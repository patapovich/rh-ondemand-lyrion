package Plugins::RadioHelsinki::Live;

# Now-playing metadata for the live stream (stream.radiohelsinki.fi).
#
# The stream itself carries no usable metadata: its SHOUTcast server advertises
# icy-metaint but only ever sends empty metadata blocks, so the station's
# djonline.js feed (the same document behind the website's player and our
# "Nyt soi" menu) is the only now-playing source that exists. While a player is
# on the stream this module polls that feed on a short timer, decides between
# "a song is playing" and "programme only" itself, resolves cover art, and
# pushes the result to the player.
#
# Registration claims the live URL in BOTH RemoteMetadata registries:
#
#  - the PROVIDER, so status queries get title/artist/album/cover from here.
#    Tie::RegexpHash hands a URL to the first registered matching entry and
#    plugins initialise alphabetically, so RadioHelsinki beats RadioNowPlaying
#    deterministically — with this module active, RadioNowPlaying is never
#    consulted for this URL and (verified against its source: its poll chain
#    is seeded exclusively from its provider/parser being called, it holds no
#    notification subscriptions) does no background work for it either. It
#    keeps working normally for any other station, and takes this one back
#    automatically if this plugin is removed.
#
#  - the PARSER, returning "handled": Protocols::HTTP consults the parser
#    registry on every in-stream metadata block, and without this a matching
#    parser elsewhere (RadioNowPlaying registers one) would be woken by the
#    first non-empty ICY block the station ever sends — and core itself would
#    overwrite our title with the raw ICY text.
#
# The poll/push mechanics follow the two proven in-tree implementations:
# the timer lifecycle is Slim::Plugin::InternetRadio::TuneIn::Metadata's
# (provider seeds a self-re-arming per-client timer that stops when the client
# leaves the stream), the push sequence is RadioNowPlaying's (duration +
# startOffset for a truthful progress bar, wmaMeta pluginData, clientless
# setCurrentTitle, currentPlaylistUpdateTime, 'newmetadata').

use strict;
use warnings;

use JSON::XS::VersionOneAndTwo;
use Scalar::Util qw(refaddr);
use URI::Escape qw(uri_escape_utf8);

use Slim::Control::Request;
use Slim::Formats::RemoteMetadata;
use Slim::Music::Info;
use Slim::Networking::SimpleAsyncHTTP;
use Slim::Player::Playlist;
use Slim::Utils::Cache;
use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Utils::Timers;
use Time::HiRes ();

use Plugins::RadioHelsinki::API;

use constant MATCH => qr{^https?://stream\.radiohelsinki\.fi/}i;

use constant POLL         => 4;      # feed poll cadence while the stream plays, s
use constant GRACE        => 90;     # song stays "current" this long past its nominal end
use constant FEED_TIMEOUT => 6;

# What the listener hears runs behind the air signal (Cloudflare + LMS +
# player buffering; ~7 s measured on the reference setup). Progress bars are
# shifted by the 'listendelay' pref (Settings → Advanced → Radio Helsinki)
# so they track the ears, not the transmitter — without this a song's bar
# already read ~7 s when its first note came out of the speakers.
use constant LISTEN_DELAY_DEFAULT => 7;

use constant ITUNES         => 'https://itunes.apple.com/search';
use constant ITUNES_TTL     => '90 days';
use constant ITUNES_NEG_TTL => 6 * 3600;

# The station's Cloudflare intermittently bot-blocks non-browser agents on
# wp-content; the website's own headers have a two-day clean record here.
use constant BROWSER_UA => 'Mozilla/5.0 (X11; Linux x86_64; rv:128.0) Gecko/20100101 Firefox/128.0';

my $log   = logger('plugin.radiohelsinki');
my $prefs = preferences('plugin.radiohelsinki');

# MATCH as a scalar for `=~` sites (a bareword constant is not a pattern).
my $liveRE = MATCH;

# iTunes results and full-resolution cover checks go to the persistent
# namespace: song rotation repeats heavily and lookups survive restarts.
my $metacache = Slim::Utils::Cache->new( 'radiohelsinki', 1, 1 );

# The current on-air state, shared by all clients (there is one station):
# { at => epoch, song => { artist, title, album, cover, start, len } | undef,
#   prog => _parseCurrentProgram() result | undef }
my $live = { at => 0 };

my $fetching = 0;
my %lastPush;        # client id -> signature of the last pushed state

# "Song (feat. X)" / "[Radio Version]" etc. hurt iTunes search precision.
my $noise = qr{\s*[\(\[][^)\]]*(?:feat\.|version|edit|remaster|mix)[^)\]]*[\)\]]\s*}i;


