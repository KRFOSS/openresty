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
    $nginx = File::Spec->catfile($prefix, 'nginx', 'sbin', 'nginx');
    $nginx = File::Spec->catfile($prefix, 'bin', 'openresty') unless -x $nginx;
}
plan skip_all => 'OpenResty binary is not available' unless -x $nginx;

my ($vout, $verr) = ('', '');
my $nothing = '';
my $SESSION = '';
run3([$nginx, '-V'], undef, \$vout, \$verr);
my $flags = $vout . $verr;
plan skip_all => 'nginx built without --with-debug'
    unless $flags =~ /--with-debug/;
plan skip_all => 'nginx built without --with-http_ssl_module'
    unless $flags =~ /--with-http_ssl_module/;
plan skip_all => 'nginx built without --with-http_v3_module'
    unless $flags =~ /--with-http_v3_module/;

# Regression guards for the CVE-2026-132779 backport:
#   * ngx_output_chain.c / ngx_http_write_filter_module.c must make progress
#     checks instead of re-posting a write event forever when SSL_write()
#     returns SSL_ERROR_WANT_READ.
#   * The "psent" rename must stay: limit_rate_after mutates `sent`, so using
#     that variable for the progress check silently disables the fix.
# All paths and ports are created at run time; nothing depends on a developer
# machine's absolute paths.
#
# NOTE: this file is a REGRESSION GUARD only.  It is not a vulnerability
# detector.  The CPU spin itself is deliberately not measured here because it
# is flaky in CI; the 0-RTT spin is verified by the separate manual
# reproduction procedure (0-RTT request with the client Finished withheld).
# Both the unpatched and the patched binary are expected to pass this file.

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
    open my $fh, '<', $path or return '';
    local $/;
    my $c = <$fh>;
    close $fh;
    return defined $c ? $c : '';
}

my $dir = tempdir(CLEANUP => 1);
chmod 0755, $dir;
my $logs = File::Spec->catdir($dir, 'logs');
my $certs = File::Spec->catdir($dir, 'certs');
my $www = File::Spec->catdir($dir, 'www');
my $tmp = File::Spec->catdir($dir, 'tmp');
for my $d ($logs, $certs, $www, $tmp) {
    make_path($d);
    chmod 0777, $d;
}

my $TLSPORT = free_port();
my $HTTPPORT = free_port();
my $BACKPORT = free_port();
my $cert = File::Spec->catfile($certs, 'server.crt');
my $key = File::Spec->catfile($certs, 'server.key');
my $ticket_key = File::Spec->catfile($certs, 'ticket.key');
my $body_file = File::Spec->catfile($www, 'blob.bin');
my $conf = File::Spec->catfile($dir, 'nginx.conf');

my $payload = 'Z' x (128 * 1024);
write_file($body_file, $payload);
my $want_md5 = md5_hex($payload);

my ($co, $ce) = ('', '');
run3(['openssl', 'req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-days', '1',
      '-subj', '/CN=localhost', '-keyout', $key, '-out', $cert],
     \$nothing, \$co, \$ce);
die "cannot generate test certificate: $ce" if $? != 0;
run3(['openssl', 'rand', '-out', $ticket_key, '48'],
     \$nothing, \$co, \$ce);
die "cannot generate ticket key: $ce" if $? != 0;

