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

# 시험 대상 계약 (drop_all 패치 주석의 의도와 실제 동작을 일치시키는 부분)
#   1) drop_all on + 본문 크기 선언이 client_max_body_size 초과 -> 드롭하지 않고
#      정상 413 오류 페이지(한국어)를 돌려준다. 접근로그도 413.
#   2) drop_all on + 한도 이내 본문 / 본문 없는 GET -> 기존대로 드롭(999).
#   3) 청크 인코딩처럼 크기를 모르는 본문(content_length_n == -1) -> 크기 초과를
#      미리 알 수 없으므로 스캐너 차단 우선, 기존대로 드롭(999).
#   4) find_config 와 preaccess(if) 두 드롭 지점에 같은 예외를 적용한다.
#   5) return 경로: find_config 를 건너뛰는 이름있는 location(@name)의
#      return 은 큰 본문 선언이어도 드롭한다. nginx 413 검문을 타지 않기
#      때문이다. 같은 location 의 return 은 find_config 의 413 검문이
#      return 보다 앞서므로 413 이 이긴다. 두 동작의 차이는 의도된 결과다.
#   6) drop_all off 는 순정과 동일하게 큰 본문에 413.

my $PORT_ON    = 19430;
my $PORT_OFF   = 19431;
my $PORT_PHASE = 19432;

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
    client_max_body_size 10;

    # (a)(b)(c)(h): find_config 의 drop_all
    server {
        listen 127.0.0.1:$PORT_ON;
        drop_all on;
        location / { }
    }

    # (d): drop_all off 는 순정과 동일
    server {
        listen 127.0.0.1:$PORT_OFF;
        location / { }
    }

    # (e)(f)(g)(i)(j): 경로별 판정 차이 확인
    server {
        listen 127.0.0.1:$PORT_PHASE;
        # 진입 location 은 한도를 크게 두어 find_config 의 413 검문을 통과시킨다.
        client_max_body_size 1m;
        location /ifdrop   { client_max_body_size 10; if (\$arg_x = 1) { drop_all on; } }
        location /ep404    { error_page 404 = \@dropname; return 404; }
        location /sameret  { drop_all on; client_max_body_size 10; return 200 "SAMERET"; }
        # find_config 를 건너뛰므로 nginx 413 검문을 타지 않는다 -> script 드롭.
        location \@dropname { drop_all on; client_max_body_size 10; return 200 "NAMED"; }
    }
}
CONF

my $nginx_pid = start_nginx($dir, $conf, $PORT_ON);
plan skip_all => 'cannot start nginx' unless $nginx_pid;

END {
    stop_nginx($nginx_pid) if $nginx_pid;
}

my $access = File::Spec->catfile($dir, 'logs', 'access.log');
my $error  = File::Spec->catfile($dir, 'logs', 'error.log');

sub post_req {
    my ($port, $path, $len) = @_;
    return "POST $path HTTP/1.1\r\nHost: x\r\nContent-Length: $len\r\n"
         . "Connection: close\r\n\r\n" . ('x' x $len);
}

sub get_req {
    my ($port, $path) = @_;
    return "GET $path HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n";
}

# --- (a) drop_all on + Content-Length > client_max_body_size ----------------

my $resp = raw_request($PORT_ON, post_req($PORT_ON, '/big', 100));
like($resp, qr{^HTTP/1\.1 413 }, 'drop_all on: 큰 본문 선언은 413 을 돌려준다');
like($resp, qr{<html lang="ko">}, 'drop_all on: 413 은 한국어 오류 페이지다');
like($resp, qr{Server: ROKFOSS-Shield}, '413 응답도 정상 응답 헤더를 가진다');

# --- (b) drop_all on + 작은 본문 --------------------------------------------

$resp = raw_request($PORT_ON, post_req($PORT_ON, '/small', 5));
is($resp, '', 'drop_all on: 한도 이내 본문은 응답 없이 드롭된다');

# --- (c) drop_all on + GET ---------------------------------------------------

$resp = raw_request($PORT_ON, get_req($PORT_ON, '/get'));
is($resp, '', 'drop_all on: GET 은 응답 없이 드롭된다');

# --- (d) drop_all off + 큰 본문 (순정과 동일) --------------------------------

$resp = raw_request($PORT_OFF, post_req($PORT_OFF, '/big', 100));
like($resp, qr{^HTTP/1\.1 413 }, 'drop_all off: 큰 본문은 순정대로 413');
like($resp, qr{<html lang="ko">}, 'drop_all off: 413 한국어 페이지도 순정과 동일');

# --- (e) return 경로: find_config 를 건너뛰는 이름있는 location ---------------
# 이름있는 location 은 find_config 를 건너뛰므로 nginx 413 검문을 타지 않는다.
# 같은 location 의 return 과 동작이 다른 것은 nginx 단계 순서 때문에 의도된 결과다.

$resp = raw_request($PORT_PHASE, post_req($PORT_PHASE, '/ep404', 100));
is($resp, '', '이름있는 location 의 return: 큰 본문 선언이어도 드롭한다(413 아님)');
unlike($resp, qr{413}, '이름있는 location 의 return: 413 응답이 아니다');

# --- (f) 같은 location 의 return ---------------------------------------------
# find_config 의 413 검문이 rewrite 의 return 보다 앞이라 413 이 이긴다.
# 우리 예외가 아니라 nginx 단계 순서의 결과다.

$resp = raw_request($PORT_PHASE, post_req($PORT_PHASE, '/sameret', 100));
like($resp, qr{^HTTP/1\.1 413 }, '같은 location 의 return: 413 이 return 보다 먼저다');
unlike($resp, qr{SAMERET}, '같은 location 의 return: 200 본문은 나가지 않는다');

# --- (g) preaccess(if) 드롭 지점: 한도 이내 본문 ------------------------------

$resp = raw_request($PORT_PHASE, post_req($PORT_PHASE, '/ifdrop?x=1', 5));
is($resp, '', 'preaccess if: 한도 이내 본문은 그대로 드롭된다');

# --- (h) 청크 인코딩(크기 미상) ----------------------------------------------
# Content-Length 가 없으면 초과 여부를 사전에 알 수 없으므로 드롭한다.

my $chunked = "POST / HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n"
            . "Connection: close\r\n\r\n5\r\nhello\r\n0\r\n\r\n";
$resp = raw_request($PORT_ON, $chunked);
is($resp, '', '크기를 모르는 청크 본문은 스캐너 차단 우선으로 드롭된다');

# --- 로그로 교차 확인 --------------------------------------------------------

select undef, undef, undef, 0.5;

my $access_log = read_file($access);
my $error_log  = read_file($error);

my $st413 = () = $access_log =~ /st=413 /g;
my $st999 = () = $access_log =~ /st=999 /g;
is($st413, 3, '413 이 3건 접근로그에 남는다(a, d, f)');
is($st999, 5, '드롭 5건이 접근로그에 999 로 남는다(b, c, e, g, h)');

like($error_log, qr{dropped by drop_all}, '기존 드롭 로그 형식은 그대로다');
like($error_log, qr{client intended to send too large body}, '413 사유가 오류로그에 남는다');

done_testing();
