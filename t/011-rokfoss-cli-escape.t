use strict;
use warnings;
use utf8;

use Encode qw(encode decode);
use File::Path qw(make_path);
use File::Spec;
use File::Temp qw(tempdir);
use IPC::Run3 qw(run3);
use Test::More;

my $prefix = $ENV{OPENRESTY_PREFIX} || '/usr/local/openresty';
my $binary = $ENV{TEST_NGINX_BINARY};

if (!defined $binary || $binary eq '') {
    $binary = File::Spec->catfile($prefix, 'bin', 'openresty');
    $binary = File::Spec->catfile($prefix, 'nginx', 'sbin', 'nginx')
        unless -x $binary;
}

binmode STDOUT, q{:utf8};
binmode STDERR, q{:utf8};
plan skip_all => 'OpenResty binary is not available' unless -x $binary;

my $dir = tempdir(CLEANUP => 1);
make_path(File::Spec->catdir($dir, 'logs'));

my $conf = "events {}\nhttp {}\n";

sub run_t {
    my ($name) = @_;

    my $path = File::Spec->catfile($dir, $name);
    open my $fh, '>', $path or die "cannot write $path: $!";
    print {$fh} $conf;
    close $fh;

    my ($stdout, $stderr) = ('', '');
    run3 [$binary, '-t', '-p', "$dir/", '-c', $path],
        undef, \$stdout, \$stderr;
    my $exit = $? >> 8;

    return ($path, $stdout, $stderr, $exit);
}

# (a) 개행이 든 경로: 두 메시지가 두 줄로만 나와야 한다.
{
    my ($path, $out, $err, $exit) = run_t("nl\nfake.conf");

    is($exit, 0, '(a) -t with newline in path succeeds');
    my $lines = () = $err =~ /\n/g;
    is($lines, 2, '(a) stderr has exactly two lines');
    ok(index($err, '\x0a') >= 0, '(a) newline is printed as \\x0a');
    ok($err !~ /\Q$path\E/, '(a) raw path with newline is not printed');
}

# (b) 0x01, 0x7f 가 든 경로: \xNN 으로 이스케이프되어야 한다.
{
    my ($path, $out, $err, $exit) = run_t("ctl\x01z\x7fq.conf");

    is($exit, 0, '(b) -t with control characters in path succeeds');
    ok(index($err, '\x01') >= 0, '(b) 0x01 is escaped');
    ok(index($err, '\x7f') >= 0, '(b) 0x7f is escaped');
    ok($err !~ /[\x01\x7f]/, '(b) no raw control byte in stderr');
}

# (c) 정상 경로: 기존 한국어 메시지가 그대로 나와야 한다.
{
    my ($path, $out, $err, $exit) = run_t('plain.conf');
    my $text = decode('UTF-8', $err);

    is($exit, 0, '(c) -t with normal path succeeds');
    ok(index($text, "설정 파일 ${path}의 문법이 올바릅니다") >= 0,
       '(c) syntax-ok Korean message unchanged');
    like($text, qr/설정 파일 \Q$path\E 검사가 .*성공했습니다/,
         '(c) test-success Korean message unchanged');
    my $lines = () = $err =~ /\n/g;
    is($lines, 2, '(c) normal path still produces two lines');
}

# (d) 한글 경로: UTF-8 바이트가 깨지지 않고 그대로 나와야 한다.
{
    my $kname = encode('UTF-8', '한글') . '.conf';
    my ($path, $out, $err, $exit) = run_t($kname);
    my $text = decode('UTF-8', $err);
    my $decoded_path = decode('UTF-8', $path);

    is($exit, 0, '(d) -t with Korean path succeeds');
    ok(index($text, "설정 파일 ${decoded_path}의 문법이 올바릅니다") >= 0,
       '(d) Korean path is printed intact');
    ok(index($err, '\x') < 0, '(d) UTF-8 bytes are not escaped');
}

done_testing();