write_file($conf, <<"CONF");
worker_processes 1;
daemon off;
error_log $logs/error.log info;
pid $logs/nginx.pid;
events { worker_connections 64; }
http {
    access_log off;
    client_body_temp_path $tmp/client;
    proxy_temp_path $tmp/proxy;
    large_client_header_buffers 4 16k;
    ssl_session_cache shared:SSL:10m;
    ssl_session_timeout 10m;
    ssl_session_tickets on;
    ssl_session_ticket_key $ticket_key;

    server {
        listen 127.0.0.1:$HTTPPORT;
        location / { return 200 "OK\n"; }
        location = /big.bin {
            alias $body_file;
            default_type application/octet-stream;
        }
        location = /rate.bin {
            alias $body_file;
            default_type application/octet-stream;
            limit_rate 1m;
            limit_rate_after 4k;
        }
        location /upstream/ {
            proxy_pass https://127.0.0.1:$BACKPORT/;
            proxy_ssl_verify off;
        }
    }

    server {
        listen 127.0.0.1:$TLSPORT ssl;
        ssl_certificate $cert;
        ssl_certificate_key $key;
        ssl_protocols TLSv1.3;
        ssl_early_data on;

        location / { return 200 "OK\\n"; }
        location /post {
            content_by_lua_block { ngx.req.read_body(); ngx.say("POST-OK") }
        }
        location = /big.bin {
            alias $body_file;
            default_type application/octet-stream;
        }
        # psent rename guard: limit_rate_after must not corrupt the progress
        # baseline used by the write filter.
        location = /rate.bin {
            alias $body_file;
            default_type application/octet-stream;
            limit_rate 1m;
            limit_rate_after 4k;
        }
        location /upstream/ {
            proxy_pass https://127.0.0.1:$BACKPORT/;
            proxy_ssl_verify off;
        }
    }

    server {
        listen 127.0.0.1:$BACKPORT ssl;
        ssl_certificate $cert;
        ssl_certificate_key $key;
        ssl_protocols TLSv1.3;
        location / { return 200 "BACKEND-OK\\n"; }
    }
}
CONF

my ($to, $te) = ('', '');
run3([$nginx, '-p', "$dir/", '-c', $conf, '-t'], \$nothing, \$to, \$te);
ok($? == 0, 'nginx 설정이 유효하다') or diag($to . $te);

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
        for my $p ($TLSPORT, $HTTPPORT, $BACKPORT) {
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
    fail('nginx 기동') or diag(read_file("$logs/error.log"));
    done_testing();
    exit;
}
ok(1, 'nginx 기동');

sub request {
    my ($port, $method, $uri) = @_;
    my $req = "$method $uri HTTP/1.1\r\nHost: 127.0.0.1\r\n"
            . "Connection: close\r\n\r\n";
    my $s = IO::Socket::INET->new(
        PeerAddr => '127.0.0.1', PeerPort => $port, Proto => 'tcp', Timeout => 10,
    ) or return '';
    print {$s} $req;
    my $got = '';
    eval {
        local $SIG{ALRM} = sub { die "timeout\n" };
        alarm 15;
        while (1) {
            my $buf = '';
            my $n = sysread($s, $buf, 8192);
            last if !defined $n || $n == 0;
            $got .= $buf;
            last if length($got) > 2 * 1024 * 1024;
        }
        alarm 0;
    };
    alarm 0;
    close $s;
    return $got;
}

sub split_response {
    my ($raw) = @_;
    my ($head, $body) = split(/\r\n\r\n/, $raw, 2);
    $body = '' unless defined $body;
    return ($head || '', $body);
}

sub status_of {
    my ($head) = @_;
    return $1 if $head =~ m{\AHTTP/1\.[01]\s+(\d{3})};
    return '<no-status>';
}

sub http_body {
    my ($raw) = @_;
    # s_client prints TLS diagnostics before the HTTP response; anchor on the
    # status line and take everything after the header terminator.
    return substr($raw, $+[0]) if $raw =~ m{HTTP/1\.[01]\s+\d{3}[^\r\n]*\r\n(?:[^\r\n]+\r\n)*\r\n};
    return '';
}

sub strip_crlf {
    my ($s) = @_;
    $s =~ s/\r\n/\n/g;
    return $s;
}

