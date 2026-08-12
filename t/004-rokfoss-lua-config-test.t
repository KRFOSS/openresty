use strict;
use warnings;

use File::Path qw(make_path);
use File::Spec;
use File::Temp qw(tempdir);
use IPC::Run3 qw(run3);
use Test::More;

my $prefix = $ENV{OPENRESTY_PREFIX} || '/usr/local/openresty';
my $openresty = File::Spec->catfile($prefix, 'bin', 'openresty');

if (!-x $openresty) {
    $openresty = File::Spec->catfile($prefix, 'nginx', 'sbin', 'nginx');
}

plan skip_all => 'OpenResty binary is not available' unless -x $openresty;

sub run_config_test {
    my ($config, $files) = @_;

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

    my ($stdout, $stderr) = ('', '');
    my @cmd = ($openresty, '-t', '-p', "$dir/", '-c', $conf);
    run3 \@cmd, undef, \$stdout, \$stderr;

    return ($? >> 8, $stdout, $stderr, $dir);
}

my $base = <<'CONF';
worker_processes 1;
error_log stderr notice;
pid logs/nginx.pid;
events { worker_connections 16; }
CONF

{
    my ($exit, $stdout, $stderr) = run_config_test(
        $base . <<'CONF'
http {
    init_by_lua_block {
        local ok = true
    }
}
CONF
    );

    is $exit, 0, 'valid inline Lua passes openresty -t';
}

{
    my ($exit, $stdout, $stderr) = run_config_test(
        $base . <<'CONF'
http {
    init_by_lua_block {
        local broken =
    }
}
CONF
    );

    isnt $exit, 0, 'invalid inline Lua fails openresty -t';
    like $stderr, qr/Lua/, 'inline Lua syntax error is reported';
}

{
    my ($exit, $stdout, $stderr, $dir) = run_config_test(
        $base . <<'CONF',
http {
    init_by_lua_file good.lua;
}
CONF
        { 'good.lua' => "local ok = true\n" },
    );

    is $exit, 0, 'valid static Lua file passes openresty -t';
}

{
    my ($exit, $stdout, $stderr) = run_config_test(
        $base . <<'CONF'
http {
    init_by_lua_file missing.lua;
}
CONF
    );

    isnt $exit, 0, 'missing static Lua file fails openresty -t';
    like $stderr, qr/Lua/, 'missing Lua file is reported';
}

{
    my ($exit, $stdout, $stderr) = run_config_test(
        $base . <<'CONF',
http {
    init_by_lua_file broken.lua;
}
CONF
        { 'broken.lua' => "local broken =\n" },
    );

    isnt $exit, 0, 'Lua syntax error in a static file fails openresty -t';
    like $stderr, qr/Lua/, 'external Lua syntax error is reported';
}

{
    my $dir = tempdir(CLEANUP => 1);
    my $marker = File::Spec->catfile($dir, 'must-not-exist');
    my $lua_marker = $marker;
    $lua_marker =~ s/\\/\\\\/g;
    $lua_marker =~ s/'/\\'/g;

    my ($exit, $stdout, $stderr) = run_config_test(
        $base . "http {\n"
        . "    init_by_lua_block {\n"
        . "        os.execute('touch $lua_marker')\n"
        . "    }\n"
        . "}\n"
    );

    is $exit, 0, 'valid Lua with runtime side effects still passes syntax test';
    ok !-e $marker, 'openresty -t compiles Lua without executing it';
}

done_testing();
