use strict;
use warnings;

use File::Path qw(make_path);
use File::Spec;
use File::Temp qw(tempdir);
use IPC::Run3 qw(run3);
use IO::Socket::INET;
use POSIX qw(WNOHANG);
use Test::More;

my $prefix = $ENV{OPENRESTY_PREFIX} || '/usr/local/openresty';
my $nginx = $ENV{TEST_NGINX_BINARY};
if (!defined $nginx || $nginx eq '') {
    $nginx = File::Spec->catfile($prefix, 'bin', 'openresty');
    $nginx = File::Spec->catfile($prefix, 'nginx', 'sbin', 'nginx')
        unless -x $nginx;
}

plan skip_all => 'OpenResty binary is not available' unless -x $nginx;

# ssl_preread 는 원래 OpenSSL 이 거부하는 ClientHello 에서도 SNI 를 뽑아
# 라우팅하던 관대함이 있었다. 이 시험은 그 동작을 고정한다.
#   V1  정상                         -> SNI 추출 -> 백엔드 A
#   V2  session_id_len = 33          -> 거부     -> default B
#   V3  cipher_suites_len = 3 (홀수) -> 거부     -> default B
#   V4  cipher_suites_len = 0        -> 거부     -> default B
#   V5  compression_methods_len = 0  -> 거부     -> default B
#   V6  V1 3회 반복                   -> 3회 모두 A
# 패치 전 바이너리에서는 V2~V5 가 A 가 나와 FAIL 하고, 패치 후 B 가 나와 PASS 한다.

sub write_file {
    my ($path, $content) = @_;
    open my $fh, '>', $path or die "cannot write $path: $!";
    print {$fh} $content;
    close $fh;
}

# 임의 포트를 커널에게 받는다. 기존 시험의 고정 포트와 겹치지 않는다.
sub free_port {
    my $s = IO::Socket::INET->new(
        LocalAddr => '127.0.0.1',
        LocalPort => 0,
        Proto     => 'tcp',
        Listen    => 1,
        ReuseAddr => 1,
    ) or die "cannot allocate a free port: $!";
    my $port = $s->sockport;
    close $s;
    return $port;
}

my $PORT_S = free_port();
my $PORT_A = free_port();
my $PORT_B = free_port();

# 백엔드: 외부 프로그램 없이 이 시험 프로세스의 자식이 accept 하여
# 응답 한 줄을 쓰고 닫는다. 각 케이스가 새 연결을 쓰므로 반복 accept 한다.
sub start_backend {
    my ($tag) = @_;

    my $ls = IO::Socket::INET->new(
        LocalAddr => '127.0.0.1',
        LocalPort => 0,
        Proto     => 'tcp',
        Listen    => 16,
        ReuseAddr => 1,
    ) or die "cannot create backend listener: $!";

    my $port = $ls->sockport;
    my $pid = fork();
    die "cannot fork: $!" unless defined $pid;

    if ($pid == 0) {
        while (my $c = $ls->accept()) {
            print {$c} "$tag\n";
            close $c;
        }
        exit 0;
    }

    close $ls;
    return ($pid, $port);
}

my ($be_a_pid, $real_port_a) = start_backend('A');
my ($be_b_pid, $real_port_b) = start_backend('B');
$PORT_A = $real_port_a;
$PORT_B = $real_port_b;

my $dir = tempdir(CLEANUP => 1);
make_path(File::Spec->catdir($dir, 'logs'));

my $conf = File::Spec->catfile($dir, 'nginx.conf');
write_file($conf, <<"CONF");
worker_processes 1;
error_log logs/error.log info;
pid logs/nginx.pid;
daemon off;
events { worker_connections 64; }
stream {
    map \$ssl_preread_server_name \$be {
        a.example   127.0.0.1:$PORT_A;
        default     127.0.0.1:$PORT_B;
    }
    server {
        listen 127.0.0.1:$PORT_S;
        ssl_preread on;
        proxy_pass \$be;
    }
}
CONF

my ($tin, $tout, $terr) = ('', '', '');
run3([$nginx, '-p', "$dir/", '-c', $conf, '-t'], \$tin, \$tout, \$terr);
ok($? == 0, 'stream ssl_preread 설정이 유효하다') or diag($tout . $terr);

