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

				# XML::Simple parses empty elements as {} and elements with
				# attributes as { content => 'value', attr => ... }.
				# _xml_text() extracts the plain string in both cases.
				my $stream = _xml_text($entry->{listen_url})
				          || _xml_text($entry->{stream_url})
				          || _xml_text($entry->{url});
				next unless $stream && $stream =~ m{^https?://}i;

				push @stations, {
					source_id   => _xml_text($entry->{server_name}) || $stream,
					name        => _xml_text($entry->{server_name}) || _xml_text($entry->{title}) || _xml_text($entry->{name}) || 'Icecast Station',
					description => _xml_text($entry->{server_description}) || _xml_text($entry->{description}) || '',
					country     => _xml_text($entry->{country}) || '',
					genre       => _xml_text($entry->{genre}) || '',
					stream_url  => $stream,
					codec       => _xml_text($entry->{server_type}) || _xml_text($entry->{codec}) || '',
					bitrate     => int(_xml_text($entry->{bitrate}) || 0),
					homepage    => _xml_text($entry->{server_url}) || _xml_text($entry->{homepage}) || '',
					network     => _xml_text($entry->{network}) || '',
					channel     => _xml_text($entry->{channel}) || '',
				};
			}

			$cb->(\@stations, {
				total_available => scalar(@stations),
			});
		},
		$eb,
	);
}

# Extract a plain string from an XML::Simple value.
# Empty elements arrive as {} (empty hashref).
# Elements with attributes arrive as { content => 'text', attr => ... }.
# Plain text elements arrive as a scalar string.
sub _xml_text {
	my ($val) = @_;
	return '' unless defined $val;
	return ref($val) eq 'HASH' ? ($val->{content} || '') : "$val";
}

1;