sub init {
	$prefs->init( {
		listendelay  => LISTEN_DELAY_DEFAULT,
		livemeta     => 1,
		pollinterval => POLL,
		songgrace    => GRACE,
	} );

	# The RadioNowPlaying override switch: with livemeta off nothing is
	# registered, so both registries fall through to whoever registers next
	# (RadioNowPlaying when installed, else core ICY handling). Registration
	# cannot be undone at runtime — the toggle takes effect at restart.
	return unless $prefs->get('livemeta');

	# Parser first: swallow any ICY metadata the stream might ever grow, and
	# keep it from reaching other plugins' parsers (see header comment).
	Slim::Formats::RemoteMetadata->registerParser(
		match => MATCH,
		func  => sub { return 1 },
	);

	Slim::Formats::RemoteMetadata->registerProvider(
		match => MATCH,
		func  => \&provider,
	);
}

# ---------------------------------------------------------------------------
# Provider: what every status query / track-info view sees. Also the seed for
# the poll loop — LMS asks for metadata as soon as the stream starts playing.
# ---------------------------------------------------------------------------

sub provider {
	my ( $client, $url ) = @_;

	$client = $client->master if $client;

	return _defaultMeta() unless $client && ( $client->isPlaying || $client->isPaused );

	# (Re)start the loop when there is no fresh state and nothing in
	# flight — first play, resume after pause, or a died timer.
	if ( !$fetching && time() - $live->{at} > _pollInterval() + 1 ) {
		Slim::Utils::Timers::killTimers( $client, \&fetchLive );
		fetchLive( $client, $url );
	}

	return _meta();
}

# Pref reads, sanitised: free-text fields, so clamp anything unusable back
# into a sensible band.
sub _listenDelay {
	my $d = $prefs->get('listendelay');

	return LISTEN_DELAY_DEFAULT unless defined $d && $d =~ /^\d+$/;
	return $d > 60 ? 60 : $d;
}

# Poll cadence: floored at 2 s to stay a polite client of the station.
sub _pollInterval {
	my $p = $prefs->get('pollinterval');

	return POLL unless defined $p && $p =~ /^\d+$/;
	return $p < 2 ? 2 : $p > 30 ? 30 : $p;
}

sub _songGrace {
	my $g = $prefs->get('songgrace');

	return GRACE unless defined $g && $g =~ /^\d+$/;
	return $g > 600 ? 600 : $g;
}

# Slot length for the programme-position bar; bounded to keep a broken
# schedule row from producing an absurd bar.
sub _progLen {
	my $prog = shift;

	return 0 unless $prog->{begin} && $prog->{end};

	my $len = $prog->{end} - $prog->{begin};
	return ( $len > 0 && $len <= 12 * 3600 ) ? $len : 0;
}

sub _defaultMeta {
	return {
		title => 'Radio Helsinki',
		cover => Plugins::RadioHelsinki::API::LOGO,
		icon  => Plugins::RadioHelsinki::API::LOGO,
	};
}

