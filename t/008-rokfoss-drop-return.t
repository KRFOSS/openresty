use strict;
use warnings;

use File::Path qw(make_path);
use File::Spec;
use File::Temp qw(tempdir);
use IO::Socket::INET;
use POSIX qw(WNOHANG);
use Test::More;

my $prefix = $ENV{OPENRESTY_PREFIX} || '/usr/local/openresty';
my $nginx = File::Spec->catfile($prefix, 'nginx', 'sbin', 'nginx');
if (!-x $nginx) {
    $nginx = File::Spec->catfile($prefix, 'bin', 'openresty');
}

plan skip_all => 'OpenResty binary is not available' unless -x $nginx;

# 시험 대상 동작
#   drop_all 은 요청을 응답 없이 끊는다. 그런데 rewrite 단계의 return 은
#   요청을 즉시 finalize 해 preaccess 의 drop_all 검문에 닿지 않았다.
#   그래서 "if (...) { drop_all on; }" 뒤에 return 을 두거나, 이름있는
#   location 에서 drop_all + return 을 쓰면 드롭이 무시되고 응답이 나갔다.
#   ngx_http_script_return_code 가 return 실행 전에 같은 판정을 한다.
#
#   1) location 직속 drop_all + return       -> 끊긴다
#   2) if 로 켠 drop_all + return            -> 끊긴다 (이 시험의 핵심)
#   3) if 조건이 거짓일 때의 return          -> 200 (과잉 드롭이 없어야 한다)
#   4) 이름있는 location 의 drop_all + return -> 끊긴다
#   5) drop_all 이 없는 곳의 return          -> 200 (영향 없음)

my $PORT = 19861;

sub write_file {
    my ($path, $content) = @_;
    open my $fh, '>', $path or die "cannot write $path: $!";
    print {$fh} $content;
    close $fh;
}

sub read_file {
    my ($path) = @_;
    open my $fh, '<', $path or return '';
    local $/;
    my $c = <$fh>;
    close $fh;
    return defined $c ? $c : '';
}

# 원시 HTTP 요청을 보내고 받은 바이트를 그대로 돌려준다.
# 드롭되면 아무 바이트도 오지 않고 연결이 닫힌다.
sub raw_request {
    my ($port, $payload) = @_;

    my $sock = IO::Socket::INET->new(
        PeerAddr => '127.0.0.1',
        PeerPort => $port,
        Proto    => 'tcp',
        Timeout  => 5,
    ) or return undef;

    print {$sock} $payload;

    my $got = '';
    eval {
        local $SIG{ALRM} = sub { die "timeout\n" };
        alarm 5;
        while (1) {
            my $buf = '';
            my $n = sysread($sock, $buf, 4096);
            last if !defined $n || $n == 0;
            $got .= $buf;
            last if length $got > 262144;
        }
        alarm 0;
    };
    alarm 0;
    close $sock;

    return $got;
}

sub start_nginx {
    my ($dir, $conf, $port) = @_;

    my $pid = fork();
    die "cannot fork: $!" unless defined $pid;

    if ($pid == 0) {
        exec $nginx, '-p', "$dir/", '-c', $conf;
        exit 1;
    }

    for (1 .. 100) {
        my $s = IO::Socket::INET->new(
            PeerAddr => '127.0.0.1',
            PeerPort => $port,
            Proto    => 'tcp',
            Timeout  => 1,
        );
        if ($s) {
            close $s;
            return $pid;
        }
        select undef, undef, undef, 0.1;
    }

    diag("nginx did not listen on $port");
    kill 'TERM', $pid;
    waitpid($pid, 0);
    return undef;
}

sub stop_nginx {
    my ($pid) = @_;
    return unless $pid;

    kill 'TERM', $pid;

    for (1 .. 60) {
        return if waitpid($pid, WNOHANG) == $pid;
        select undef, undef, undef, 0.1;
    }

    kill 'KILL', $pid;
    waitpid($pid, 0);
}

my $dir = tempdir(CLEANUP => 1);
make_path(File::Spec->catdir($dir, 'logs'));
make_path(File::Spec->catdir($dir, 'body'));

my $conf = File::Spec->catfile($dir, 'nginx.conf');
write_file($conf, <<"CONF");
worker_processes 1;
error_log logs/error.log info;
pid logs/nginx.pid;
daemon off;
events { worker_connections 64; }
http {
    log_format kf 'st=\$status u=\$uri';
    access_log logs/access.log kf;
    client_body_temp_path body;
    server {
        listen 127.0.0.1:$PORT;
        location /plain    { drop_all on; return 200 "PLAIN"; }
        location /ifret    { if (\$arg_x = 1) { drop_all on; } return 200 "IFRET"; }
        location /ep404    { error_page 404 = \@dropname; return 404; }
        location \@dropname { drop_all on; return 200 "NAMED"; }
        location /nodrop   { return 200 "NODROP-OK"; }
    }
}
CONF

my $nginx_pid = start_nginx($dir, $conf, $PORT);
plan skip_all => 'cannot start nginx' unless $nginx_pid;

END {
    stop_nginx($nginx_pid) if $nginx_pid;
}

my $access = File::Spec->catfile($dir, 'logs', 'access.log');
my $error  = File::Spec->catfile($dir, 'logs', 'error.log');

sub get_req {
    my ($path) = @_;
    return "GET $path HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n";
}

# --- 1) location 직속 drop_all + return ------------------------------------

my $resp = raw_request($PORT, get_req('/plain'));
is($resp, '', 'drop_all + return 이 같은 location 에 있으면 응답 없이 끊긴다');

# --- 2) if 로 켠 drop_all + return (핵심) ----------------------------------

$resp = raw_request($PORT, get_req('/ifret?x=1'));
is($resp, '', 'if 로 켠 drop_all 은 뒤따르는 return 보다 우선한다');

# --- 3) if 조건이 거짓이면 드롭하지 않는다 (과잉 드롭 방지) ----------------

$resp = raw_request($PORT, get_req('/ifret'));
like($resp, qr{^HTTP/1\.1 200 }, 'if 조건이 거짓이면 return 은 정상 동작한다');
like($resp, qr{IFRET}, 'if 조건이 거짓이면 본문도 그대로 나간다');

# --- 4) 이름있는 location 의 drop_all + return -----------------------------

$resp = raw_request($PORT, get_req('/ep404'));
is($resp, '', 'error_page 로 간 이름있는 location 의 drop_all 도 return 을 이긴다');

# --- 5) drop_all 이 없는 곳은 영향이 없다 ---------------------------------

$resp = raw_request($PORT, get_req('/nodrop'));
like($resp, qr{^HTTP/1\.1 200 }, 'drop_all 이 없으면 return 은 그대로 200 이다');
like($resp, qr{NODROP-OK}, 'drop_all 이 없으면 본문도 그대로 나간다');

# --- 로그로 교차 확인 -----------------------------------------------------

select undef, undef, undef, 0.5;

my $access_log = read_file($access);
my $drop_hits  = () = $access_log =~ /st=999 /g;
is($drop_hits, 3, '드롭된 3건이 접근로그에 999 로 남는다');
like($access_log, qr{st=200 u=/nodrop}, '드롭되지 않은 요청은 200 으로 남는다');

my $error_log = read_file($error);
like($error_log, qr{dropped by drop_all},
     '드롭 사유가 에러로그에 남는다');

done_testing();
