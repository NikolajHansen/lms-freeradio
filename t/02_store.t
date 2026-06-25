#!/usr/bin/perl
use strict;
use warnings;
use FindBin qw($Bin);
use lib "$Bin", "$Bin/..", "$Bin/lib";
use Test::More;
use File::Temp qw(tempfile);

use FreeRadio::TestStubs;
use Slim::Utils::Prefs;

# Point store at a temp DB
my ($fh, $tmpdb) = tempfile(SUFFIX => '.db', UNLINK => 1);
close $fh;

# Stub prefs to return our temp path
{
    no warnings 'redefine';
    my $ns = Slim::Utils::Prefs::Namespace->new;
    $ns->set('cachedir', (File::Temp::tempdir(CLEANUP => 1)));

    # Patch Store to use our temp DB directly
    *Slim::Utils::Prefs::preferences = sub {
        return $ns;
    };
}

# Override db path in Store by patching new()
require Plugins::FreeRadio::Store;
{
    no warnings 'redefine';
    my $orig_new = \&Plugins::FreeRadio::Store::new;
    *Plugins::FreeRadio::Store::new = sub {
        my ($class, %args) = @_;
        my $self = {
            log     => $args{log},
            db_path => $tmpdb,
            dbh     => undef,
        };
        bless $self, $class;
        $self->_init();
        return $self;
    };
}

my $store = Plugins::FreeRadio::Store->new(log => undef);
ok($store, 'Store created');

# ------------------------------------------------------------------
# Schema: raw_payload column should not exist
# ------------------------------------------------------------------
subtest 'schema has no raw_payload column' => sub {
    my $cols = $store->dbh->selectall_arrayref('PRAGMA table_info(stations)');
    my @names = map { $_->[1] } @$cols;
    ok(!grep { $_ eq 'raw_payload' } @names, 'raw_payload column absent from schema');
};

# ------------------------------------------------------------------
# Schema: codec index tables exist
# ------------------------------------------------------------------
subtest 'codec index tables exist' => sub {
    my $tables = $store->dbh->selectall_arrayref(
        "SELECT name FROM sqlite_master WHERE type='table' ORDER BY name"
    );
    my %t = map { $_->[0] => 1 } @$tables;
    ok($t{codec_index},         'codec_index table exists');
    ok($t{codec_station_index}, 'codec_station_index table exists');
};

# ------------------------------------------------------------------
# Helper: insert stations directly and rebuild indexes
# ------------------------------------------------------------------
sub _load_stations {
    my ($store, @stations) = @_;
    $store->replace_source_stations('test', \@stations);
}

# ------------------------------------------------------------------
# Genre index: stopwords excluded
# ------------------------------------------------------------------
subtest 'genre stopwords excluded from index' => sub {
    my @stations = map {
        {
            uid          => "uid-$_->[0]",
            source_id    => $_->[0],
            name         => "Station $_->[0]",
            genre        => $_->[1],
            bitrate      => 128,
            codec        => 'MP3',
            stream_url   => "http://example.com/$_->[0]",
            search_text  => "station $_->[0]",
            last_seen_at => time(),
        }
    } (
        [1, 'Pop'],
        [2, 'Pop'],
        [3, 'Pop'],
        [4, 'Pop'],
        [5, 'Pop'],
        [6, 'Pop'],
        [7, 'Pop'],
        [8, 'Pop'],
        [9, 'Pop'],
        [10, 'Pop'],
        [11, 'Pop'],  # 11 Pop stations to exceed threshold of 10
        [12, 'Null'],
        [13, 'Genre'],
        [14, 'Unspecified'],
        [15, 'Assorted'],
    );

    _load_stations($store, @stations);

    my $genres = $store->list_genre_index();
    my %genre_labels = map { $_->{genre_label} => 1 } @$genres;

    ok($genre_labels{Pop}, 'Pop genre is in index');
    ok(!$genre_labels{Null},        'Null stopword excluded');
    ok(!$genre_labels{Genre},       'Genre stopword excluded');
    ok(!$genre_labels{Unspecified}, 'Unspecified stopword excluded');
    ok(!$genre_labels{Assorted},    'Assorted stopword excluded');
};