sub _meta {
	my $song = $live->{song};
	my $prog = $live->{prog};

	my $progimg = $prog ? _progImage( $prog->{progid} ) : undef;

	# The album line doubles as the episode text when nothing better claims
	# it — same trick RadioNowPlaying used (its progsynopsis lands in album):
	# a song with a real album shows the album, everything else shows the
	# programme's description for the slot when the station wrote one.
	my $desc = $prog ? $prog->{desc} : undef;

	if ($song) {
		return {
			title  => $song->{title},
			artist => $song->{artist},
			( $song->{album} || $desc ) ? ( album => $song->{album} || $desc ) : (),
			cover  => $song->{cover} || $progimg || Plugins::RadioHelsinki::API::LOGO,
			icon   => $progimg || Plugins::RadioHelsinki::API::LOGO,
			$song->{len} ? ( duration => $song->{len} ) : (),
		};
	}

	if ($prog) {
		my $len = _progLen($prog);

		return {
			title => $prog->{title},
			$prog->{hosts} ? ( artist => $prog->{hosts} ) : (),
			$desc ? ( album => $desc ) : (),
			cover => $progimg || Plugins::RadioHelsinki::API::LOGO,
			icon  => $progimg || Plugins::RadioHelsinki::API::LOGO,
			$len ? ( duration => $len ) : (),
		};
	}

	return _defaultMeta();
}

# ---------------------------------------------------------------------------
# The poll loop
# ---------------------------------------------------------------------------

sub fetchLive {
	my ( $client, $url ) = @_;

	# Stop condition: the client has moved off the live stream (or stopped).
	# Resume re-seeds through the provider.
	my $playing = Slim::Player::Playlist::url($client) || '';
	return unless $playing =~ $liveRE && ( $client->isPlaying || $client->isPaused );

	$fetching = 1;

	Slim::Networking::SimpleAsyncHTTP->new(
		\&_gotFeed,
		\&_feedError,
		{ client => $client, url => $url, timeout => FEED_TIMEOUT, cache => 0 },
	)->get(
		Plugins::RadioHelsinki::API::DJONLINE . '?dt=' . time() . '000_0',
		'User-Agent' => BROWSER_UA,
		'Accept'     => 'application/json, text/javascript, */*; q=0.01',
		'Referer'    => 'https://www.radiohelsinki.fi/',
	);
}

sub _rearm {
	my ( $client, $url ) = @_;

	$fetching = 0;

	Slim::Utils::Timers::killTimers( $client, \&fetchLive );
	Slim::Utils::Timers::setTimer( $client, time() + _pollInterval(), \&fetchLive, $url );
}

sub _feedError {
	my $http = shift;

	# The feed's origin 502s / truncates in short bursts at exactly the song
	# boundaries (it regenerates the file then); keep the last state and keep
	# polling at full cadence — backing off here is what costs the update.
	main::DEBUGLOG && $log->is_debug && $log->debug( 'live feed error: ' . ( $http->error || '?' ) );

	_rearm( $http->params('client'), $http->params('url') );
}

sub _gotFeed {
	my $http   = shift;
	my $client = $http->params('client');

	my $doc = eval { from_json( $http->content ) };

	if ( ref $doc eq 'HASH' ) {
		$live = {
			at   => time(),
			song => _pickSong($doc),
			prog => Plugins::RadioHelsinki::API::_parseCurrentProgram($doc) || $live->{prog},
		};

		if ( my $song = $live->{song} ) {
			_lookupSong( $client, $song );
		}

		_push($client);
	}
	# Unparseable body: same boundary-burst story as _feedError.

	_rearm( $client, $http->params('url') );
}

