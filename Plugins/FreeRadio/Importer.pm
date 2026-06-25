package Plugins::FreeRadio::Importer;

use strict;

use File::Basename qw(dirname);
use File::Spec::Functions qw(catfile);

use Slim::Music::Import;
use Slim::Utils::Progress;
use Slim::Utils::Log;
use Slim::Utils::Strings;

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
	});
	$progress->update(Slim::Utils::Strings::string('PLUGIN_FREERADIO'));

	require Plugins::FreeRadio::Plugin;
	if ($main::wipe) {
		main::INFOLOG && $log->is_info && $log->info('Clear library requested - clearing FreeRadio index data');
		Plugins::FreeRadio::Plugin::clear_library_data();
	}

	# Throttle per-station progress updates — update every N stations to avoid
	# 33k+ DB writes while still showing a smoothly advancing bar.
	my $PROGRESS_INTERVAL = 250;
	my %provider_indexed;  # provider_id -> count

	eval {
		Plugins::FreeRadio::Plugin::triggerSync(
			sub {
				$progress->update(Slim::Utils::Strings::string('PLUGIN_FREERADIO_PROGRESS_DONE'));
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
						$provider_indexed{$provider} = 0;
						$progress->update(
							sprintf(Slim::Utils::Strings::string('PLUGIN_FREERADIO_PROGRESS_FETCHING'), $provider)
						);
						return;
					}

					if ($event->{event} eq 'provider_fetched') {
						my $provider = $event->{provider} || 'provider';
						my $count    = $event->{filtered_count} || 0;
						$progress->total($progress->total + $count);
						$progress->update(
							sprintf(Slim::Utils::Strings::string('PLUGIN_FREERADIO_PROGRESS_INDEXING'), $provider)
						);
						main::INFOLOG && $log->is_info && $log->info("Fetched $count stations from $provider");
						return;
					}

					if ($event->{event} eq 'station_indexed') {
						my $provider = $event->{provider} || '';
						$provider_indexed{$provider}++;
						# Only update the progress display every PROGRESS_INTERVAL stations
						# to avoid 33k+ DB writes that would slow down the scan.
						if ($provider_indexed{$provider} % $PROGRESS_INTERVAL == 0) {
							my $station = $event->{station} || {};
							my $name    = $station->{name} || '';
							$progress->update(
								sprintf(Slim::Utils::Strings::string('PLUGIN_FREERADIO_PROGRESS_INDEXING'),
									$name || $provider)
							);
						}
						return;
					}

					if ($event->{event} eq 'provider_done') {
						my $provider = $event->{provider} || 'provider';
						my $count    = $provider_indexed{$provider} || $event->{count} || 0;
						$progress->update(
							sprintf(Slim::Utils::Strings::string('PLUGIN_FREERADIO_PROGRESS_PROVIDER_DONE'),
								$count, $provider)
						);
						main::INFOLOG && $log->is_info && $log->info("Indexed $count stations from $provider");
						return;
					}

					if ($event->{event} eq 'provider_error') {
						my $provider = $event->{provider} || 'provider';
						$log->warn("Provider $provider failed: " . ($event->{error} || ''));
						$progress->update("$provider failed");
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
