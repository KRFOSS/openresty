use strict;
use warnings;

use File::Path qw(make_path);
use File::Spec;
use File::Temp qw(tempdir);
use IPC::Run3 qw(run3);
use Test::More;

my $prefix = $ENV{OPENRESTY_PREFIX} || '/usr/local/openresty';
my $nginx = File::Spec->catfile($prefix, 'nginx', 'sbin', 'nginx');
if (!-x $nginx) {
    $nginx = File::Spec->catfile($prefix, 'bin', 'openresty');
}

plan skip_all => 'nginx binary is not available' unless -x $nginx;

# 오류 로그는 바이트로 오므로 비교용 문자열도 UTF-8 바이트로 만든다.
my $kr_warn = pack 'C*', 0xec, 0x9c, 0x84, 0xed, 0x97, 0x98;   # 위험

sub conf_with {
    my ($body) = @_;
    return <<"CONF";
worker_processes 1;
error_log logs/error.log warn;
pid nginx.pid;
events { worker_connections 64; }
http {
    server {
        listen 127.0.0.1:19811;
        location / {
$body
        }
    }
}
CONF
}

# nginx -t 를 돌려 (종료코드, 출력전문) 을 돌려준다.
sub nginx_t {
    my ($body) = @_;

    my $dir = tempdir(CLEANUP => 1);
    make_path(File::Spec->catdir($dir, 'logs'));

    my $conf = File::Spec->catfile($dir, 'nginx.conf');
    open my $fh, '>', $conf or die "cannot write $conf: $!";
    print {$fh} conf_with($body);
    close $fh;

    my ($out, $err) = ('', '');
    run3([$nginx, '-p', $dir, '-c', $conf, '-t'], \undef, \$out, \$err);

    return ($? >> 8, ($out // '') . ($err // ''));
}

my @cases = (
    {
        name  => 'proxy_cache_key "$uri" 는 -t 를 통과하고 경고한다',
        body  => 'proxy_cache_key "$uri";',
        rc    => 0,
        warn  => 1,
        instr => 'proxy_cache_key',
    },
    {
        name  => 'proxy_cache_key "$request_uri" 는 경고하지 않는다',
        body  => 'proxy_cache_key "$scheme$proxy_host$request_uri";',
        rc    => 0,
        warn  => 0,
    },
    {
        name  => '중괄호 표기 ${uri} 도 경고한다',
        body  => 'proxy_cache_key "$scheme$host${uri}";',
        rc    => 0,
        warn  => 1,
    },
    {
        name  => '$document_uri 도 $uri 와 같이 경고한다',
        body  => 'proxy_cache_key "$document_uri";',
        rc    => 0,
        warn  => 1,
    },
    {
        name  => 'fastcgi_cache_key 에도 같은 경고가 적용된다',
        body  => 'fastcgi_cache_key "$uri"; fastcgi_pass 127.0.0.1:19812;',
        rc    => 0,
        warn  => 1,
        instr => 'fastcgi_cache_key',
    },
    {
        name  => 'cache_key 를 쓰지 않으면 경고하지 않는다',
        body  => 'proxy_pass http://127.0.0.1:19813;',
        rc    => 0,
        warn  => 0,
    },
    {
        name  => '헤더 값의 $uri 는 이 경고 대상이 아니다',
        body  => 'add_header X-Echo-U "$uri" always;',
        rc    => 0,
        warn  => 0,
    },
    {
        name  => '대문자 $URI 도 경고한다',
        body  => 'proxy_cache_key "$URI";',
        rc    => 0,
        warn  => 1,
        instr => 'proxy_cache_key',
    },
    {
        name  => '대문자 중괄호 표기 ${URI} 도 경고한다',
        body  => 'proxy_cache_key "${URI}";',
        rc    => 0,
        warn  => 1,
    },
    {
        name  => '$Document_URI 도 경고한다',
        body  => 'proxy_cache_key "$Document_URI";',
        rc    => 0,
        warn  => 1,
    },
    {
        name  => '$request_uri 는 경고하지 않는다',
        body  => 'proxy_cache_key "$request_uri";',
        rc    => 0,
        warn  => 0,
    },
    {
        name  => 'add_header X-Test 의 $uri 는 경고 대상이 아니다',
        body  => 'add_header X-Test "$uri";',
        rc    => 0,
        warn  => 0,
    },
);

plan tests => scalar @cases * 3;

for my $case (@cases) {
    my ($rc, $out) = nginx_t($case->{body});

    is($rc, $case->{rc}, "$case->{name} (종료코드)");

    my $seen = index($out, $kr_warn) >= 0 ? 1 : 0;
    is($seen, $case->{warn}, "$case->{name} (경고 유무)");

    if ($case->{instr}) {
        ok(index($out, $case->{instr}) >= 0, "$case->{name} (지시어 이름 표기)");
    }
    else {
        ok(1, "$case->{name} (지시어 이름 표기 없음)");
    }
}
