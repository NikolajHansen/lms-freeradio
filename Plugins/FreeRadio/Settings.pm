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
	return ($prefs, qw(
		shoutcast_api_key
		enable_icecast
		enable_shoutcast
		include_genres
		exclude_genres
		include_countries
		exclude_countries
	));
}

sub handler {
	my ($class, $client, $params, $callback, @args) = @_;

	$params->{pref_enable_icecast}   = $params->{pref_enable_icecast}   ? 1 : 0;
	$params->{pref_enable_shoutcast} = $params->{pref_enable_shoutcast} ? 1 : 0;

	require Plugins::FreeRadio::Plugin;
	my $store = Plugins::FreeRadio::Plugin::get_store();

	if ($store && defined $params->{genres_text}) {
		my $text = $params->{genres_text};
		$prefs->set('canonical_genres_text', $text);
		$store->sync_canonical_genres($text);
	}

	if ($store) {
		$params->{genres_text} = $store->genres_as_text();
	}
	else {
		require Plugins::FreeRadio::Store;
		$params->{genres_text} = Plugins::FreeRadio::Store::DEFAULT_GENRES_TEXT;
	}

	return $class->SUPER::handler($client, $params, $callback, @args);
}

1;
