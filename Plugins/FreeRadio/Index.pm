package Plugins::FreeRadio::Index;

use strict;

use Digest::SHA qw(sha1_hex);
use JSON::PP qw(encode_json);

sub new {
	my ($class, %args) = @_;
	return bless {
		store => $args{store},
		log   => $args{log},
	}, $class;
}

sub index_provider {
	my ($self, $provider_id, $stations) = @_;
	$stations ||= [];

	my @normalized;
	for my $item (@$stations) {
		my $station = $self->normalize_station($provider_id, $item);
		next unless $station;
		push @normalized, $station;
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
	my $country = _trim($raw->{country});
	my $genre = _trim($raw->{genre});
	my $network = _trim($raw->{network});
	my $channel = _trim($raw->{channel});
	my $description = _trim($raw->{description});
	my $codec = _trim($raw->{codec});
	my $homepage = _trim($raw->{homepage});
	my $bitrate = $raw->{bitrate};
	$bitrate = int($bitrate || 0);

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
	my $uid = sha1_hex($uid_basis);

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
		raw_payload  => encode_json($raw),
	};
}

sub _trim {
	my ($value) = @_;
	return '' unless defined $value;
	$value =~ s/^\s+|\s+$//g;
	return $value;
}

1;