# The newest played row, while its window is still current: from its logged
# start time until its nominal length plus GRACE. The station's DJ log is the
# only signal there is — after the window lapses (talk, or nobody logging)
# the display falls back to the programme. Real lengths throughout: no upper
# cap, so long mixes keep their song display.
sub _pickSong {
	my $doc = shift;

	my ($row) = grep { ref $_ eq 'HASH' } @{ ref $doc->{last_playing} eq 'ARRAY' ? $doc->{last_playing} : [] };

	return undef unless $row && $row->{_start} && $row->{_start} =~ /^\d+$/;

	my $title  = Plugins::RadioHelsinki::API::_clean( $row->{song}   || $row->{song_fi}   || '' );
	my $artist = Plugins::RadioHelsinki::API::_clean( $row->{artist} || $row->{artist_fi} || '' );

	return undef unless length $title;

	my $len = 0;
	if ( ( $row->{length} || '' ) =~ /^(?:(\d+):)?(\d+):(\d+)$/ ) {
		$len = ( $1 || 0 ) * 3600 + $2 * 60 + $3;
	}

	my $elapsed = time() - $row->{_start};
	return undef if $elapsed < -_pollInterval() || $elapsed > $len + _songGrace();

	my $song = {
		title  => $title,
		artist => $artist,
		album  => Plugins::RadioHelsinki::API::_clean( $row->{album} || '' ),
		start  => $row->{_start},
		len    => $len,
	};

	# Album + artwork from an earlier lookup of the same song, if any.
	if ( my $hit = $metacache->get( _itunesKey($song) ) ) {
		$song->{album} ||= $hit->{album} || '';
		$song->{cover} = $hit->{art} if $hit->{art};
	}

	return $song;
}

# ---------------------------------------------------------------------------
# Cover art
# ---------------------------------------------------------------------------

sub _itunesKey { 'itunes_' . lc( $_[0]->{artist} || '' ) . '|' . lc( $_[0]->{title} ) }

# One iTunes search per (artist, title) gives both the album name and the
# cover (artworkUrl100, rescaled to 600x600 — standard mzstatic trick).
# Results, including misses, live in the persistent cache.
sub _lookupSong {
	my ( $client, $song ) = @_;

	return unless length( $song->{artist} || '' );
	return if $song->{cover} || $metacache->get( _itunesKey($song) );

	my $clean = $song->{title};
	$clean =~ s/$noise/ /g;

	my $query = ITUNES . '?term=' . uri_escape_utf8("$song->{artist} $clean")
		. '&entity=song&limit=1&country=FI';

	Slim::Networking::SimpleAsyncHTTP->new(
		sub {
			my $http = shift;

			my $doc = eval { from_json( $http->content ) };
			my ($r) = @{ ref $doc eq 'HASH' && ref $doc->{results} eq 'ARRAY' ? $doc->{results} : [] };

			my $hit = { album => '', art => '' };

			if ( ref $r eq 'HASH' ) {
				$hit->{album} = $r->{collectionName} || '';
				if ( my $art = $r->{artworkUrl100} ) {
					$art =~ s/100x100bb/600x600bb/;
					$hit->{art} = $art;
				}
			}

			$metacache->set( _itunesKey($song),
				$hit, ( $hit->{album} || $hit->{art} ) ? ITUNES_TTL : ITUNES_NEG_TTL );

			# Still the same song on air? Enrich it and repaint.
			if ( $live->{song} && $live->{song}->{start} == $song->{start} ) {
				$live->{song}->{album} ||= $hit->{album};
				$live->{song}->{cover} = $hit->{art} if $hit->{art};
				_push($client);
			}
		},
		sub {
			my $http = shift;
			main::DEBUGLOG && $log->is_debug && $log->debug( 'itunes error: ' . ( $http->error || '?' ) );
		},
		{ timeout => FEED_TIMEOUT, cache => 0 },
	)->get( $query, 'User-Agent' => BROWSER_UA );
}

