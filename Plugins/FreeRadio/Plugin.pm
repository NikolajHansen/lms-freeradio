package Plugins::FreeRadio::Plugin;

use strict;

use base qw(Slim::Plugin::OPMLBased);

use File::Spec::Functions qw(catfile catdir);
use Scalar::Util qw(blessed);

use Slim::Utils::Log;
use Slim::Menu::TrackInfo;
use Slim::Utils::Prefs;
use Slim::Utils::Strings qw(cstring string);
use Slim::Utils::Timers;

use Plugins::FreeRadio::Cache;
use Plugins::FreeRadio::Index;
use Plugins::FreeRadio::Search;
use Plugins::FreeRadio::Store;
use Plugins::FreeRadio::Provider::Icecast;
use Plugins::FreeRadio::Provider::Shoutcast;

our $pluginDir;
BEGIN {
	$pluginDir = $INC{'Plugins/FreeRadio/Plugin.pm'};
	$pluginDir =~ s/Plugin.pm$//;
}

my $log = Slim::Utils::Log->addLogCategory({
	category     => 'plugin.freeradio',
	defaultLevel => 'INFO',
	description  => 'PLUGIN_FREERADIO',
});

my $prefs = preferences('plugin.freeradio');

my $store;
my $cache;
my $search;
my $index;
my @providers;
my $syncRunning = 0;

sub _init_runtime {
	$prefs->init({
		shoutcast_api_key => '',
		initial_sync_done => 0,
		enable_icecast    => 1,
		enable_shoutcast  => 1,
		include_genres    => '',
		exclude_genres    => '',
		include_countries => '',
		exclude_countries => '',
	});

	$store ||= Plugins::FreeRadio::Store->new(log => $log);
	$cache ||= Plugins::FreeRadio::Cache->new(size => 300, default_ttl => 300);
	$index ||= Plugins::FreeRadio::Index->new(store => $store, log => $log);
	$search ||= Plugins::FreeRadio::Search->new(store => $store, cache => $cache, log => $log);

	if (!@providers) {
		@providers = (
			Plugins::FreeRadio::Provider::Icecast->new(log => $log),
			Plugins::FreeRadio::Provider::Shoutcast->new(log => $log, prefs => $prefs),
		);
	}
}

sub initPlugin {
	my ($class) = @_;

	Slim::Utils::Strings::loadFile(catfile($pluginDir, 'strings.txt'));

	require Plugins::FreeRadio::Importer;
	Plugins::FreeRadio::Importer->initPlugin();

	# Scanner process only needs importer registration.
	return if main::SCANNER;

	_init_runtime();

	if (main::WEBUI) {
		require Plugins::FreeRadio::Settings;
		Plugins::FreeRadio::Settings->new();
	}

	$class->SUPER::initPlugin(
		feed => \&handleFeed,
		tag  => 'freeradio',
		menu => 'radios',
		weight => 2,
	);

	Slim::Menu::TrackInfo->registerInfoProvider( freeradio => (
		after => 'playitem',
		func  => \&trackInfoHandler,
	) );

	Slim::Control::Request::addDispatch(
		[ 'freeradio', 'sync' ],
		[ 0, 0, 0, \&cliSync ]
	);

	# Context menu (right-arrow / more) for a single station: Add/Remove Favorite.
	Slim::Control::Request::addDispatch(
		[ 'freeradio', 'stationcontext' ],
		[ 1, 1, 1, \&stationContextCLI ]
	);
}

sub getDisplayName { 'PLUGIN_FREERADIO' }

sub playerMenu { 'RADIO' }

sub requestScannerSync {
	my ($cb) = @_;
	$cb ||= sub {};

	# In scanner.pl context, run directly.
	if (main::SCANNER) {
		triggerSync($cb);
		return;
	}

	# In server context, only queue scanner work.
	Slim::Control::Request::executeRequest(undef, [ 'rescan', 'external', 'file:///freeradio' ]);
	$cb->();
}

