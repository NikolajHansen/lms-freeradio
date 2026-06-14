package Plugins::FreeRadio::Importer;

use strict;

use Slim::Utils::Progress;
use Slim::Utils::Log;

my $log = Slim::Utils::Log->addLogCategory({
	category     => 'plugin.freeradio',
	defaultLevel => 'INFO',
	description  => 'PLUGIN_FREERADIO',
});

sub initPlugin {
	my $class = shift;

	# don't run importer if we're doing a singledir scan (unless explicitly for freeradio)
	return if main::SCANNER && $ARGV[-1] && 'freeradio' ne $ARGV[-1];

	# Register this importer to be called during scanner runs
	Slim::Music::Import->addImporter($class, {
		type   => 'post',
		weight => 50,
		'use'  => 1,
	});

	main::INFOLOG && $log->is_info && $log->info('FreeRadio importer registered');
}

sub startScan {
	my ($class) = @_;

	main::INFOLOG && $log->is_info && $log->info('Starting FreeRadio sync');

	my $progress = Slim::Utils::Progress->new({
		'type'  => 'importer',
		'name'  => 'plugin_freeradio_sync',
		'total' => 1,
		'bar'   => 1,
		'every' => 1,
	});

	require Plugins::FreeRadio::Plugin;
	Plugins::FreeRadio::Plugin::triggerSync(sub {
		$progress->update('done');
		main::INFOLOG && $log->is_info && $log->info('FreeRadio sync completed');
	});
}

1;
