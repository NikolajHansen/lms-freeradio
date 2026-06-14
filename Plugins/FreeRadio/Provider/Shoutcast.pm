package Plugins::FreeRadio::Provider::Shoutcast;

use strict;

use base qw(Plugins::FreeRadio::Provider::Base);

sub provider_id { 'shoutcast' }
sub provider_name { 'Shoutcast' }

sub fetch_stations {
	my ($self, $cb, $eb) = @_;
	$cb ||= sub {};
	$eb ||= sub {};

	my $apiKey = $self->{prefs} ? ($self->{prefs}->get('shoutcast_api_key') || '') : '';
	$apiKey =~ s/^\s+|\s+$//g;

	if (!$apiKey) {
		# Skip SHOUTcast if no API key configured
		# Icecast provider will handle station listings instead
		main::INFOLOG && $self->{log}->is_info && $self->{log}->info('SHOUTcast API key not configured, skipping SHOUTcast provider');
		$cb->([]);
		return;
	}

	my $url = sprintf('https://api.shoutcast.com/station/advancedsearch?f=json&k=%s&limit=500', $apiKey);

	$self->_fetch_json(
		$url,
		sub {
			my $payload = shift || {};
			my $stations = _extract_stations($payload);
			$cb->($stations);
		},
		$eb,
	);
}

sub _extract_stations {
	my ($payload) = @_;
	my @found;
	_walk_payload($payload, \@found);

	my @stations;
	for my $entry (@found) {
		next unless ref $entry eq 'HASH';
		my $stream = $entry->{ct} && $entry->{id}
			? sprintf('https://yp.shoutcast.com/sbin/tunein-station.m3u?id=%s', $entry->{id})
			: ($entry->{stream_url} || $entry->{url} || '');
		next unless $stream;

		push @stations, {
			source_id   => $entry->{id} || $entry->{ID} || $entry->{station_id} || $stream,
			name        => $entry->{name} || $entry->{stationname} || 'SHOUTcast Station',
			description => $entry->{ct} || $entry->{description} || '',
			country     => $entry->{country} || $entry->{countrycode} || '',
			genre       => $entry->{genre} || $entry->{genre2} || '',
			stream_url  => $stream,
			codec       => $entry->{mt} || $entry->{codec} || '',
			bitrate     => $entry->{br} || $entry->{bitrate} || 0,
			homepage    => $entry->{homepage} || '',
			network     => $entry->{network} || 'SHOUTcast',
			channel     => $entry->{channel} || '',
		};
	}

	return \@stations;
}

sub _walk_payload {
	my ($value, $collector) = @_;

	if (ref($value) eq 'HASH') {
		if ($value->{station}) {
			my $stations = $value->{station};
			if (ref($stations) eq 'ARRAY') {
				push @$collector, @$stations;
			}
			elsif (ref($stations) eq 'HASH') {
				push @$collector, $stations;
			}
		}

		for my $k (keys %$value) {
			_walk_payload($value->{$k}, $collector);
		}
	}
	elsif (ref($value) eq 'ARRAY') {
		for my $entry (@$value) {
			_walk_payload($entry, $collector);
		}
	}
}

1;