sub triggerSync {
	my ($cb, $opts) = @_;
	$cb ||= sub {};
	$opts ||= {};
	my $on_progress = $opts->{on_progress} || sub {};

	# Never run fetch/index pipeline in server process.
	if (!main::SCANNER) {
		requestScannerSync($cb);
		return;
	}

	_init_runtime();

	if ($syncRunning) {
		main::DEBUGLOG && $log->is_debug && $log->debug('sync already running');
		$cb->();
		return;
	}

	$syncRunning = 1;
	my @queue = grep { _provider_enabled($_->provider_id) } @providers;
	$on_progress->({
		event => 'start',
		providers_total => scalar @queue,
	});

	my $finish = sub {
		$syncRunning = 0;
		$prefs->set('initial_sync_done', 1);
		$search->clear_cache();
		$cb->();
	};

	my $next;
	$next = sub {
		my $provider = shift @queue;
		if (!$provider) {
			$finish->();
			return;
		}

		my $pid = $provider->provider_id;
		main::INFOLOG && $log->is_info && $log->info("syncing provider $pid");
		$on_progress->({
			event    => 'provider_start',
			provider => $pid,
		});

		$provider->fetch_stations(
			sub {
				my ($stations, $meta) = @_;
				$stations ||= [];
				$meta ||= {};
				my $raw_count = scalar @$stations;
				$stations = _apply_station_filters($stations);
				my $filtered_count = scalar @$stations;
				$on_progress->({
					event           => 'provider_fetched',
					provider        => $pid,
					raw_count       => $raw_count,
					filtered_count  => $filtered_count,
					total_available => $meta->{total_available},
				});

				eval {
					$index->index_provider($pid, $stations, sub {
						my ($station) = @_;
						$on_progress->({
							event   => 'station_indexed',
							provider => $pid,
							station => $station,
						});
					});
					$store->set_sync_state("provider.$pid.last_success", time());
					$store->set_sync_state("provider.$pid.last_count", $filtered_count);
					$store->set_sync_state("provider.$pid.last_total_available", $meta->{total_available} || $filtered_count);
					1;
				} or do {
					my $err = $@ || 'unknown indexing error';
					$log->error("failed indexing $pid: $err");
				};
				$on_progress->({
					event   => 'provider_done',
					provider => $pid,
					count   => $filtered_count,
				});
				$next->();
			},
			sub {
				my $err = shift || 'unknown provider error';
				$log->warn("provider $pid failed: $err");
				$store->set_sync_state("provider.$pid.last_error", $err);
				$on_progress->({
					event   => 'provider_error',
					provider => $pid,
					error   => $err,
				});
				$next->();
			}
		);
	};

	$next->();
}

sub clear_library_data {
	_init_runtime();
	$store->clear_stations();
	$store->clear_sync_state();
	$search->clear_cache();
}

sub cliSync {
	my $request = shift;
	requestScannerSync(sub { $request->setStatusDone() });
}

sub handleFeed {
	my ($client, $cb, $args) = @_;
	my $items = _root_menu($client);
	$cb->({ items => $items });
}

