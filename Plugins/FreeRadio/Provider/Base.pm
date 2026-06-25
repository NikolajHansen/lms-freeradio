package Plugins::FreeRadio::Provider::Base;

use strict;

use JSON::PP qw(decode_json);
use HTTP::Tiny;
use XML::Simple;

use Slim::Networking::SimpleAsyncHTTP;

sub new {
	my ($class, %args) = @_;
	return bless {
		log   => $args{log},
		prefs => $args{prefs},
	}, $class;
}

sub provider_id {
	die 'provider_id() not implemented';
}

sub provider_name {
	die 'provider_name() not implemented';
}

sub fetch_stations {
	die 'fetch_stations() not implemented';
}

sub _fetch_text {
	my ($self, $url, $cb, $eb) = @_;
	$eb ||= sub {};

	# scanner.pl does not run the async server event loop - use blocking HTTP there.
	if (main::SCANNER) {
		my $http = HTTP::Tiny->new(
			timeout => 30,
		);
		my $res = $http->get($url);
		if ($res->{success}) {
			$cb->($res->{content});
		}
		else {
			my $err = $res->{status} ? "$res->{status} $res->{reason}" : 'http request failed';
			$eb->($err);
		}
		return;
	}

	Slim::Networking::SimpleAsyncHTTP->new(
		sub {
			my $http = shift;
			$cb->($http->content);
		},
		sub {
			my ($http, $error) = @_;
			$eb->($error || 'http request failed');
		},
		{ timeout => 30 }
	)->get($url);
}

sub _fetch_json {
	my ($self, $url, $cb, $eb) = @_;
	$self->_fetch_text(
		$url,
		sub {
			my $content = shift;
			my $decoded = eval { decode_json($content) };
			if ($@) {
				$eb->("invalid json from $url: $@");
				return;
			}
			$cb->($decoded);
		},
		$eb,
	);
}

sub _fetch_xml {
	my ($self, $url, $cb, $eb) = @_;
	$self->_fetch_text(
		$url,
		sub {
			my $content = shift;
			my $decoded = eval {
				XMLin($content, KeyAttr => [], ForceArray => [qw(entry station)]);
			};
			if ($@) {
				$eb->("invalid xml from $url: $@");
				return;
			}
			$cb->($decoded);
		},
		$eb,
	);
}

1;