# Programme cover from the programme directory, upgraded to the full-size
# original when the CDN has one (the directory serves WordPress "-640x640"
# renditions; stripping the suffix usually reveals the original — checked
# once with a 1-byte ranged GET, remembered persistently).
sub _progImage {
	my $progid = shift;

	return undef unless $progid;

	my $prog = Plugins::RadioHelsinki::API::programById($progid) or return undef;
	my $img  = $prog->{img} or return undef;

	if ( my $best = $metacache->get( "fullres_$img" ) ) {
		return $best;
	}

	if ( $img =~ /^(.+)-\d+x\d+(\.\w+)$/ ) {
		my $candidate = "$1$2";

		# Serve the sized rendition until the check answers; the next repaint
		# picks the upgrade up from the cache.
		$metacache->set( "fullres_$img", $img, '30 days' );

		Slim::Networking::SimpleAsyncHTTP->new(
			sub {
				my $http = shift;
				$metacache->set( "fullres_$img", $candidate, '30 days' )
					if ( $http->code || 0 ) =~ /^20[06]$/;
			},
			sub {},
			{ timeout => FEED_TIMEOUT, cache => 0 },
		)->get( $candidate, 'User-Agent' => BROWSER_UA, 'Range' => 'bytes=0-0' );

		return $img;
	}

	$metacache->set( "fullres_$img", $img, '30 days' );
	return $img;
}

# ---------------------------------------------------------------------------
# Push: make the new state visible without waiting for a UI poll
# ---------------------------------------------------------------------------

sub _push {
	my $client = shift;

	return unless $client;
	$client = $client->master;

	my $song = $client->playingSong or return;
	my $surl = $song->track ? $song->track->url : '';
	return unless $surl =~ $liveRE;

	my $meta = _meta();
	my $prog = $live->{prog};

	# The station line: channel name plus the programme — never a copy of the
	# track title.
	my $progline = 'Radio Helsinki'
		. ( $prog
			? " \x{2013} $prog->{title}" . ( $prog->{hosts} ? " / $prog->{hosts}" : '' )
			: '' );

	my $sig = join "\0", refaddr($song), map { $_ // '' }
		@{$meta}{qw(title artist album cover duration)}, $progline;

	my $signew = ( $lastPush{ $client->id } || '' ) ne $sig;
	$lastPush{ $client->id } = $sig;

	# Progress bar: the song's real position and length, or — between songs —
	# the position within the programme's time slot. Displayed elapsed is the
	# player's stream elapsed plus the offset. Re-applied on EVERY cycle, not
	# just on change: the core stream-open path resets the Song's startOffset
	# (and can land after our first push — the stream is still connecting when
	# the provider seeds the loop), and recomputing also corrects clock drift.
	my $delay = _listenDelay();

	if ( my $s = $live->{song} ) {
		$song->duration( $s->{len} || 0 );

		$song->startOffset( ( time() - $delay - $s->{start} ) - $client->songElapsedSeconds )
			if $s->{len};
	}
	elsif ( $prog && _progLen($prog) ) {
		$song->duration( _progLen($prog) );
		$song->startOffset( ( time() - $delay - $prog->{begin} ) - $client->songElapsedSeconds );
	}
	else {
		$song->duration(0);
	}

	# Same story for the station line: stream connect overwrites it with the
	# icy-name header, so assert it whenever the observed value differs.
	# Clientless on purpose: with a client this would also fire a
	# 'playlist newsong' notification per update (Slim::Music::Info:535).
	my $titlefix = ( Slim::Music::Info::getCurrentTitle( $client, $surl ) || '' ) ne $progline;
	Slim::Music::Info::setCurrentTitle( $surl, $progline ) if $titlefix;

	return unless $signew || $titlefix;

	$song->pluginData( wmaMeta => {
		artist => $meta->{artist},
		album  => $meta->{album},
		title  => $meta->{title},
		cover  => $meta->{cover},
	} );

	$client->currentPlaylistUpdateTime( Time::HiRes::time() );

	Slim::Control::Request::notifyFromArray( $client, ['newmetadata'] );

	main::DEBUGLOG && $log->is_debug && $log->debug(
		'live push: ' . ( $meta->{artist} ? "$meta->{artist} - " : '' ) . ( $meta->{title} || '' ) );
}

1;