sub _root_menu {
	my ($client) = @_;
	my $count = $store->count_stations();
	my @items;

	if (!$count) {
		push @items, {
			type => 'textarea',
			name => cstring($client, 'PLUGIN_FREERADIO_INDEXING_HINT'),
		};
	}

	push @items, {
		name => cstring($client, 'PLUGIN_FREERADIO_SEARCH'),
		type => 'search',
		url  => \&searchHandler,
		image => 'html/images/search.png',
		weight => 10,
	};

	push @items, {
		name => cstring($client, 'PLUGIN_FREERADIO_BROWSE_GENRE'),
		type => 'link',
		url  => \&browseFieldValues,
		passthrough => [ { field => 'genre' } ],
		image => '/plugins/TuneIn/html/images/radiomusic.png',
		weight => 20,
	};

	push @items, {
		name => cstring($client, 'PLUGIN_FREERADIO_BROWSE_COUNTRY'),
		type => 'link',
		url  => \&browseFieldValues,
		passthrough => [ { field => 'country' } ],
		image => '/plugins/TuneIn/html/images/radioworld.png',
		weight => 30,
	};

	push @items, {
		name => cstring($client, 'PLUGIN_FREERADIO_BROWSE_SOURCE'),
		type => 'link',
		url  => \&browseFieldValues,
		passthrough => [ { field => 'source' } ],
		image => '/plugins/TuneIn/html/images/radio.png',
		weight => 40,
	};

	push @items, {
		name => cstring($client, 'PLUGIN_FREERADIO_BROWSE_STATION_NAME'),
		type => 'link',
		url  => \&browseFieldValues,
		passthrough => [ { field => 'station_name' } ],
		image => '/plugins/TuneIn/html/images/radio.png',
		weight => 45,
	};

	push @items, {
		name => cstring($client, 'PLUGIN_FREERADIO_BROWSE_BITRATE_QUALITY'),
		type => 'link',
		url  => \&browseFieldValues,
		passthrough => [ { field => 'bitrate_quality' } ],
		image => '/plugins/TuneIn/html/images/radiomusic.png',
		weight => 47,
	};

	push @items, {
		name => cstring($client, 'PLUGIN_FREERADIO_BROWSE_FORMAT'),
		type => 'link',
		url  => \&browseFieldValues,
		passthrough => [ { field => 'codec' } ],
		image => '/plugins/TuneIn/html/images/radiomusic.png',
		weight => 48,
	};

	push @items, {
		name => cstring($client, 'PLUGIN_FREERADIO_FAVORITES'),
		type => 'link',
		url  => \&favoritesHandler,
		image => '/plugins/TuneIn/html/images/radiopresets.png',
		weight => 50,
	};

	return \@items;
}

sub searchHandler {
	my ($client, $cb, $args) = @_;
	my $query = $args->{search} || '';
	$query =~ s/^\s+|\s+$//g;

	if (!$query) {
		$cb->({ items => [ { type => 'text', name => cstring($client, 'PLUGIN_FREERADIO_ENTER_SEARCH') } ] });
		return;
	}

	$store->record_search($query);
	my $rows = $search->search({ query => $query, limit => 200, offset => 0 });
	$cb->({ items => _station_items($client, $rows) });
}

sub browseFieldValues {
	my ($client, $cb, $args, $pt) = @_;
	my $field = $pt->{field} || 'genre';
	my @items;

	if ($field eq 'genre') {
		my $genres = $search->indexed_genres();
		@items = map {
			{
				name => "$_->{genre_label} ($_->{station_count})",
				type => 'link',
				url  => \&browseFieldStations,
				passthrough => [ { field => $field, value => $_->{genre_label}, genre_key => $_->{genre_key} } ],
			}
		} @$genres;
	}
	elsif ($field eq 'station_name') {
		my $station_names = $search->indexed_station_names();
		@items = map {
			{
				name => "$_->{station_name_label} ($_->{station_count})",
				type => 'link',
				url  => \&browseFieldStations,
				passthrough => [ { field => $field, value => $_->{station_name_label}, station_name_key => $_->{station_name_key} } ],
			}
		} @$station_names;
	}
	elsif ($field eq 'bitrate_quality') {
		my $quality = $search->indexed_bitrate_quality();
		@items = map {
			{
				name => "$_->{quality_label} ($_->{station_count})",
				type => 'link',
				url  => \&browseFieldStations,
				passthrough => [ { field => $field, value => $_->{quality_label}, quality_key => $_->{quality_key} } ],
			}
		} @$quality;
	}
	elsif ($field eq 'codec') {
		my $codecs = $search->indexed_codecs();
		@items = map {
			{
				name => "$_->{codec_label} ($_->{station_count})",
				type => 'link',
				url  => \&browseFieldStations,
				passthrough => [ { field => $field, value => $_->{codec_label}, codec_key => $_->{codec_key} } ],
			}
		} @$codecs;
	}
	else {
		my $values = $search->distinct_values($field);
		@items = map {
			{
				name => $_,
				type => 'link',
				url  => \&browseFieldStations,
				passthrough => [ { field => $field, value => $_ } ],
			}
		} @$values;
	}

	push @items, { type => 'text', name => cstring($client, 'EMPTY') } unless @items;
	$cb->({ items => \@items });
}

