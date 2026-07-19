package Plugins::RadioHelsinki::Settings;

# Settings → Advanced → Radio Helsinki. Live-stream now-playing knobs (see
# Live.pm): the master switch (off = leave the stream to RadioNowPlaying or
# core ICY handling; applies at restart), the listening delay that shifts
# the progress bars from air-time to what the listener hears, the feed poll
# interval, and how long a song outlives its nominal length. Everything but
# the master switch applies within one poll cycle.

use strict;
use warnings;

use base qw(Slim::Web::Settings);

use Slim::Utils::Prefs;

my $prefs = preferences('plugin.radiohelsinki');

sub name {
	return Slim::Web::HTTP::CSRF->protectName('PLUGIN_RADIOHELSINKI');
}

sub page {
	return Slim::Web::HTTP::CSRF->protectURI('plugins/RadioHelsinki/settings/basic.html');
}

sub prefs {
	return ( $prefs, qw(livemeta listendelay pollinterval songgrace) );
}

sub handler {
	my ( $class, $client, $params ) = @_;

	# An unticked checkbox never reaches the server; normalise it to 0 so
	# saving actually turns the switch off.
	if ( $params->{saveSettings} ) {
		$params->{pref_livemeta} = $params->{pref_livemeta} ? 1 : 0;
	}

	return $class->SUPER::handler( $client, $params );
}

1;