sub start_nginx {
    my $pid = fork();
    die "cannot fork: $!" unless defined $pid;

    if ($pid == 0) {
        exec $nginx, '-p', "$dir/", '-c', $conf;
        exit 1;
    }

    for (1 .. 100) {
        my $s = IO::Socket::INET->new(
            PeerAddr => '127.0.0.1',
            PeerPort => $PORT_S,
            Proto    => 'tcp',
            Timeout  => 1,
        );
        if ($s) {
            close $s;
            return $pid;
        }
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
    for my $pid ($be_a_pid, $be_b_pid) {
        next unless $pid;
        kill 'TERM', $pid;
        for (1 .. 20) {
            last if waitpid($pid, WNOHANG) == $pid;
            select undef, undef, undef, 0.1;
        }
        kill 'KILL', $pid;
        waitpid($pid, 0);
    }
    $? = 0;
}

if (!$nginx_pid) {
    fail('nginx 기동 실패');
    fail('V1~V6 시험 불가') for 1 .. 7;
    done_testing();
    exit;
}

# ClientHello 조립. 모든 길이 필드는 그 케이스의 실제 바이트 길이에서
# 매번 다시 계산한다 (고정 상수를 박으면 V2~V5 가 깨진다).
#
# SNI(server_name, type=0):
#   HostName        = 00 09 . "a.example"        (length 9 + 9 bytes = 11)
#   ServerName      = 00 . HostName              (name_type + 11 = 12)
#   ServerNameList  = 00 0C . ServerName         (list len 12 + 12 = 14)
#   extension_data  = 위 14바이트
#   extension       = 00 00 . 00 0E . extension_data (type, len, 14 bytes)
sub build_client_hello {
    my (%p) = @_;

    my $host = 'a.example';    # 9 bytes
    my $hostname = pack('n', length $host) . $host;
    my $server_name = "\x00" . $hostname;
    my $name_list = pack('n', length $server_name) . $server_name;
    my $sni_ext = pack('nn', 0x0000, length $name_list) . $name_list;

    my $body = pack('n', 0x0303)                       # client_version
        . ("\x00" x 32)                                 # random
        . pack('C', $p{sid_len}) . ("\x00" x $p{sid_len})
        . pack('n', $p{cs_len})  . ("\x00" x $p{cs_len})
        . pack('C', $p{cm_len})  . ("\x00" x $p{cm_len})
        . pack('n', length $sni_ext) . $sni_ext;        # extensions

    my $handshake = "\x01" . substr(pack('N', length $body), 1) . $body;
    my $record = "\x16\x03\x01" . substr(pack('N', length $handshake), 2)
               . $handshake;
    return $record;
}

sub probe {
    my ($hello) = @_;

    my $s = IO::Socket::INET->new(
        PeerAddr => '127.0.0.1',
        PeerPort => $PORT_S,
        Proto    => 'tcp',
        Timeout  => 5,
    ) or return '<connect-failed>';

    print {$s} $hello;

    my $got = '';
    eval {
        local $SIG{ALRM} = sub { die "timeout\n" };
        alarm 5;
        while (length $got < 2) {
            my $buf = '';
            my $n = sysread($s, $buf, 1024);
            last if !defined $n || $n == 0;
            $got .= $buf;
        }
        alarm 0;
    };
    alarm 0;
    close $s;

    $got =~ s/\r?\n\z//;
    return $got;
}

sub hello_for {
    my (%over) = @_;
    return build_client_hello(
        sid_len => 32,
        cs_len  => 2,
        cm_len  => 1,
        %over,
    );
}

my $v1 = hello_for();
my $v2 = hello_for(sid_len => 33);
my $v3 = hello_for(cs_len  => 3);
my $v4 = hello_for(cs_len  => 0);
my $v5 = hello_for(cm_len  => 0);

is(probe($v1), 'A', 'V1 정상 ClientHello: SNI 로 A 로 라우팅된다');
is(probe($v2), 'B', 'V2 session_id_len=33: SNI 미추출 -> default B');
is(probe($v3), 'B', 'V3 cipher_suites_len=3: SNI 미추출 -> default B');
is(probe($v4), 'B', 'V4 cipher_suites_len=0: SNI 미추출 -> default B');
is(probe($v5), 'B', 'V5 compression_methods_len=0: SNI 미추출 -> default B');

for my $i (1 .. 3) {
    is(probe($v1), 'A', "V6 정상 라우팅 반복 $i/3: A");
}

done_testing();
