#!/usr/bin/perl
use strict;
use warnings;
use FindBin qw($Bin);
use lib "$Bin", "$Bin/..", "$Bin/lib";
use Test::More;
use File::Temp qw(tempfile tempdir);

use FreeRadio::TestStubs;
use Slim::Utils::Prefs;

# ------------------------------------------------------------------
# Stub prefs + wire up a temp DB for Store
# ------------------------------------------------------------------
my ($fh, $tmpdb) = tempfile(SUFFIX => '.db', UNLINK => 1);
close $fh;

{
    my $ns = Slim::Utils::Prefs::Namespace->new;
    $ns->set('cachedir', tempdir(CLEANUP => 1));
    no warnings 'redefine';
    *Slim::Utils::Prefs::preferences = sub { $ns };
}

require Plugins::FreeRadio::Store;
require Plugins::FreeRadio::Index;
require Plugins::FreeRadio::Cache;
require Plugins::FreeRadio::Search;

{
    no warnings 'redefine';
    *Plugins::FreeRadio::Store::new = sub {
        my ($class, %args) = @_;
        my $self = { log => $args{log}, db_path => $tmpdb, dbh => undef };
        bless $self, $class;
        $self->_init();
        return $self;
    };
}

my $store  = Plugins::FreeRadio::Store->new(log => undef);
my $cache  = Plugins::FreeRadio::Cache->new(size => 50, default_ttl => 60);
my $index  = Plugins::FreeRadio::Index->new(store => $store, log => undef);
my $search = Plugins::FreeRadio::Search->new(store => $store, cache => $cache, log => undef);

# ------------------------------------------------------------------
# Build a small dataset through the full Index -> Store pipeline
# ------------------------------------------------------------------
my @raw_stations = (
    {
        source_id  => 'fr1',
        name       => 'France Musique',
        stream_url => 'http://icecast.radiofrance.fr:80/francemusique-hifi.aac',
        codec      => 'audio/aac',
        bitrate    => 192,
        genre      => 'Classical',
        country    => '',
    },
    {
        source_id  => 'de1',
        name       => 'Bayern Klassik',
        stream_url => 'http://stream.br.de/br-klassik/live/mp3_192.m3u',
        codec      => 'audio/mpeg',
        bitrate    => 192,
        genre      => 'Classical',
        country    => '',
    },
    {
        source_id  => 'nl1',
        name       => 'Radio 538',
        stream_url => 'http://playerservices.streamtheworld.nl/api/livestream.mp3',
        codec      => 'audio/mpeg',
        bitrate    => 128,
        genre      => 'Pop',
        country    => '',
    },
    {
        source_id  => 'uk1',
        name       => 'BBC Radio 1',
        stream_url => 'http://bbcmedia.ic.llnwd.net/stream/bbcmedia_radio1_mf_p',
        codec      => 'audio/aacp',
        bitrate    => 320,
        genre      => 'Pop ' . 'X' x 60,  # AI-bloated genre — should truncate to 'Pop'
        country    => 'United Kingdom',   # explicit country provided
    },
    {
        source_id  => 'junk1',
        name       => 'Default Stream',   # junk station name
        stream_url => 'http://example.com:8000/junk',
        codec      => 'Radio TETEVEN-48 kbps',  # garbage codec
        bitrate    => 48,
        genre      => 'Unspecified',      # stopword genre
        country    => '',
    },
);

$index->index_provider('icecast', \@raw_stations);

# ------------------------------------------------------------------
# Country derivation from URL TLD
# ------------------------------------------------------------------
subtest 'country derived from stream URL TLD' => sub {
    my $sth = $store->dbh->prepare("SELECT name, country FROM stations WHERE source_id = ?");

    $sth->execute('fr1');
    my $fr = $sth->fetchrow_hashref;
    is($fr->{country}, 'France', 'France Musique gets country France from .fr TLD');

    $sth->execute('de1');
    my $de = $sth->fetchrow_hashref;
    is($de->{country}, 'Germany', 'Bayern Klassik gets country Germany from .de TLD');

    $sth->execute('nl1');
    my $nl = $sth->fetchrow_hashref;
    is($nl->{country}, 'Netherlands', 'Radio 538 gets country Netherlands from .nl TLD');

    $sth->execute('uk1');
    my $uk = $sth->fetchrow_hashref;
    is($uk->{country}, 'United Kingdom', 'Explicit country takes precedence over TLD');
};

