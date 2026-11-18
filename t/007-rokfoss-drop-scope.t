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
#   1) drop_all 이 꺼진 곳: 비정상 입력(400 등)은 순정 nginx 처럼 오류 페이지로
#      나가고 접근로그에도 원래 코드가 남는다. error_page 도 정상 동작한다.
#   2) drop_all 이 켜진 곳: 같은 입력이 응답 없이 끊기고 접근로그에 999 가 남는다.
#   3) 백포트 da92f58: 콜론 없는 헤더 줄은 400 으로 거부된다.

my $PORT_OFF    = 19851;
my $PORT_ON     = 19852;
my $PORT_CUSTOM = 19853;

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
# drop_all 이 켜진 곳은 아무 바이트도 오지 않고 연결이 닫힌다.
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
        listen 127.0.0.1:$PORT_OFF;
        location / { return 200 "OK"; }
    }
    server {
        listen 127.0.0.1:$PORT_ON;
        drop_all on;
        location / { return 200 "NEVER"; }
    }
    server {
        listen 127.0.0.1:$PORT_CUSTOM;
        error_page 400 /e400;
        location /e400 { return 200 "CUSTOM-400"; }
        location / { return 200 "OK"; }
    }
}
CONF

my $nginx_pid = start_nginx($dir, $conf, $PORT_OFF);
plan skip_all => 'cannot start nginx' unless $nginx_pid;

END {
    stop_nginx($nginx_pid) if $nginx_pid;
}

my $access = File::Spec->catfile($dir, 'logs', 'access.log');
my $error  = File::Spec->catfile($dir, 'logs', 'error.log');

# 요청줄이 깨진 요청: 파싱 단계에서 400 이 된다.
my $broken = "BADREQUEST\r\n\r\n";

# 콜론 없는 헤더 줄(da92f58 이 거부해야 하는 형태)
my $colonless = "GET / HTTP/1.1\r\nHost: x\r\nX-Foo bar\r\nConnection: close\r\n\r\n";

# 정상 요청
my $normal = "GET / HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n";

# --- drop_all 이 꺼진 서버: 순정 nginx 동작 --------------------------------

my $resp = raw_request($PORT_OFF, $broken);
like($resp, qr{^HTTP/1\.1 400 }, 'drop_all 없음: 깨진 요청줄이 400 으로 응답한다');
like($resp, qr{<html lang="ko">}, 'drop_all 없음: 한국어 오류 페이지 본문이 나간다');

$resp = raw_request($PORT_CUSTOM, $broken);
like($resp, qr{CUSTOM-400}, 'drop_all 없음: error_page 400 이 동작한다');

$resp = raw_request($PORT_OFF, $colonless);
like($resp, qr{^HTTP/1\.1 400 }, '콜론 없는 헤더 줄은 400 으로 거부된다(da92f58)');
unlike($resp, qr{CUSTOM-400}, '콜론 없는 헤더는 커스텀 페이지가 아닌 기본 오류로 끝난다');

$resp = raw_request($PORT_OFF, $normal);
like($resp, qr{^HTTP/1\.1 200 }, '정상 헤더 요청은 200 으로 통과한다');

# --- drop_all 이 켜진 서버 -------------------------------------------------

$resp = raw_request($PORT_ON, $broken);
is($resp, '', 'drop_all 켜짐: 깨진 요청줄은 응답 없이 끊긴다');

$resp = raw_request($PORT_ON, $colonless);
is($resp, '', 'drop_all 켜짐: 콜론 없는 헤더도 응답 없이 끊긴다');

# --- 로그로 교차 확인 -----------------------------------------------------

select undef, undef, undef, 0.5;

my $access_log = read_file($access);
like($access_log, qr{st=400 }, 'drop_all 없음: 접근로그에 원래 코드 400 이 남는다');
like($access_log, qr{st=999 }, 'drop_all 켜짐: 접근로그에 999 가 남는다');

my $error_log = read_file($error);
like($error_log, qr{client sent invalid method while reading client request line},
     '깨진 요청줄은 파서가 거부한 것으로 기록된다');
like($error_log, qr{client sent invalid header line},
     '콜론 없는 헤더 줄은 헤더 파서가 거부한 것으로 기록된다');

done_testing();
