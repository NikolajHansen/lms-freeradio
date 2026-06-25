#!/usr/bin/perl
use strict;
use warnings;
use FindBin qw($Bin);
use lib "$Bin", "$Bin/../Plugins", "$Bin/lib";
use Test::More;

use FreeRadio::TestStubs;

# Load Index module with FreeRadio in @INC
use lib "$Bin/..";
require Plugins::FreeRadio::Index;

my $idx = Plugins::FreeRadio::Index->new(store => undef, log => undef);

# ------------------------------------------------------------------
# _normalize_codec
# ------------------------------------------------------------------
subtest 'codec normalization' => sub {
    my @tests = (
        [ 'audio/mpeg',               'MP3'  ],
        [ 'audio/mp3',                'MP3'  ],
        [ 'application/mp3',          'MP3'  ],
        [ 'mp3',                      'MP3'  ],
        [ '"audio/mpeg"',             'MP3'  ],  # with quotes
        [ 'audio/mpeg; charset=UTF-8','MP3'  ],  # with parameter
        [ 'audio/aac',                'AAC'  ],
        [ 'audio/aacp',               'AAC'  ],
        [ 'audio/aacp; charset=UTF-8','AAC'  ],
        [ 'audio/mp4',                'AAC'  ],
        [ 'audio/x-m4a',              'AAC'  ],
        [ 'application/aacp',         'AAC'  ],
        [ 'application/ogg',          'OGG'  ],
        [ 'audio/ogg',                'OGG'  ],
        [ 'audio/opus',               'OPUS' ],
        [ 'audio/flac',               'FLAC' ],
        [ 'video/webm',               'WebM' ],
        [ 'application/octet-stream', ''     ],  # binary junk
        [ 'Radio TETEVEN-48 kbps',    ''     ],  # station name as codec
        [ '',                         ''     ],
        [ undef,                      ''     ],
    );

    for my $t (@tests) {
        my ($input, $expected) = @$t;
        my $station = $idx->normalize_station('icecast', {
            name       => 'Test',
            stream_url => 'http://example.com/stream',
            codec      => $input,
        });
        my $got = $station->{codec} // '';
        is($got, $expected, "codec '${\($input//'undef')}' -> '$expected'");
    }
};

# ------------------------------------------------------------------
# _country_from_url
# ------------------------------------------------------------------
subtest 'country from URL TLD' => sub {
    my @tests = (
        [ 'http://radio.example.fr:8000/stream', 'France'          ],
        [ 'http://xfer.hirschmilch.de:8000/mp3', 'Germany'         ],
        [ 'http://stream.radio.nl:80/live',       'Netherlands'     ],
        [ 'http://example.dk/stream',             'Denmark'         ],
        [ 'http://radio.example.ru/live',         'Russia'          ],
        [ 'http://radio.example.com/stream',      ''                ],  # generic TLD
        [ 'http://192.168.1.1:8000/stream',       ''                ],  # IP address
        [ 'http://cdn.example.io/stream',         ''                ],  # io is skipped
        [ 'http://example.fm/stream',             ''                ],  # fm is skipped
        [ '',                                     ''                ],
    );

    for my $t (@tests) {
        my ($url, $expected) = @$t;
        my $station = $idx->normalize_station('icecast', {
            name       => 'Test',
            stream_url => $url || 'http://fallback.example.com/s',
            country    => '',
        });
        next unless $url;  # skip empty URL (would fail normalize_station)
        my $got = $station->{country} // '';
        is($got, $expected, "url '$url' -> country '$expected'");
    }
};

subtest 'country from metadata overrides URL TLD' => sub {
    my $station = $idx->normalize_station('icecast', {
        name       => 'Test',
        stream_url => 'http://example.de:8000/stream',
        country    => 'Denmark',  # explicit wins
    });
    is($station->{country}, 'Denmark', 'explicit country overrides TLD');
};

# ------------------------------------------------------------------
# genre normalization (AI tag bloat truncation)
# ------------------------------------------------------------------
subtest 'genre AI bloat truncation' => sub {
    my $long_genre = 'Big Room House Festival Anthems Massive Drops High Energy EDM ' .
                     'Uplifting Dancefloor Crowd-Pleaser Melodic Builds Powerful Bass';
    my $station = $idx->normalize_station('icecast', {
        name       => 'Test',
        stream_url => 'http://example.com/stream',
        genre      => $long_genre,
    });
    is($station->{genre}, 'Big', 'AI-bloat genre truncated to first token');

    my $short_genre = 'Pop Rock';
    $station = $idx->normalize_station('icecast', {
        name       => 'Test',
        stream_url => 'http://example.com/stream',
        genre      => $short_genre,
    });
    is($station->{genre}, 'Pop Rock', 'short genre kept as-is');

    my $exact50 = 'A' x 50;
    $station = $idx->normalize_station('icecast', {
        name       => 'Test',
        stream_url => 'http://example.com/stream',
        genre      => $exact50,
    });
    is($station->{genre}, $exact50, 'genre of exactly 50 chars kept');

    my $over50 = 'Jazz ' . ('B' x 46);
    $station = $idx->normalize_station('icecast', {
        name       => 'Test',
        stream_url => 'http://example.com/stream',
        genre      => $over50,
    });
    is($station->{genre}, 'Jazz', 'genre of 51+ chars truncated to first token');
};

# ------------------------------------------------------------------
# raw_payload is not present in normalized station
# ------------------------------------------------------------------
subtest 'no raw_payload in normalized station' => sub {
    my $station = $idx->normalize_station('icecast', {
        name       => 'Test',
        stream_url => 'http://example.com/stream',
        genre      => 'Pop',
    });
    ok(!exists $station->{raw_payload}, 'raw_payload not in normalized station hash');
};

# ------------------------------------------------------------------
# uid stability
# ------------------------------------------------------------------
subtest 'uid is stable for same input' => sub {
    my %raw = (name => 'Radio X', stream_url => 'http://example.com/stream', genre => 'Pop');
    my $s1 = $idx->normalize_station('icecast', \%raw);
    my $s2 = $idx->normalize_station('icecast', \%raw);
    is($s1->{uid}, $s2->{uid}, 'uid is deterministic');

    my $s3 = $idx->normalize_station('icecast', { %raw, name => 'Radio Y' });
    isnt($s1->{uid}, $s3->{uid}, 'different name produces different uid');
};

done_testing();
