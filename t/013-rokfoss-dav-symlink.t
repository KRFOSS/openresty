use strict;
use warnings;

use Digest::MD5 qw(md5_hex);
use File::Path qw(make_path);
use File::Spec;
use File::Temp qw(tempdir);
use IO::Socket::INET;
use IPC::Run3 qw(run3);
use POSIX qw(WNOHANG);
use Test::More;

my $nginx = $ENV{TEST_NGINX_BINARY};
if (!defined $nginx || $nginx eq '') {
    my $prefix = $ENV{OPENRESTY_PREFIX} || '/usr/local/openresty';
    $nginx = File::Spec->catfile($prefix, 'bin', 'openresty');
    $nginx = File::Spec->catfile($prefix, 'nginx', 'sbin', 'nginx')
        unless -x $nginx;
}

plan skip_all => 'OpenResty binary is not available' unless -x $nginx;

my ($vout, $verr) = ('', '');
run3([$nginx, '-V'], undef, \$vout, \$verr);
plan skip_all => 'nginx built without --with-http_dav_module'
    unless ($vout . $verr) =~ /--with-http_dav_module/;

# disable_symlinks is enforced by ngx_open_file_wrapper(), not by
# ngx_http_set_disable_symlinks().  DAV used to call neither, so PUT through a
# symlink directory created a real file OUTSIDE the document root.
# Every case below uses a kernel-assigned port and a tempdir: no absolute
# path from a developer machine may leak into CI.

sub free_port {
    my $s = IO::Socket::INET->new(
        LocalAddr => '127.0.0.1', LocalPort => 0, Proto => 'tcp',
        Listen => 1, ReuseAddr => 1,
    ) or die "cannot allocate a free port: $!";
    my $p = $s->sockport;
    close $s;
    return $p;
}

sub write_file {
    my ($path, $content) = @_;
    open my $fh, '>', $path or die "cannot write $path: $!";
    print {$fh} $content;
    close $fh;
}

sub read_file {
    my ($path) = @_;
    open my $fh, '<', $path or return undef;
    local $/;
    my $d = <$fh>;
    close $fh;
    return defined $d ? $d : '';
}

my $PORT_ON  = free_port();
my $PORT_OFF = free_port();

my $dir = tempdir(CLEANUP => 1);
chmod 0755, $dir;

my $www_on  = File::Spec->catdir($dir, 'www_on');
my $www_off = File::Spec->catdir($dir, 'www_off');
my $outside = File::Spec->catdir($dir, 'outside');
my $tmp     = File::Spec->catdir($dir, 'tmp');
my $logs    = File::Spec->catdir($dir, 'logs');
for my $d ($www_on, $www_off, $outside, $tmp, $logs) {
    make_path($d);
    chmod 0777, $d;
}
make_path(File::Spec->catdir($www_on,  'plain'));
make_path(File::Spec->catdir($www_off, 'plain'));
chmod 0777, File::Spec->catdir($www_on,  'plain');
chmod 0777, File::Spec->catdir($www_off, 'plain');

my $secret      = File::Spec->catfile($outside, 'secret.txt');
my $outside_new = File::Spec->catfile($outside, 'new.txt');
my $src_on      = File::Spec->catfile($www_on, 'src.txt');
my $wo_on       = File::Spec->catfile($www_on, 'plain', 'wo.txt');
my $link_on     = File::Spec->catfile($www_on, 'link.txt');
my $linkdir_on  = File::Spec->catfile($www_on, 'linkdir');
my $link_off    = File::Spec->catfile($www_off, 'link.txt');

# Worker must be non-root for the EACCES case to mean anything: root can open
# a mode-0200 file for reading, so a root worker would silently skip the very
# branch we need to exercise.
my $worker_is_root = ($> == 0);
if ($worker_is_root) {
    my $nobody = getpwnam('nobody');
    die 'no nobody user on this system' unless defined $nobody;
    chown $nobody, -1, $www_on, $www_off, $tmp, $logs, $outside,
          File::Spec->catdir($www_on, 'plain'),
          File::Spec->catdir($www_off, 'plain');
}

