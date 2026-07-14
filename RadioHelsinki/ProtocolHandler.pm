package Plugins::RadioHelsinki::ProtocolHandler;

# The handler behind radiohelsinki:// — which exists for exactly one feature:
# remembering where you stopped in a two-hour programme.
#
# Plain https items never see the play lifecycle; only a track whose URL belongs
# to a registered protocol gets onStop (save the position) and scanUrl /
# getNextTrack (seek back to it). So API.pm wraps every episode URL as
# radiohelsinki://<https-url>, optionally suffixed {from=N} by the "resume from"
# menu row. Everything else — streaming, seeking, direct-stream negotiation — is
# inherited from the stock HTTPS handler once scanUrl has unwrapped the real URL.
#
# This is a port of Slim::Plugin::Podcast::ProtocolHandler, minus its %21/! URI
# workaround: our _safeUrl never emits %21 (it only encodes bytes outside
# \x21-\x7E), so the scan rabbit hole has nothing to mangle.

use strict;
use warnings;

use base qw(Slim::Player::Protocols::HTTPS);

use Slim::Player::ProtocolHandlers;
use Slim::Utils::Log;

use Plugins::RadioHelsinki::API;

my $log = logger('plugin.radiohelsinki');

Slim::Player::ProtocolHandlers->registerHandler( 'radiohelsinki', __PACKAGE__ );

# Strip the wrapper and scan the real https URL, then rename the scanned track
# back to the (clean) wrapped URL so every later lookup lands on this handler.
sub scanUrl {
	my ( $class, $url, $args ) = @_;

	my $song = $args->{song};
	my ( $httpUrl, $startTime ) = Plugins::RadioHelsinki::API::unwrapUrl($url);
	my $cb = $args->{cb};

	# The canonical playlist entry: no trailing {from=N}, so a favourite saved
	# from now-playing never fossilises an offset.
	$url = Plugins::RadioHelsinki::API::wrapUrl($httpUrl);

	# Just a marker for getNextTrack — the byte-offset conversion has to wait
	# until the scan has learned the track's bitrate and duration.
	$song->seekdata( { startTime => $startTime } ) if $startTime;

	$args->{cb} = sub {
		my $track = shift;

		if ($track) {
			main::INFOLOG && $log->is_info
				&& $log->info( "scanned $url => " . $track->url . ( $startTime ? " (resume from $startTime)" : '' ) );

			# Stream from the scanned URL (it may have followed redirects), but
			# ignore the scanned title/coverart — Metadata.pm owns those.
			$song->streamUrl( $track->url );
			$track->title( Slim::Music::Info::getCurrentTitle( $args->{client}, $url ) );
			$track->cover(0);

			# From now on every $url-based request resolves to this track.
			$track->url($url);

			# The web UI only refreshes the playlist when its timestamp moves.
			$song->master->currentPlaylistUpdateTime( Time::HiRes::time() );
		}

		$cb->( $track, @_ );
	};

	$class->SUPER::scanUrl( $httpUrl, $args );
}

sub new {
	my ( $class, $args ) = @_;

	# Open the socket on the real streaming URL — but not on a redirect, where
	# $args->{url} already is the redirect target.
	$args->{url} = $args->{song}->streamUrl unless $args->{redir};

	return $class->SUPER::new($args);
}

# Runs after scanUrl has updated $song->track, which is what makes the
# startTime -> byte-offset conversion possible (it needs bitrate + duration,
# via the inherited HTTP getSeekData). If the scan learned neither, the
# conversion yields undef and playback simply starts from the beginning.
sub getNextTrack {
	my ( $class, $song, $successCb, $errorCb ) = @_;

	if ( my $startTime = $song->seekdata && $song->seekdata->{startTime} ) {
		$song->seekdata( $song->getSeekData($startTime) );
		main::INFOLOG && $log->is_info && $log->info("starting from $startTime");
	}

	$successCb->();
}

# Slim::Formats::XML::getFeedAsync hands any non-http feed URL to its scheme's
# handler via this hook — which is what lets the Kesken and Viimeksi kuunnellut
# menus be favourited: the favourite stores radiohelsinki://kesken|recent, and
# opening it lands here, where the live list is served back as a full OPML
# feed. Any other URL is a plain wrapped episode: answer with the single-track
# array the play paths expect.
#
# Plugin.pm is referenced fully qualified, not use'd — it already use's this
# module, and by the time a favourite can be opened it is long loaded.
sub explodePlaylist {
	my ( $class, $client, $url, $cb ) = @_;

	if ( $url =~ m|^radiohelsinki://kesken$|i ) {
		return $cb->( Plugins::RadioHelsinki::Plugin::inProgressFeed($client) );
	}

	if ( $url =~ m|^radiohelsinki://recent$|i ) {
		return $cb->( Plugins::RadioHelsinki::Plugin::recentFeed($client) );
	}

	return $cb->( [$url] );
}

# Fired by the controller at every stream start — this is what feeds the
# "Viimeksi kuunnellut" list. Replays just refresh the timestamp.
sub onStream {
	my ( $self, $client, $song ) = @_;

	my ($url) = Plugins::RadioHelsinki::API::unwrapUrl( $song->currentTrack->url );

	Plugins::RadioHelsinki::API::recentAdd($url) if $url;
}

# A track that plays to its natural end never reaches onStop: the controller
# takes the _Stopped path, which fires no handler hook and rebuilds the song
# queue (so by notification time the elapsed clock reads zero and the FINISHED
# song object is already gone — there is nothing left to inspect). What the end
# of a track *does* fire, before any of that, is the decoder-done signal (STMd
# -> playerReadyToStream -> onPlayout) — the song is still playing out its last
# buffered seconds, so the live elapsed time sits within the output buffer of
# the duration and the onStop logic below lands in its "finished, forget the
# position" branch. Explicit stops never come this way, so nothing is saved or
# cleared twice with conflicting values.
sub onPlayout {
	my ( $class, $song, $controller ) = @_;

	$class->onStop($song);

	# Anything else would alter the controller's flow (Spotty returns 'return'
	# here to hijack it; we must not).
	return 0;
}

# The whole point. Called by the streaming controller whenever this track stops
# playing — pause is not stop, so pausing keeps the live elapsed time and this
# only fires when the slot is genuinely over (stop, track change, power off).
sub onStop {
	my ( $self, $song ) = @_;

	my $elapsed = $song->master->controller->playingSongElapsed;
	my ($url)   = Plugins::RadioHelsinki::API::unwrapUrl( $song->currentTrack->url );

	return unless $url;

	# The scan usually learned the duration even when the menu item had none
	# (podcasts and clips have begin == end in the API) — keep it, so the resume
	# row can be gated on "not practically finished" next time.
	Plugins::RadioHelsinki::API::setMetaDuration( $url, $song->duration ) if $song->duration;

	# Less than 15 s in is "never really started"; within 15 s of the end is
	# "finished" — both forget the position rather than saving it.
	if ( $elapsed > 15 && ( !$song->duration || $elapsed < $song->duration - 15 ) ) {
		Plugins::RadioHelsinki::API::setPosition( $url, int $elapsed );
		main::INFOLOG && $log->is_info && $log->info("saved position for $url: $elapsed");
	}
	else {
		Plugins::RadioHelsinki::API::clearPosition($url);
	}
}

1;
