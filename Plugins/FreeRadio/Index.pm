package Plugins::FreeRadio::Index;

use strict;

use Encode qw(encode_utf8);
use Digest::SHA qw(sha1_hex);

sub new {
	my ($class, %args) = @_;
	return bless {
		store => $args{store},
		log   => $args{log},
	}, $class;
}

sub index_provider {
	my ($self, $provider_id, $stations, $on_indexed) = @_;
	$stations ||= [];
	$on_indexed ||= sub {};

	my @normalized;
	for my $item (@$stations) {
		my $station = $self->normalize_station($provider_id, $item);
		next unless $station;
		push @normalized, $station;
		$on_indexed->($station);
	}

	$self->{store}->replace_source_stations($provider_id, \@normalized);
}

sub normalize_station {
	my ($self, $provider_id, $raw) = @_;
	return unless $raw && ref $raw eq 'HASH';

	my $name = _trim($raw->{name});
	my $stream_url = _trim($raw->{stream_url} || $raw->{url});
	return unless $name && $stream_url;

	my $source_id = _trim($raw->{source_id});
	my $country   = _trim($raw->{country}) || _country_from_url($stream_url);
	my $genre     = _normalize_genre(_trim($raw->{genre}));
	my $network   = _trim($raw->{network});
	my $channel   = _trim($raw->{channel});
	my $description = _trim($raw->{description});
	my $codec     = _normalize_codec(_trim($raw->{codec}));
	my $homepage  = _trim($raw->{homepage});
	my $bitrate   = int($raw->{bitrate} || 0);

	my $search_text = join ' ', grep { $_ } map { lc($_) } (
		$name,
		$description,
		$country,
		$genre,
		$stream_url,
		$codec,
		$homepage,
		$network,
		$channel,
		$provider_id,
	);
	$search_text =~ s/\s+/ /g;

	if ($network || $channel) {
		my $suffix = join(' ', grep { $_ } ($network, $channel));
		if (!$description || $description !~ /\Q$suffix\E/i) {
			$description = join(' — ', grep { $_ } ($description, $suffix));
		}
	}

	my $uid_basis = join('|', map { defined $_ ? $_ : '' } (
		$provider_id,
		$source_id,
		$name,
		$stream_url,
		$network,
		$channel,
		$genre,
		$country,
	));
	my $uid = sha1_hex(encode_utf8($uid_basis));

	return {
		uid          => $uid,
		source_id    => $source_id,
		name         => $name,
		description  => $description,
		country      => $country,
		genre        => $genre,
		stream_url   => $stream_url,
		codec        => $codec,
		bitrate      => $bitrate,
		homepage     => $homepage,
		network      => $network,
		channel      => $channel,
		search_text  => $search_text,
		last_seen_at => time(),
	};
}

