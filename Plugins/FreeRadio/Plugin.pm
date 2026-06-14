package Plugins::FreeRadio::Plugin;

use strict;

use base qw(Slim::Plugin::OPMLBased);

use File::Spec::Functions qw(catfile catdir);
use Scalar::Util qw(blessed);

use Slim::Utils::Log;
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

sub initPlugin {
	my ($class) = @_;

	Slim::Utils::Strings::loadFile(catfile($pluginDir, 'strings.txt'));

	$prefs->init({
		shoutcast_api_key     => '',
		initial_sync_done     => 0,
	});

	$store = Plugins::FreeRadio::Store->new(log => $log);
	$cache = Plugins::FreeRadio::Cache->new(size => 300, default_ttl => 300);
	$index = Plugins::FreeRadio::Index->new(store => $store, log => $log);
	$search = Plugins::FreeRadio::Search->new(store => $store, cache => $cache, log => $log);

	@providers = (
		Plugins::FreeRadio::Provider::Icecast->new(log => $log),
		Plugins::FreeRadio::Provider::Shoutcast->new(log => $log, prefs => $prefs),
	);

	if (main::WEBUI) {
		require Plugins::FreeRadio::Settings;
		Plugins::FreeRadio::Settings->new();
	}

	$class->SUPER::initPlugin(
		feed => \&handleFeed,
		tag  => 'freeradio',
		menu => 'radios',
	);

	Slim::Control::Request::addDispatch(
		[ 'freeradio', 'sync' ],
		[ 0, 0, 0, \&cliSync ]
	);

	# Register with scanner for import
	Slim::Music::Import->addScanType('freeradio', {
		cmd  => ['rescan', 'freeradio'],
		name => 'PLUGIN_FREERADIO',
	});

	# Trigger initial sync on startup
	Slim::Utils::Timers::setTimer(undef, time() + 2, \&triggerSync);
}

sub getDisplayName { 'PLUGIN_FREERADIO' }

sub triggerSync {
	my $cb = shift;
	$cb ||= sub {};

	if ($syncRunning) {
		main::DEBUGLOG && $log->is_debug && $log->debug('sync already running');
		$cb->();
		return;
	}

	$syncRunning = 1;
	my @queue = @providers;

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

		$provider->fetch_stations(
			sub {
				my $stations = shift || [];
				eval {
					$index->index_provider($pid, $stations);
					$store->set_sync_state("provider.$pid.last_success", time());
					$store->set_sync_state("provider.$pid.last_count", scalar @$stations);
					1;
				} or do {
					my $err = $@ || 'unknown indexing error';
					$log->error("failed indexing $pid: $err");
				};
				$next->();
			},
			sub {
				my $err = shift || 'unknown provider error';
				$log->warn("provider $pid failed: $err");
				$store->set_sync_state("provider.$pid.last_error", $err);
				$next->();
			}
		);
	};

	$next->();
}

sub cliSync {
	my $request = shift;
	triggerSync(sub { $request->setStatusDone() });
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
	};

	push @items, {
		name => cstring($client, 'PLUGIN_FREERADIO_BROWSE_GENRE'),
		type => 'link',
		url  => \&browseFieldValues,
		passthrough => [ { field => 'genre' } ],
	};

	push @items, {
		name => cstring($client, 'PLUGIN_FREERADIO_BROWSE_COUNTRY'),
		type => 'link',
		url  => \&browseFieldValues,
		passthrough => [ { field => 'country' } ],
	};

	push @items, {
		name => cstring($client, 'PLUGIN_FREERADIO_BROWSE_SOURCE'),
		type => 'link',
		url  => \&browseFieldValues,
		passthrough => [ { field => 'source' } ],
	};

	push @items, {
		name => cstring($client, 'PLUGIN_FREERADIO_FAVORITES'),
		type => 'link',
		url  => \&favoritesHandler,
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
	$cb->({ items => _station_items($client, $rows, 0) });
}

sub browseFieldValues {
	my ($client, $cb, $args, $pt) = @_;
	my $field = $pt->{field} || 'genre';
	my $values = $search->distinct_values($field);

	my @items = map {
		{
			name => $_,
			type => 'link',
			url  => \&browseFieldStations,
			passthrough => [ { field => $field, value => $_ } ],
		}
	} @$values;

	push @items, { type => 'text', name => cstring($client, 'EMPTY') } unless @items;
	$cb->({ items => \@items });
}

sub browseFieldStations {
	my ($client, $cb, $args, $pt) = @_;
	my $field = $pt->{field};
	my $value = $pt->{value};
	my %filters = ( $field => $value );
	my $rows = $search->search({ filters => \%filters, limit => 500, offset => 0 });
	$cb->({ items => _station_items($client, $rows, 0) });
}

sub favoritesHandler {
	my ($client, $cb) = @_;
	my $rows = $store->list_favorites();
	$cb->({ items => _station_items($client, $rows, 1) });
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

sub _station_items {
	my ($client, $rows, $favorite_context) = @_;
	my @items;

	for my $row (@{$rows || []}) {
		my $line2 = join(' · ', grep { $_ } ($row->{country}, $row->{genre}, uc($row->{source} || '')));
		my $description = $row->{description} || $line2;

		my @subItems = ({
			type    => 'audio',
			name    => cstring($client, 'PLAY'),
			line1   => $row->{name},
			line2   => $description,
			url     => $row->{stream_url},
			bitrate => $row->{bitrate} || 0,
		});

		if (!$favorite_context) {
			push @subItems, {
				type => 'link',
				name => cstring($client, 'PLUGIN_FREERADIO_ADD_FAVORITE'),
				url  => \&addFavoriteHandler,
				passthrough => [ { uid => $row->{uid} } ],
			};
		}
		else {
			push @subItems, {
				type => 'link',
				name => cstring($client, 'PLUGIN_FREERADIO_REMOVE_FAVORITE'),
				url  => \&removeFavoriteHandler,
				passthrough => [ { uid => $row->{uid} } ],
			};
		}

		push @items, {
			type  => 'link',
			name  => $row->{name},
			line1 => $row->{name},
			line2 => $line2,
			url   => sub {
				my ($c, $innerCb) = @_;
				$innerCb->({ items => \@subItems });
			},
		};
	}

	push @items, { type => 'text', name => cstring($client, 'EMPTY') } unless @items;
	return \@items;
}

1;