sub s_client {
    my (@args) = @_;
    my ($out, $err) = ('', '');
    my $in = '';
    eval {
        local $SIG{ALRM} = sub { die "timeout\n" };
        alarm 25;
        run3(['timeout', '20', 'openssl', 's_client', '-connect',
              '127.0.0.1:' . shift(@args), '-tls1_3', @args],
             \$in, \$out, \$err);
        alarm 0;
    };
    alarm 0;
    return ($out ne '' ? $out : ($err // ''));
}

sub warm {
    my ($sess) = @_;
    my $req = "GET / HTTP/1.1\r\nHost: t\r\nConnection: close\r\n\r\n";
    my ($out, $err) = ('', '');
    my $in = $req;
    run3(['timeout', '10', 'openssl', 's_client', '-connect',
          "127.0.0.1:$TLSPORT", '-tls1_3', '-sess_out', $sess, '-quiet'],
         \$in, \$out, \$err);
}

sub early {
    my ($ed) = @_;
    return s_client($TLSPORT, '-sess_in', $SESSION, '-early_data', $ed, '-quiet');
}

# 1) 일반 경로 회귀 없음
my $r = request($HTTPPORT, 'GET', '/');
my ($h, $b) = split_response($r);
is(status_of($h), '200', '3) GET / -> 200');
is($b, "OK\n", '3) GET / 본문');

# 2) limit_rate + limit_rate_after: 본문이 잘리지 않고 정확히 전달
$r = request($HTTPPORT, 'GET', '/rate.bin');
($h, $b) = split_response($r);
is(status_of($h), '200', '4) limit_rate_after 응답 상태 200');
is(length($b), length($payload), '4) limit_rate_after 본문 길이 정확');
is(md5_hex($b), $want_md5, '4) limit_rate_after 본 내용 일치 (psent 개명)');

# 3) rate limit 없는 큰 응답
$r = request($HTTPPORT, 'GET', '/big.bin');
($h, $b) = split_response($r);
is(status_of($h), '200', '5) 큰 응답 상태 200');
is(md5_hex($b), $want_md5, '5) 큰 응답 내용 일치');

# 4) 업스트ream TLS 경유 (output_chain 변경 회귀 방지)
$r = request($HTTPPORT, 'GET', '/upstream/ok');
($h, $b) = split_response($r);
is(status_of($h), '200', '6) 업스트림 TLS 프록시 상태 200');
is($b, "BACKEND-OK\n", '6) 업스트림 TLS 프록시 본문');

# 5) 0-RTT 회귀: 티켓 -> 0-RTT GET/POST 가 응답하고 멈추지 않음
$SESSION = File::Spec->catfile($dir, 'ticket.pem');
warm($SESSION);
ok(-s $SESSION, '7) TLS 세션 티켓 발급');

my $pad = 'A' x 4000;
my $ed_get = File::Spec->catfile($dir, 'ed_get.bin');
my $ed_post = File::Spec->catfile($dir, 'ed_post.bin');
my $ed_rate = File::Spec->catfile($dir, 'ed_rate.bin');
write_file($ed_get, "GET / HTTP/1.1\r\nHost: t\r\nX-Pad: $pad\r\n"
                  . "Connection: close\r\n\r\n");
write_file($ed_post, "POST /post HTTP/1.1\r\nHost: t\r\nContent-Length: 4\r\n"
                   . "Connection: close\r\n\r\nX=1\n");
write_file($ed_rate, "GET /rate.bin HTTP/1.1\r\nHost: t\r\nX-Pad: $pad\r\n"
                   . "Connection: close\r\n\r\n");

my $e = early($ed_get);
like($e, qr{^HTTP/1\.1 200 }m, '8) 0-RTT GET 이 응답한다 (타임아웃 없음)')
    or diag(substr($e, 0, 300));

$e = early($ed_post);
like($e, qr{^HTTP/1\.1 425 }m, '9) 0-RTT POST 는 ROKFOSS 가드로 425')
    or diag(substr($e, 0, 300));

# 6) 가장 중요한 조합: limit_rate_after + 0-RTT
$e = early($ed_rate);
like($e, qr{^HTTP/1\.1 200 }m, '10) limit_rate_after + 0-RTT 응답 상태 200')
    or diag(substr($e, 0, 300));
my ($eh, $eb) = ('', http_body($e));
is(length($eb), length($payload), '10) limit_rate_after + 0-RTT 본문 길이');
is(md5_hex(strip_crlf($eb)), $want_md5, '10) limit_rate_after + 0-RTT 본문 일치');

# 7) 워커가 살아 있고 추가 요청을 처리할 수 있어야 한다
$r = request($HTTPPORT, 'GET', '/');
($h, $b) = split_response($r);
is(status_of($h), '200', '11) 0-RTT 이후에도 워커가 정상 응답');

done_testing();