# Normalise MIME codec strings to clean display labels.
sub _normalize_codec {
	my ($raw) = @_;
	return '' unless defined $raw && length $raw;

	my $c = lc($raw);
	$c =~ s/^\s+|\s+$//g;
	$c =~ s/^["']+|["']+$//g;  # strip surrounding quotes
	$c =~ s/;.*$//;   # strip charset / parameter suffixes
	$c =~ s/\s+//g;

	return 'MP3'  if $c =~ /^(?:audio\/mpeg|audio\/mp3|application\/mp3|application\/mpeg|mp3)$/;
	return 'AAC'  if $c =~ /^(?:audio\/aac|audio\/aacp|audio\/mp4|audio\/x-m4a|application\/aacp|application\/aac)$/;
	return 'OGG'  if $c =~ /^(?:application\/ogg|audio\/ogg|video\/ogg)$/;
	return 'OPUS' if $c =~ /^audio\/opus$/;
	return 'FLAC' if $c eq 'audio/flac';
	return 'WebM' if $c =~ /^video\/webm$/;
	return '';    # unrecognised / station name injected as codec
}

# Guess country from a 2-letter ccTLD in the stream URL hostname.
my %_TLD_COUNTRY = (
	ad => 'Andorra',       ae => 'UAE',            al => 'Albania',
	am => 'Armenia',       ar => 'Argentina',      at => 'Austria',
	au => 'Australia',     az => 'Azerbaijan',     ba => 'Bosnia',
	be => 'Belgium',       bg => 'Bulgaria',       bh => 'Bahrain',
	bo => 'Bolivia',       br => 'Brazil',         by => 'Belarus',
	ca => 'Canada',        ch => 'Switzerland',    cl => 'Chile',
	cn => 'China',         co => 'Colombia',       cr => 'Costa Rica',
	cu => 'Cuba',          cy => 'Cyprus',         cz => 'Czech Republic',
	de => 'Germany',       dk => 'Denmark',        dz => 'Algeria',
	ec => 'Ecuador',       ee => 'Estonia',        eg => 'Egypt',
	es => 'Spain',         fi => 'Finland',        fr => 'France',
	ge => 'Georgia',       gr => 'Greece',         gt => 'Guatemala',
	hr => 'Croatia',       hu => 'Hungary',        id => 'Indonesia',
	ie => 'Ireland',       il => 'Israel',         in => 'India',
	iq => 'Iraq',          ir => 'Iran',           is => 'Iceland',
	it => 'Italy',         jo => 'Jordan',         jp => 'Japan',
	ke => 'Kenya',         kg => 'Kyrgyzstan',     kz => 'Kazakhstan',
	lb => 'Lebanon',       lt => 'Lithuania',      lu => 'Luxembourg',
	lv => 'Latvia',        ma => 'Morocco',        md => 'Moldova',
	me => 'Montenegro',    mk => 'North Macedonia', mn => 'Mongolia',
	mt => 'Malta',         mx => 'Mexico',         my => 'Malaysia',
	ng => 'Nigeria',       nl => 'Netherlands',    no => 'Norway',
	nz => 'New Zealand',   pa => 'Panama',         pe => 'Peru',
	ph => 'Philippines',   pk => 'Pakistan',       pl => 'Poland',
	pt => 'Portugal',      py => 'Paraguay',       qa => 'Qatar',
	ro => 'Romania',       rs => 'Serbia',         ru => 'Russia',
	sa => 'Saudi Arabia',  se => 'Sweden',         sg => 'Singapore',
	si => 'Slovenia',      sk => 'Slovakia',       sn => 'Senegal',
	th => 'Thailand',      tn => 'Tunisia',        tr => 'Turkey',
	tw => 'Taiwan',        ua => 'Ukraine',        ug => 'Uganda',
	uk => 'United Kingdom', us => 'USA',           uy => 'Uruguay',
	uz => 'Uzbekistan',    ve => 'Venezuela',      vn => 'Vietnam',
	za => 'South Africa',  zw => 'Zimbabwe',
);

sub _country_from_url {
	my ($url) = @_;
	return '' unless defined $url && length $url;
	# match the ccTLD just before the port or first path segment
	if ($url =~ m{://[^/?#]*\.([a-z]{2})(?::\d+)?(?:[/?#]|$)}i) {
		my $tld = lc($1);
		# skip common generic TLDs that happen to be 2 chars
		return '' if $tld =~ /^(?:js|pl|pm|sh|io|ai|co|tv|fm|am|me)$/;
		return $_TLD_COUNTRY{$tld} || '';
	}
	return '';
}

# Trim AI-generated keyword-stuffed genre strings to the first clean token.
sub _normalize_genre {
	my ($genre) = @_;
	return '' unless defined $genre && length $genre;
	return $genre if length($genre) <= 50;

	# Long strings are AI tag dumps — take only the first space/comma-separated token
	my ($first) = split /[\s,;\/|]+/, $genre;
	return defined $first ? $first : $genre;
}

sub _trim {
	my ($value) = @_;
	return '' unless defined $value;
	$value =~ s/^\s+|\s+$//g;
	return $value;
}

1;
