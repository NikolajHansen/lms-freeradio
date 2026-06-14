package Plugins::FreeRadio::Provider::Icecast;

use strict;

use base qw(Plugins::FreeRadio::Provider::Base);

sub provider_id { 'icecast' }
sub provider_name { 'Icecast' }

sub fetch_stations {
	my ($self, $cb, $eb) = @_;
	$cb ||= sub {};
	$eb ||= sub {};

	my $url = 'https://dir.xiph.org/yp.xml';
	$self->_fetch_xml(
		$url,
		sub {
			my $xml = shift || {};
			my $entries = $xml->{entry} || $xml->{station} || [];
			$entries = [$entries] if ref($entries) eq 'HASH';

			my @stations;
			for my $entry (@$entries) {
				next unless ref $entry eq 'HASH';
				my $stream = $entry->{listen_url} || $entry->{stream_url} || $entry->{url};
				next unless $stream;

				push @stations, {
					source_id   => $entry->{server_name} || $entry->{listen_url} || $entry->{stream_url},
					name        => $entry->{server_name} || $entry->{title} || $entry->{name} || 'Icecast Station',
					description => $entry->{server_description} || $entry->{description} || '',
					country     => $entry->{country} || '',
					genre       => $entry->{genre} || '',
					stream_url  => $stream,
					codec       => $entry->{server_type} || $entry->{codec} || '',
					bitrate     => $entry->{bitrate} || 0,
					homepage    => $entry->{server_url} || $entry->{homepage} || '',
					network     => $entry->{network} || '',
					channel     => $entry->{channel} || '',
				};
			}

			$cb->(\@stations);
		},
		$eb,
	);
}

1;
