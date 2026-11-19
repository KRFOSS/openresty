use strict;
use warnings;

use File::Path qw(make_path);
use File::Spec;
use File::Temp qw(tempdir);
use IPC::Run3 qw(run3);
use IO::Socket::INET;
use POSIX qw(WNOHANG);
use Test::More tests => 16;

my $prefix = $ENV{OPENRESTY_PREFIX} || '/usr/local/openresty';
my $nginx = File::Spec->catfile($prefix, 'nginx', 'sbin', 'nginx');
$nginx = File::Spec->catfile($prefix, 'bin', 'openresty') unless -x $nginx;

# 0-RTT 재전송 방어 검증.
#   ON  (ssl_early_data_idempotent_only on)  : 0-RTT POST -> 425, GET -> 200
#   OFF (ssl_early_data_idempotent_only off) : 0-RTT POST -> 200 (패치 전 동작과 동일)
# 실제로 0-RTT 가 수락됐음($ssl_early_data = 1)을 접근로그와 응답 헤더로 먼저 확인한다.

my $PORT_ON  = 19871;
my $PORT_OFF = 19872;
my $certdir   = File::Spec->catdir($dir, 'certs');
my $CERT      = File::Spec->catfile($certdir, 'server.crt');
my $KEY       = File::Spec->catfile($certdir, 'server.key');
my $TICKETKEY = File::Spec->catfile($certdir, 'ticket.key');

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
make_path($certdir);
make_path(File::Spec->catdir($dir, 'logs'));
make_path(File::Spec->catdir($dir, 'body'));
make_path(File::Spec->catdir($dir, 'client_body_temp'));

# Generate test-only TLS material inside the temporary directory so the test
# does not depend on host-specific paths or certificate file permissions.
my ($cert_out, $cert_err);
my $cert_input = '';
run3([
    'openssl', 'req', '-x509', '-newkey', 'rsa:2048',
    '-nodes', '-days', '1',
    '-subj', '/CN=localhost',
    '-keyout', $KEY, '-out', $CERT,
], \$cert_input, \$cert_out, \$cert_err);
die "cannot generate test certificate: $cert_err" if $? != 0;

my ($ticket_out, $ticket_err);
my $ticket_input = '';
run3(['openssl', 'rand', '-out', $TICKETKEY, '48'],
     \$ticket_input, \$ticket_out, \$ticket_err);
die "cannot generate TLS session ticket key: $ticket_err" if $? != 0;

my $conf = File::Spec->catfile($dir, 'nginx.conf');
my $common = <<"SSL";
        ssl_certificate     $CERT;
        ssl_certificate_key $KEY;
        ssl_protocols       TLSv1.3;
        ssl_session_timeout 10m;
        ssl_session_tickets on;
        ssl_session_ticket_key $TICKETKEY;
        ssl_early_data      on;
        add_header X-Early \$ssl_early_data always;
SSL

write_file($conf, <<"CONF");
user root;
worker_processes 1;
daemon off;
error_log $dir/logs/error.log info;
pid $dir/logs/nginx.pid;
events { worker_connections 128; }
http {
    access_log off;
    client_body_temp_path $dir/client_body_temp;
    log_format tls '\$status|\$request_method|\$request_uri|early=\$ssl_early_data';

    server {
        listen 127.0.0.1:$PORT_ON ssl;
        server_name on;
        ssl_session_cache shared:ONSSL:1m;
$common        ssl_early_data_idempotent_only on;
        access_log $dir/logs/on.access.log tls;
        location / { echo "ON-OK"; }
        location /ret { return 200 "RET-OK"; }
    }

    server {
        listen 127.0.0.1:$PORT_OFF ssl;
        server_name off;
        ssl_session_cache shared:OFFSSL:1m;
$common        ssl_early_data_idempotent_only off;
        access_log $dir/logs/off.access.log tls;
        location / { echo "OFF-OK"; }
    }
}
CONF

my ($cout, $cerr);
my $input = '';
run3([$nginx, '-p', "$dir/", '-c', $conf, '-t'], \$input, \$cout, \$cerr);
ok($? == 0, 'ssl_early_data_idempotent_only 지시어가 받아들여진다')
    or diag("nginx -t: $cout$cerr");

my $onlog  = File::Spec->catfile($dir, 'logs', 'on.access.log');
my $offlog = File::Spec->catfile($dir, 'logs', 'off.access.log');

sub start_nginx {
    my $pid = fork();
    die "cannot fork: $!" unless defined $pid;
    if ($pid == 0) {
        exec $nginx, '-p', "$dir/", '-c', $conf;
        exit 1;
    }
    for (1 .. 100) {
        my $s = IO::Socket::INET->new(
            PeerAddr => '127.0.0.1', PeerPort => $PORT_ON,
            Proto => 'tcp', Timeout => 1);
        if ($s) { close $s; return $pid; }
        select undef, undef, undef, 0.1;
    }
    kill 'TERM', $pid;
    waitpid($pid, 0);
    return undef;
}

my $nginx_pid = start_nginx();

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

if (!$nginx_pid) {
    fail("nginx 기동 실패") for 1 .. 15;
    done_testing();
    exit;
}