# ------------------------------------------------------------------
# Station name index: junk defaults excluded
# ------------------------------------------------------------------
subtest 'station name junk excluded from index' => sub {
    my @stations = map {
        {
            uid          => "sn-uid-$_->[0]",
            source_id    => "sn-$_->[0]",
            name         => $_->[1],
            genre        => 'Rock',
            bitrate      => 128,
            codec        => 'MP3',
            stream_url   => "http://example.com/sn$_->[0]",
            search_text  => lc($_->[1]),
            last_seen_at => time(),
        }
    } (
        [1, 'Online Radio'],
        [2, 'Online Radio'],
        [3, 'Online Radio'],
        [4, 'Default Stream'],
        [5, 'Default Stream'],
        [6, 'Default Stream'],
        [7, 'My Station Name'],
        [8, 'My Station Name'],
        [9, 'My Station Name'],
        [10, 'Real Radio Berlin'],
        [11, 'Real Radio Berlin'],
        [12, 'Real Radio Berlin'],
    );

    _load_stations($store, @stations);

    my $names = $store->list_station_name_index();
    my %name_labels = map { lc($_->{station_name_label}) => 1 } @$names;

    ok(!$name_labels{'online radio'},    '"Online Radio" junk excluded');
    ok(!$name_labels{'default stream'},  '"Default Stream" junk excluded');
    ok(!$name_labels{'my station name'}, '"My Station Name" junk excluded');
    ok($name_labels{'real radio berlin'},'Real station name included');
};

# ------------------------------------------------------------------
# Codec index built correctly
# ------------------------------------------------------------------
subtest 'codec index populated' => sub {
    my @stations = map {
        {
            uid          => "codec-uid-$_->[0]",
            source_id    => "c-$_->[0]",
            name         => "Codec Test $_->[0]",
            genre        => 'Pop',
            bitrate      => 128,
            codec        => $_->[1],
            stream_url   => "http://example.com/codec$_->[0]",
            search_text  => "codec test",
            last_seen_at => time(),
        }
    } (
        [1, 'MP3'], [2, 'MP3'], [3, 'MP3'],
        [4, 'AAC'], [5, 'AAC'],
        [6, 'OGG'],
    );

    _load_stations($store, @stations);

    my $codecs = $store->list_codec_index();
    my %by_key = map { $_->{codec_key} => $_ } @$codecs;

    ok($by_key{mp3}, 'MP3 in codec index');
    is($by_key{mp3}{station_count}, 3, 'MP3 count correct');
    ok($by_key{aac}, 'AAC in codec index');
    is($by_key{aac}{station_count}, 2, 'AAC count correct');
    ok($by_key{ogg}, 'OGG in codec index');
};

# ------------------------------------------------------------------
# search_stations_by_codec_key
# ------------------------------------------------------------------
subtest 'search by codec key' => sub {
    my @stations = map {
        {
            uid          => "srch-codec-$_->[0]",
            source_id    => "sc-$_->[0]",
            name         => "Search Codec $_->[0]",
            genre        => 'Jazz',
            bitrate      => 128,
            codec        => $_->[1],
            stream_url   => "http://example.com/sc$_->[0]",
            search_text  => "search codec",
            last_seen_at => time(),
        }
    } ([1,'MP3'],[2,'MP3'],[3,'AAC']);

    _load_stations($store, @stations);

    my $mp3 = $store->search_stations_by_codec_key(codec_key => 'mp3', limit => 10);
    my $aac = $store->search_stations_by_codec_key(codec_key => 'aac', limit => 10);

    is(scalar @$mp3, 2, 'search_by_codec_key returns correct MP3 count');
    is(scalar @$aac, 1, 'search_by_codec_key returns correct AAC count');
    ok((grep { $_->{codec} eq 'MP3' } @$mp3) == 2, 'all returned stations have correct codec');
};

# ------------------------------------------------------------------
# count_stations / clear_stations
# ------------------------------------------------------------------
subtest 'count and clear stations' => sub {
    my $count = $store->count_stations();
    ok($count > 0, "count_stations > 0 ($count)");

    $store->clear_stations();
    is($store->count_stations(), 0, 'count_stations is 0 after clear');

    my ($ci) = $store->dbh->selectrow_array('SELECT COUNT(*) FROM codec_index');
    is($ci, 0, 'codec_index cleared');
};

done_testing();
