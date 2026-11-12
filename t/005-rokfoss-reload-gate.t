use strict;
use warnings;

use File::Path qw(make_path);
use File::Spec;
use File::Temp qw(tempdir);
use IPC::Run3 qw(run3);
use POSIX qw(WNOHANG);
use Test::More;

my $prefix = $ENV{OPENRESTY_PREFIX} || '/usr/local/openresty';
my $openresty = File::Spec->catfile($prefix, 'bin', 'openresty');

if (!-x $openresty) {
    $openresty = File::Spec->catfile($prefix, 'nginx', 'sbin', 'nginx');
}

plan skip_all => 'OpenResty binary is not available' unless -x $openresty;

# 오류 로그는 바이트로 오므로 비교용 문자열도 UTF-8 바이트로 만든다.
my $msg_ok = pack 'C*', 0xec, 0x84, 0xb1, 0xea, 0xb3, 0xb5;
my $msg_deny = pack 'C*', 0xea, 0xb1, 0xb0, 0xeb, 0xb6, 0x80;

# 더미 프로세스를 마스터인 것처럼 PID 파일에 기록한 뒤 신호를 보낸다.
# 더미가 죽었으면 신호가 전달된 것이고, 살아 있으면 전달되지 않은 것이다.
sub run_signal_test {
    my ($config, $signal, $files) = @_;

    my $dir = tempdir(CLEANUP => 1);
    my $logs = File::Spec->catdir($dir, 'logs');
    make_path($logs);

    if ($files) {
        while (my ($name, $content) = each %$files) {
            my $path = File::Spec->catfile($dir, $name);
            open my $fh, '>', $path or die "cannot write $path: $!";
            print {$fh} $content;
            close $fh;
        }
    }

    my $conf = File::Spec->catfile($dir, 'nginx.conf');
    open my $fh, '>', $conf or die "cannot write $conf: $!";
    print {$fh} $config;
    close $fh;

    my $dummy = fork();
    die "cannot fork: $!" unless defined $dummy;

    if ($dummy == 0) {
        exec 'sleep', '300';
        exit 1;
    }

    my $pid_file = File::Spec->catfile($logs, 'nginx.pid');
    open my $pfh, '>', $pid_file or die "cannot write $pid_file: $!";
    print {$pfh} "$dummy\n";
    close $pfh;

    my ($stdout, $stderr) = ('', '');
    my @cmd = ($openresty, '-p', "$dir/", '-c', $conf, '-s', $signal);
    run3 \@cmd, undef, \$stdout, \$stderr;
    my $exit = $? >> 8;

    # 신호를 받은 더미가 종료될 때까지 기다린다.
    # 부하가 높은 러너에서는 2초(0.1 x 20)로는 전달 확인을 놓치는 경우가 있어
    # 5초(0.1 x 50)로 넉넉히 잡는다. 신호를 보내지 않는 시험은 결과가 같다.
    my $delivered = 0;
    for (1 .. 50) {
        if (waitpid($dummy, WNOHANG) == $dummy) {
            $delivered = 1;
            last;
        }

        select undef, undef, undef, 0.1;
    }

    if (!$delivered) {
        kill 'KILL', $dummy;
        waitpid $dummy, 0;
    }

    return ($exit, $stdout, $stderr, $delivered, $conf);
}

my $base = <<'CONF';
worker_processes 1;
error_log stderr notice;
pid logs/nginx.pid;
events { worker_connections 16; }
CONF

{
    my ($exit, $stdout, $stderr, $delivered) = run_signal_test(
        $base . <<'CONF',
http {
    init_by_lua_block {
        local ok = true
    }
}
CONF
        'reload',
    );

    is $exit, 0, 'valid configuration allows a reload';
    ok $delivered, 'the reload signal reaches the master process';
    ok index($stderr, $msg_ok) >= 0, 'the passing check is reported';
}

{
    my ($exit, $stdout, $stderr, $delivered) = run_signal_test(
        $base . <<'CONF',
http {
    server {
        listen 127.0.0.1:8080;
        location / {
            content_by_lua_block {
                local broken =
            }
        }
    }
}
CONF
        'reload',
    );

    isnt $exit, 0, 'a Lua syntax error refuses the reload';
    ok !$delivered, 'no reload signal is sent when the Lua check fails';
    like $stderr, qr/Lua/, 'the Lua syntax error is reported';
    ok index($stderr, $msg_deny) >= 0, 'the refusal is reported';
}

{
    my ($exit, $stdout, $stderr, $delivered) = run_signal_test(
        $base . <<'CONF',
http {
    init_by_lua_file missing.lua;
}
CONF
        'reload',
    );

    isnt $exit, 0, 'a missing Lua file refuses the reload';
    ok !$delivered, 'no reload signal is sent when a Lua file is missing';
    ok index($stderr, $msg_deny) >= 0, 'the refusal is reported';
}

{
    my ($exit, $stdout, $stderr, $delivered) = run_signal_test(
        $base . <<'CONF',
http {
    server {
        listen 127.0.0.1:8080
        location / { return 200 "ok"; }
    }
}
CONF
        'reload',
    );

    isnt $exit, 0, 'an nginx syntax error refuses the reload';
    ok !$delivered, 'no reload signal is sent when the nginx syntax is invalid';
    ok index($stderr, $msg_deny) >= 0, 'the refusal is reported';
}

{
    my ($exit, $stdout, $stderr, $delivered) = run_signal_test(
        $base . <<'CONF',
http {
    server {
        listen 127.0.0.1:8080;
        location / {
            content_by_lua_block {
                local broken =
            }
        }
    }
}
CONF
        'stop',
    );

    ok $delivered, 'a Lua syntax error still allows the server to be stopped';
    unlike $stderr, qr/Lua/, 'the Lua check does not run for other signals';
}


{
    my ($exit, $stdout, $stderr, $delivered) = run_signal_test(
        $base . <<'CONF',
stream {
    server {
        listen 127.0.0.1:19005;
        content_by_lua_block {
            local broken =
        }
    }
}
CONF
        'reload',
    );

    isnt $exit, 0, 'a Stream Lua syntax error refuses the reload';
    ok !$delivered, 'no reload signal is sent when the Stream Lua check fails';
    like $stderr, qr/Stream Lua/, 'the Stream Lua syntax error is reported';
    ok index($stderr, $msg_deny) >= 0, 'the Stream Lua reload refusal is reported';
}

done_testing();
