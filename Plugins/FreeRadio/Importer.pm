package Plugins::FreeRadio::Importer;

use strict;

use File::Basename qw(dirname);
use File::Spec::Functions qw(catfile);

use Slim::Music::Import;
use Slim::Utils::Progress;
use Slim::Utils::Log;

my $log = Slim::Utils::Log->addLogCategory({
	category     => 'plugin.freeradio',
	defaultLevel => 'INFO',
	description  => 'PLUGIN_FREERADIO',
});

sub initPlugin {
	my ($class) = @_;

	# When loaded directly by PluginManager in scanner context (via <importmodule>),
	# Plugin::initPlugin is not called, so we load strings ourselves.
	if (main::SCANNER) {
		my $stringsFile = catfile(dirname(__FILE__), 'strings.txt');
		Slim::Utils::Strings::loadFile($stringsFile) if -f $stringsFile;
	}

	Slim::Music::Import->addScanType('freeradio', {
		cmd  => ['rescan', 'external', 'file:///freeradio'],
		name => 'PLUGIN_FREERADIO',
	});

	# Register as a post importer so scanner.pl invokes this after library scan.
	Slim::Music::Import->addImporter($class, {
		type   => 'post',
		weight => 50,
		use          => 1,
	});
}

sub startScan {
	my ($class) = @_;
	my $scanToken = $ARGV[-1] || '';
	$scanToken =~ s!.*/!!;

	# Keep FreeRadio out of normal rescans; only run on dedicated token.
	if (main::SCANNER && $scanToken ne 'freeradio') {
		Slim::Music::Import->endImporter($class);
		return;
	}

	main::INFOLOG && $log->is_info && $log->info('Starting FreeRadio sync');

	my $progress = Slim::Utils::Progress->new({
		'type'  => 'importer',
		'name'  => 'plugin_freeradio_sync',
		'total' => 1,
		'bar'   => 1,
		'every' => 1,
	});
	$progress->update('Preparing FreeRadio sync');

	require Plugins::FreeRadio::Plugin;
	if ($main::wipe) {
		main::INFOLOG && $log->is_info && $log->info('Clear library requested - clearing FreeRadio index data');
		Plugins::FreeRadio::Plugin::clear_library_data();
	}

	eval {
		Plugins::FreeRadio::Plugin::triggerSync(
			sub {
				$progress->update('done');
				$progress->final();
				main::INFOLOG && $log->is_info && $log->info('FreeRadio sync completed');
				Slim::Music::Import->endImporter($class);
			},
			{
				on_progress => sub {
					my ($event) = @_;
					return unless $event && ref($event) eq 'HASH';

					if ($event->{event} eq 'start') {
						$progress->total($progress->total + ($event->{providers_total} || 0));
						return;
					}

					if ($event->{event} eq 'provider_start') {
						my $provider = $event->{provider} || 'provider';
						$progress->update("Fetching $provider stations");
						return;
					}

					if ($event->{event} eq 'provider_fetched') {
						my $provider = $event->{provider} || 'provider';
						my $count = $event->{filtered_count} || 0;
						$progress->total($progress->total + $count);
						main::INFOLOG && $log->is_info && $log->info("Fetched $count stations from $provider");
						return;
					}

					if ($event->{event} eq 'station_indexed') {
						my $station = $event->{station} || {};
						my $provider = $event->{provider} || '';
						my $name = $station->{name} || $provider || 'station';
						$progress->update($name);
						return;
					}

					if ($event->{event} eq 'provider_error') {
						my $provider = $event->{provider} || 'provider';
						$progress->update("Failed $provider");
						return;
					}
				},
			}
		);
		1;
	} or do {
		my $err = $@ || 'unknown sync error';
		$log->error("FreeRadio sync failed: $err");
		$progress->final();
		Slim::Music::Import->endImporter($class);
	};
}

1;