sub browseFieldStations {
	my ($client, $cb, $args, $pt) = @_;
	my $field = $pt->{field};
	my $value = $pt->{value};
	my $rows;

	if ($field eq 'genre' && defined $pt->{genre_key} && length $pt->{genre_key}) {
		$rows = $search->search_by_genre_key(
			genre_key => $pt->{genre_key},
			limit     => 500,
			offset    => 0,
		);
	}
	elsif ($field eq 'station_name' && defined $pt->{station_name_key} && length $pt->{station_name_key}) {
		$rows = $search->search_by_station_name_key(
			station_name_key => $pt->{station_name_key},
			limit            => 500,
			offset           => 0,
		);
	}
	elsif ($field eq 'bitrate_quality' && defined $pt->{quality_key} && length $pt->{quality_key}) {
		$rows = $search->search_by_quality_key(
			quality_key => $pt->{quality_key},
			limit       => 500,
			offset      => 0,
		);
	}
	elsif ($field eq 'codec' && defined $pt->{codec_key} && length $pt->{codec_key}) {
		$rows = $search->search_by_codec_key(
			codec_key => $pt->{codec_key},
			limit     => 500,
			offset    => 0,
		);
	}
	else {
		my %filters = ( $field => $value );
		$rows = $search->search({ filters => \%filters, limit => 500, offset => 0 });
	}

	$cb->({ items => _station_items($client, $rows) });
}

sub favoritesHandler {
	my ($client, $cb) = @_;
	my $rows = $store->list_favorites();
	$cb->({ items => _station_items($client, $rows) });
}

sub addFavoriteHandler {
	my ($client, $cb, $args, $pt) = @_;
	my $uid = $pt->{uid};
	if ($uid) {
		$store->add_favorite($uid);
	}
	$cb->({ items => [ { type => 'text', name => cstring($client, 'PLUGIN_FREERADIO_FAVORITE_ADDED') } ] });
}

sub removeFavoriteHandler {
	my ($client, $cb, $args, $pt) = @_;
	my $uid = $pt->{uid};
	if ($uid) {
		$store->remove_favorite($uid);
	}
	$cb->({ items => [ { type => 'text', name => cstring($client, 'PLUGIN_FREERADIO_FAVORITE_REMOVED') } ] });
}

sub stationContextCLI {
	my $request = shift;
	my $client  = $request->client();
	my $uid     = $request->getParam('uid');

	_init_runtime() unless $store;
	$request->setStatusProcessing();

	_stationContextItems($client, sub {
		my $feed = shift;
		$feed->{'type'} ||= 'opml';
		$request->setRawResults($feed);
		$request->setStatusDone();
	}, $uid);
}

sub _stationContextItems {
	my ($client, $cb, $uid) = @_;

	_init_runtime() unless $store;

	my @items;
	if ($store && $store->is_favorite($uid)) {
		push @items, {
			type => 'link',
			name => cstring($client, 'PLUGIN_FREERADIO_REMOVE_FAVORITE'),
			url  => sub {
				my ($client2, $cb2) = @_;
				$store->remove_favorite($uid);
				$cb2->({ items => [{ type => 'text', name => cstring($client2, 'PLUGIN_FREERADIO_FAVORITE_REMOVED') }] });
			},
		};
	}
	else {
		push @items, {
			type => 'link',
			name => cstring($client, 'PLUGIN_FREERADIO_ADD_FAVORITE'),
			url  => sub {
				my ($client2, $cb2) = @_;
				$store->add_favorite($uid);
				$cb2->({ items => [{ type => 'text', name => cstring($client2, 'PLUGIN_FREERADIO_FAVORITE_ADDED') }] });
			},
		};
	}
	$cb->({ items => \@items, isContextMenu => 1 });
}

sub trackInfoHandler {
	my ($client, $url, $track) = @_;

	return unless $url;
	my $station = $store->get_station_by_stream_url($url);
	return unless $station;

	return {
		name => cstring($client, 'PLUGIN_FREERADIO_TRACKINFO_OPTIONS'),
		url  => \&trackInfoMenu,
		passthrough => [ { uid => $station->{uid} } ],
	};
}