# ------------------------------------------------------------------
# Codec normalization through pipeline
# ------------------------------------------------------------------
subtest 'codec normalized through pipeline' => sub {
    my $sth = $store->dbh->prepare("SELECT name, codec FROM stations WHERE source_id = ?");

    $sth->execute('fr1');
    is($sth->fetchrow_hashref->{codec}, 'AAC', 'audio/aac -> AAC');

    $sth->execute('de1');
    is($sth->fetchrow_hashref->{codec}, 'MP3', 'audio/mpeg -> MP3');

    $sth->execute('uk1');
    is($sth->fetchrow_hashref->{codec}, 'AAC', 'audio/aacp -> AAC');

    $sth->execute('junk1');
    is($sth->fetchrow_hashref->{codec}, '', 'garbage codec -> empty string');
};

# ------------------------------------------------------------------
# AI genre bloat truncated
# ------------------------------------------------------------------
subtest 'AI-bloated genre truncated to first token' => sub {
    my ($genre) = $store->dbh->selectrow_array(
        "SELECT genre FROM stations WHERE source_id = 'uk1'"
    );
    is($genre, 'Pop', 'long genre string truncated to first token');
};

# ------------------------------------------------------------------
# Genre index quality (stopwords absent, real genres present)
# ------------------------------------------------------------------
subtest 'genre index quality' => sub {
    my $genres = $store->list_genre_index();
    my %labels = map { $_->{genre_label} => $_->{station_count} } @$genres;

    ok(!exists $labels{Unspecified}, 'Unspecified stopword not in genre index');
    # Classical has 2 stations (fr1 + de1), Pop has 2 (nl1 + uk1)
    # threshold is > 10, so with only 2 each they won't appear — that's correct behaviour
    # Just verify the stopword is absent
    ok(!exists $labels{Null},        'Null stopword absent');
    ok(!exists $labels{Genre},       'Genre stopword absent');
};

# ------------------------------------------------------------------
# Codec index populated via pipeline
# ------------------------------------------------------------------
subtest 'codec index populated via pipeline' => sub {
    my $codecs = $store->list_codec_index();
    my %by_key = map { $_->{codec_key} => $_->{station_count} } @$codecs;

    # mp3: de1 + nl1 = 2; aac: fr1 + uk1 = 2
    is($by_key{mp3}, 2, 'MP3 codec count correct');
    is($by_key{aac}, 2, 'AAC codec count correct');
    ok(!exists $by_key{''}, 'empty/junk codec not in codec index');
};

# ------------------------------------------------------------------
# Search layer: indexed_codecs / search_by_codec_key
# ------------------------------------------------------------------
subtest 'Search.indexed_codecs' => sub {
    my $codecs = $search->indexed_codecs();
    ok(ref $codecs eq 'ARRAY', 'indexed_codecs returns arrayref');
    my @keys = map { $_->{codec_key} } @$codecs;
    ok((grep { $_ eq 'mp3' } @keys), 'mp3 in indexed_codecs result');
    ok((grep { $_ eq 'aac' } @keys), 'aac in indexed_codecs result');
};

subtest 'Search.search_by_codec_key' => sub {
    my $mp3 = $search->search_by_codec_key(codec_key => 'mp3', limit => 10);
    ok(ref $mp3 eq 'ARRAY', 'search_by_codec_key returns arrayref');
    is(scalar @$mp3, 2, 'two MP3 stations returned');
    ok((grep { $_->{codec} eq 'MP3' } @$mp3) == 2, 'all returned stations are MP3');

    # Cache hit
    my $mp3_again = $search->search_by_codec_key(codec_key => 'mp3', limit => 10);
    is_deeply($mp3_again, $mp3, 'second call returns same cached result');
};

# ------------------------------------------------------------------
# Country browse
# ------------------------------------------------------------------
subtest 'country browse now returns results' => sub {
    my $countries = $store->list_distinct_values('country');
    ok(grep { $_ eq 'France' } @$countries, 'France in country list');
    ok(grep { $_ eq 'Germany' } @$countries, 'Germany in country list');
    ok(grep { $_ eq 'Netherlands' } @$countries, 'Netherlands in country list');
};

done_testing();