sub s_client {
    my (@args) = @_;
    my ($out, $err);
    my $stdin = '';
    eval {
        local $SIG{ALRM} = sub { die "timeout\n" };
        alarm 20;
        run3(['openssl', 's_client', '-connect', '127.0.0.1:' . shift(@args),
              '-tls1_3', @args], \$stdin, \$out, \$err);
        alarm 0;
    };
    alarm 0;
    return ($out // '') . ($err // '');
}

sub warm {
    my ($port, $sess) = @_;
    my $req = "GET /warm HTTP/1.1\r\nHost: t\r\nConnection: close\r\n\r\n";
    my ($out, $err);
    my $in = $req;
    run3(['openssl', 's_client', '-connect', "127.0.0.1:$port", '-tls1_3',
          '-sess_out', $sess, '-quiet'], \$in, \$out, \$err);
}

sub early_req {
    my ($port, $sess, $ed) = @_;
    return s_client($port, '-sess_in', $sess, '-early_data', $ed, '-quiet');
}

sub normal_post {
    my ($port, $path) = @_;
    $path ||= '/charge';
    my $req = "POST $path HTTP/1.1\r\nHost: t\r\nContent-Length: 4\r\n"
            . "Connection: close\r\n\r\nX=1\n";
    my ($out, $err);
    my $in = $req;
    run3(['openssl', 's_client', '-connect', "127.0.0.1:$port", '-tls1_3',
          '-quiet'], \$in, \$out, \$err);
    return ($out // '') . ($err // '');
}

my $sess_on  = File::Spec->catfile($dir, 'ticket_on.pem');
my $sess_off = File::Spec->catfile($dir, 'ticket_off.pem');
my $ed_post  = File::Spec->catfile($dir, 'ed_post.bin');
my $ed_get   = File::Spec->catfile($dir, 'ed_get.bin');
my $ed_ret   = File::Spec->catfile($dir, 'ed_ret.bin');
write_file($ed_post, "POST /charge HTTP/1.1\r\nHost: t\r\nContent-Length: 4\r\n"
                   . "Connection: close\r\n\r\nX=1\n");
write_file($ed_get,  "GET /warm HTTP/1.1\r\nHost: t\r\nConnection: close\r\n\r\n");
write_file($ed_ret,  "POST /ret HTTP/1.1\r\nHost: t\r\nContent-Length: 4\r\n"
                   . "Connection: close\r\n\r\nX=1\n");

warm($PORT_ON, $sess_on);
warm($PORT_OFF, $sess_off);
ok(-s $sess_on && -s $sess_off, '세션 티켓을 발급받았다');

# 1) 0-RTT + POST -> 425
my $r1 = early_req($PORT_ON, $sess_on, $ed_post);
like($r1, qr{^HTTP/1\.1 425 }m, '0-RTT POST 는 425 로 거부된다')
    or diag($r1);
like($r1, qr{X-Early: 1}, '0-RTT POST 응답에 X-Early: 1 이 붙는다')
    or diag($r1);
like($r1, qr{너무 일렀습니다}, '425 본문이 우리 오류 페이지다')
    or diag($r1);
select undef, undef, undef, 0.2;
my $on1 = read_file($onlog);
like($on1, qr{425\|POST\|/charge\|early=1}, '0-RTT POST 접근로그는 status=425, early=1')
    or diag($on1);

# 2) 0-RTT + GET -> 200
my $r2 = early_req($PORT_ON, $sess_on, $ed_get);
like($r2, qr{^HTTP/1\.1 200 }m, '0-RTT GET 은 200 으로 허용된다')
    or diag($r2);
select undef, undef, undef, 0.2;
my $on2 = read_file($onlog);
like($on2, qr{200\|GET\|/warm\|early=1}, '0-RTT GET 접근로그는 early=1')
    or diag($on2);

# 3) 일반 POST -> 200 (오탐 없음)
my $r3 = normal_post($PORT_ON);
like($r3, qr{^HTTP/1\.1 200 }m, '일반 POST 는 200 으로 유지된다 (오탐 없음)')
    or diag($r3);
select undef, undef, undef, 0.2;
my $on3 = read_file($onlog);
like($on3, qr{200\|POST\|/charge\|early=-}, '일반 POST 접근로그는 early=-')
    or diag($on3);

# 4) 지시어 off -> 0-RTT POST 도 200 (패치 전과 동일)
my $r4 = early_req($PORT_OFF, $sess_off, $ed_post);
like($r4, qr{^HTTP/1\.1 200 }m, 'idempotent_only off 에서 0-RTT POST 는 200')
    or diag($r4);
like($r4, qr{X-Early: 1}, 'off 케이스도 실제 0-RTT (X-Early: 1)')
    or diag($r4);
select undef, undef, undef, 0.2;
my $off4 = read_file($offlog);
like($off4, qr{200\|POST\|/charge\|early=1}, 'off 접근로그는 status=200, early=1')
    or diag($off4);

# 5) return 경로 우회 차단 (PREACCESS 를 건너뛰는 rewrite return)
my $r5 = early_req($PORT_ON, $sess_on, $ed_ret);
like($r5, qr{^HTTP/1\.1 425 }m, 'return 이 있는 location 의 0-RTT POST 도 425')
    or diag($r5);
like($r5, qr{X-Early: 1}, 'return 경로 425 응답도 실제 0-RTT (X-Early: 1)')
    or diag($r5);

my $r6 = normal_post($PORT_ON, '/ret');
like($r6, qr{^HTTP/1\.1 200 }m, 'return 경로의 일반 POST 는 200으로 유지')
    or diag($r6);