sub trackInfoMenu {
	my ($client, $cb, $args, $pt) = @_;
	my $uid = $pt->{uid};
	my $station = $store->get_station_by_uid($uid);

	if (!$station) {
		$cb->({ items => [ { type => 'text', name => cstring($client, 'EMPTY') } ] });
		return;
	}

	my @items = ({
		type    => 'audio',
		name    => cstring($client, 'PLAY'),
		line1   => $station->{name},
		line2   => join(' · ', grep { $_ } ($station->{country}, $station->{genre}, uc($station->{source} || ''))),
		url     => $station->{stream_url},
		bitrate => $station->{bitrate} || 0,
	});

	if ($store->is_favorite($uid)) {
		push @items, {
			type => 'link',
			name => cstring($client, 'PLUGIN_FREERADIO_REMOVE_FAVORITE'),
			url  => \&removeFavoriteHandler,
			passthrough => [ { uid => $uid } ],
		};
	}
	else {
		push @items, {
			type => 'link',
			name => cstring($client, 'PLUGIN_FREERADIO_ADD_FAVORITE'),
			url  => \&addFavoriteHandler,
			passthrough => [ { uid => $uid } ],
		};
	}

	$cb->({ items => \@items });
}

sub _provider_enabled {
	my ($provider_id) = @_;
	return $prefs->get('enable_icecast')   ? 1 : 0 if $provider_id eq 'icecast';
	return $prefs->get('enable_shoutcast') ? 1 : 0 if $provider_id eq 'shoutcast';
	return 1;
}

sub _parse_filter_values {
	my ($raw) = @_;
	return {} unless defined $raw && length $raw;
	my %set = map { lc($_) => 1 } grep { length $_ } map {
		s/^\s+|\s+$//gr
	} split(/[,\n\r]+/, $raw);
	return \%set;
}

sub _station_allowed {
	my ($station, $include_genres, $exclude_genres, $include_countries, $exclude_countries) = @_;
	my $genre = lc(($station->{genre} // '') =~ s/^\s+|\s+$//gr);
	my $country = lc(($station->{country} // '') =~ s/^\s+|\s+$//gr);

	return 0 if %$exclude_genres && $genre && $exclude_genres->{$genre};
	return 0 if %$exclude_countries && $country && $exclude_countries->{$country};
	return 0 if %$include_genres && (!$genre || !$include_genres->{$genre});
	return 0 if %$include_countries && (!$country || !$include_countries->{$country});
	return 1;
}

sub _apply_station_filters {
	my ($stations) = @_;
	$stations ||= [];

	my $include_genres = _parse_filter_values($prefs->get('include_genres'));
	my $exclude_genres = _parse_filter_values($prefs->get('exclude_genres'));
	my $include_countries = _parse_filter_values($prefs->get('include_countries'));
	my $exclude_countries = _parse_filter_values($prefs->get('exclude_countries'));

	return $stations
		if !%$include_genres && !%$exclude_genres && !%$include_countries && !%$exclude_countries;

	my @filtered = grep {
		_station_allowed($_, $include_genres, $exclude_genres, $include_countries, $exclude_countries)
	} @$stations;

	return \@filtered;
}

sub _station_items {
	my ($client, $rows) = @_;
	my @items;

	for my $row (@{$rows || []}) {
		my $line2 = join(' · ', grep { $_ } ($row->{country}, $row->{genre}, uc($row->{source} || '')));

		push @items, {
			type    => 'audio',
			name    => $row->{name},
			line1   => $row->{name},
			line2   => $line2,
			url     => $row->{stream_url},
			bitrate => $row->{bitrate} || 0,
			# play/add/insert actions so Jive players have explicit controls
			itemActions => {
				play => {
					command     => [ 'playlist', 'play' ],
					fixedParams => { url => $row->{stream_url} },
					nextWindow  => 'nowPlaying',
				},
				add => {
					command     => [ 'playlist', 'add' ],
					fixedParams => { url => $row->{stream_url} },
				},
				insert => {
					command     => [ 'playlist', 'insert' ],
					fixedParams => { url => $row->{stream_url} },
				},
				# info maps to actions.more (right-arrow context menu)
				info => {
					command     => [ 'freeradio', 'stationcontext' ],
					fixedParams => { uid => $row->{uid} },
				},
			},
		};
	}

	push @items, { type => 'text', name => cstring($client, 'EMPTY') } unless @items;
	return \@items;
}

1;