# Recreate every mutable fixture so pre/post runs are independent of order.
sub reset_fixtures {
    unlink $secret, $outside_new, $src_on, $wo_on;
    unlink $link_on, $linkdir_on, $link_off;
    unlink File::Spec->catfile($www_on, 'plain', 'ok.txt');
    unlink File::Spec->catfile($www_on, 'plain', 'inside.txt');
    unlink File::Spec->catfile($www_off, 'plain', 'inside.txt');

    write_file($secret, "ORIGINAL-OUTSIDE\n");
    # writable so that a pre-patch COPY reaches the symlink target and
    # produces the supervisor-observed 204 instead of a permission 500
    chmod 0666, $secret;
    write_file(File::Spec->catfile($www_on, 'plain', 'inside.txt'), "IN-ROOT\n");
    write_file(File::Spec->catfile($www_off, 'plain', 'inside.txt'), "IN-ROOT\n");
    write_file($src_on, "SRC\n");
    write_file($wo_on, "WO\n");
    chmod 0200, $wo_on;
    if ($worker_is_root) {
        my $nobody = getpwnam('nobody');
        chown $nobody, -1, $wo_on;
    }

    symlink($secret, $link_on)  or die "symlink: $!";
    symlink($outside, $linkdir_on) or die "symlink: $!";
    symlink($secret, $link_off) or die "symlink: $!";
    if ($worker_is_root) {
        # COPY calls utimes() on the destination; give the non-root worker
        # ownership so a pre-patch run reaches the same 204 as a root worker.
        my $nobody = getpwnam('nobody');
        chown $nobody, -1, $secret, $link_on, $link_off;
    }
}
reset_fixtures();

# Kali/Debian have uid nobody with group nogroup; do not hardcode the group.
my $worker_group = getgrgid((getpwnam('nobody'))[3]) || 'nogroup';
my $user_line = $worker_is_root ? "user nobody $worker_group;" : '';
my $conf = File::Spec->catfile($dir, 'nginx.conf');
write_file($conf, <<"CONF");
worker_processes 1;
daemon off;
$user_line
error_log $logs/error.log info;
pid $logs/nginx.pid;
events { worker_connections 64; }
http {
    access_log off;
    client_max_body_size 1m;
    client_body_temp_path $tmp/cb;
    proxy_temp_path $tmp/px;
    fastcgi_temp_path $tmp/fc;
    uwsgi_temp_path $tmp/uw;
    scgi_temp_path $tmp/sc;
    server {
        listen 127.0.0.1:$PORT_ON;
        root $www_on;
        disable_symlinks on;
        dav_methods PUT DELETE COPY MOVE MKCOL;
        dav_access user:rw group:rw all:rw;
        location / { }
    }
    server {
        listen 127.0.0.1:$PORT_OFF;
        root $www_off;
        disable_symlinks off;
        dav_methods PUT DELETE COPY MOVE MKCOL;
        dav_access user:rw group:rw all:rw;
        location / { }
    }
}
CONF

my ($tin, $tout, $terr) = ('', '', '');
run3([$nginx, '-p', "$dir/", '-c', $conf, '-t'], \$tin, \$tout, \$terr);
if ($? != 0) {
    fail('nginx 설정이 유효하다');
    diag($tout . $terr);
    done_testing();
    exit;
}
ok(1, 'nginx 설정이 유효하다');

my $nginx_pid = fork();
die "cannot fork: $!" unless defined $nginx_pid;
if ($nginx_pid == 0) {
    exec $nginx, '-p', "$dir/", '-c', $conf;
    exit 1;
}

END {
    if ($nginx_pid) {
        kill 'TERM', $nginx_pid;
        for (1 .. 60) {
            last if waitpid($nginx_pid, WNOHANG) == $nginx_pid;
            select undef, undef, undef, 0.1;
        }
        kill 'KILL', $nginx_pid;
        waitpid($nginx_pid, 0);
    }
    $? = 0;
}

sub wait_ready {
    for (1 .. 100) {
        for my $p ($PORT_ON, $PORT_OFF) {
            my $s = IO::Socket::INET->new(
                PeerAddr => '127.0.0.1', PeerPort => $p,
                Proto => 'tcp', Timeout => 1,
            );
            if ($s) { close $s; return 1; }
        }
        select undef, undef, undef, 0.1;
    }
    return 0;
}

if (!wait_ready()) {
    fail('nginx 기동');
    diag(read_file("$logs/error.log") || '');
    done_testing();
    exit;
}
ok(1, 'nginx 기동');

