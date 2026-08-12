use strict;
use warnings;

use File::Path qw(make_path);
use File::Temp qw(tempdir);
use Test::More tests => 11;

my $root = tempdir(CLEANUP => 1);
my $bin = "$root/bin";
my $geoip = "$root/geoip";
my $counter = "$root/download-count";
make_path($bin);

my $wget = "$bin/wget";
open my $fh, '>', $wget or die "cannot create fake wget: $!";
print {$fh} <<'SH';
#!/bin/sh
set -eu
output=
url=
while [ "$#" -gt 0 ]; do
    case "$1" in
        -O)
            output=$2
            shift 2
            ;;
        http*)
            url=$1
            shift
            ;;
        *)
            shift
            ;;
    esac
done
count=0
if [ -f "$ROKFOSS_TEST_COUNTER" ]; then
    count=$(cat "$ROKFOSS_TEST_COUNTER")
fi
printf '%s\n' "$((count + 1))" > "$ROKFOSS_TEST_COUNTER"
case "$url" in
    *GeoLite2-City.mmdb) size=10000001 ;;
    *) size=1000001 ;;
esac
truncate -s "$size" "$output"
SH
close $fh;
chmod 0755, $wget or die "cannot chmod fake wget: $!";

my $mmdblookup = "$bin/mmdblookup";
open $fh, '>', $mmdblookup or die "cannot create fake mmdblookup: $!";
print {$fh} "#!/bin/sh\nexit 0\n";
close $fh;
chmod 0755, $mmdblookup or die "cannot chmod fake mmdblookup: $!";

local $ENV{PATH} = "$bin:$ENV{PATH}";
local $ENV{ROKFOSS_GEOIP_DIR} = $geoip;
local $ENV{ROKFOSS_GEOIP_BASE_URL} = 'https://example.invalid/download';
local $ENV{ROKFOSS_TEST_COUNTER} = $counter;

my $script = 'util/rokfoss-geoip2-init';

is(system($script), 0, 'first service start succeeds');
ok(-s "$geoip/GeoLite2-ASN.mmdb", 'ASN database installed');
ok(-s "$geoip/GeoLite2-City.mmdb", 'City database installed');
ok(-s "$geoip/GeoLite2-Country.mmdb", 'Country database installed');
is(read_counter(), 3, 'first service start downloads three files');

my @sizes = map { -s "$geoip/$_" }
    qw(GeoLite2-ASN.mmdb GeoLite2-City.mmdb GeoLite2-Country.mmdb);

is(system($script), 0, 'second service start succeeds');
is(read_counter(), 3, 'second service start downloads nothing');
is_deeply(
    [ map { -s "$geoip/$_" }
        qw(GeoLite2-ASN.mmdb GeoLite2-City.mmdb GeoLite2-Country.mmdb) ],
    \@sizes,
    'existing databases remain unchanged'
);

unlink "$geoip/GeoLite2-Country.mmdb"
    or die "cannot remove test Country database: $!";

is(system($script), 0, 'start with one missing database succeeds');
is(read_counter(), 4, 'only the missing database is downloaded');
ok(-s "$geoip/GeoLite2-Country.mmdb", 'missing database restored');

sub read_counter {
    open my $in, '<', $counter or die "cannot read counter: $!";
    my $value = <$in>;
    close $in;
    chomp $value;
    return 0 + $value;
}
