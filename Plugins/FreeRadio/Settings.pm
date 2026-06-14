package Plugins::FreeRadio::Settings;

use strict;
use base qw(Slim::Web::Settings);

use Slim::Utils::Prefs;

my $prefs = preferences('plugin.freeradio');

sub name {
	return Slim::Web::HTTP::CSRF->protectName('PLUGIN_FREERADIO');
}

sub page {
	return Slim::Web::HTTP::CSRF->protectURI('plugins/FreeRadio/settings/basic.html');
}

sub prefs {
	return ($prefs, qw(refresh_interval_mins shoutcast_api_key));
}

sub handler {
	my ($class, $client, $params, $callback, @args) = @_;

	my $body = $class->SUPER::handler($client, $params, $callback, @args);

	if ($params->{saveSettings}) {
		require Plugins::FreeRadio::Plugin;
		Plugins::FreeRadio::Plugin->scheduleRefresh();
	}

	if ($params->{syncNow}) {
		require Plugins::FreeRadio::Plugin;
		Plugins::FreeRadio::Plugin::triggerSync();
	}

	return $body;
}

1;