sub request {
    my ($port, $method, $uri, $body, %hdr) = @_;
    $body = '' unless defined $body;
    my $dest = delete $hdr{Destination};

    my $req = "$method $uri HTTP/1.1\r\n"
            . "Host: 127.0.0.1:$port\r\n"
            . "Connection: close\r\n";
    $req .= "Destination: $dest\r\n" if defined $dest;
    $req .= "Content-Length: " . length($body) . "\r\n" if length $body;
    $req .= "\r\n$body";

    my $s = IO::Socket::INET->new(
        PeerAddr => '127.0.0.1', PeerPort => $port,
        Proto => 'tcp', Timeout => 5,
    ) or return '<connect-failed>';
    print {$s} $req;

    my $got = '';
    eval {
        local $SIG{ALRM} = sub { die "timeout\n" };
        alarm 5;
        while (1) {
            my $buf = '';
            my $n = sysread($s, $buf, 4096);
            last if !defined $n || $n == 0;
            $got .= $buf;
            last if length($got) > 65536;
        }
        alarm 0;
    };
    alarm 0;
    close $s;
    return $got;
}

sub status {
    my ($port, $method, $uri, $body, %hdr) = @_;
    my $r = request($port, $method, $uri, $body, %hdr);
    return $1 if $r =~ m{\AHTTP/1\.[01]\s+(\d{3})};
    return "<no-status:" . substr($r, 0, 60) . ">";
}

sub is_2xx { return shift =~ /^2\d\d$/ ? 1 : 0 }

# 1) 기본값(disable_symlinks off) 회귀 없음: 심링크 경유 PUT 이 예전처럼 성공
reset_fixtures();
my $s1 = status($PORT_OFF, 'PUT', '/link.txt', "PWNED-BY-PUT");
ok(is_2xx($s1), "1) disable_symlinks off: PUT link.txt 성공 (got $s1)");

# 2) 오탐 없음: 루트 안 정상 경로 PUT
reset_fixtures();
my $s2 = status($PORT_ON, 'PUT', '/plain/ok.txt', "OK");
is($s2, '201', "2) disable_symlinks on: 정상 경로 PUT -> 201");

# 3) 핵심: 심링크 파일에 PUT -> 403, 대상 내용/링크 자체 보존
reset_fixtures();
my $md5_before = md5_hex(read_file($secret) || '');
my $s3 = status($PORT_ON, 'PUT', '/link.txt', "PWNED-BY-PUT");
is($s3, '403', "3) disable_symlinks on: PUT link.txt -> 403");
is(md5_hex(read_file($secret) || ''), $md5_before, '3) 루트 밖 대상 파일 내용 불변');
is(readlink($link_on) || '', $secret, '3) 심링크가 파괴되지 않음');

# 4) 가장 강한 위반: 심링크 디렉터리 안에 새 파일 PUT -> 403, 루트 밖 생성 없음
reset_fixtures();
my $s4 = status($PORT_ON, 'PUT', '/linkdir/new.txt', "PWNED-DIR");
is($s4, '403', "4) disable_symlinks on: PUT linkdir/new.txt -> 403");
ok(!-e $outside_new, '4) 루트 밖 outside/new.txt 가 생성되지 않음');

# 5) DELETE 도 심링크를 따라가지 않음
reset_fixtures();
my $s5 = status($PORT_ON, 'DELETE', '/link.txt');
is($s5, '403', "5) disable_symlinks on: DELETE link.txt -> 403");
ok(-l $link_on && (readlink($link_on) || '') eq $secret,
   '5) DELETE 후에도 심링크가 남음');

# 6) COPY Destination 이 심링크 -> 403
reset_fixtures();
my $s6 = status($PORT_ON, 'COPY', '/src.txt', '', Destination => '/link.txt');
is($s6, '403', "6) disable_symlinks on: COPY Destination=link.txt -> 403");
ok(-l $link_on && (readlink($link_on) || '') eq $secret,
   '6) COPY 후에도 심링크가 남음');

# 7) 대조군: 정적 GET 은 원래부터 403
reset_fixtures();
my $s7 = status($PORT_ON, 'GET', '/link.txt');
is($s7, '403', "7) disable_symlinks on: 정적 GET link.txt -> 403 (대조군)");

# 8) EACCES 오탐 방지: worker(nobody) 소유의 mode 0200 파일에 PUT 성공
reset_fixtures();
my $s8 = status($PORT_ON, 'PUT', '/plain/wo.txt', "OVERWRITE");
ok(is_2xx($s8), "8) 쓰기 전용(0200) 파일 PUT 성공 (got $s8)");
if (!is_2xx($s8)) {
    diag(read_file("$logs/error.log") || '');
}

done_testing();
