package Plugins::RadioHelsinki::API;

# Data layer for the Radio Helsinki WordPress REST API.
#
# Every JSON -> item mapping lives in this file. The API is undocumented and
# unversioned, so when it changes this is the only file that needs to move.

use strict;
use warnings;

use Time::Local qw(timelocal);
use HTML::Entities qw(decode_entities);
use Encode qw(encode_utf8);
use JSON::XS::VersionOneAndTwo;

use Slim::Networking::SimpleAsyncHTTP;
use Slim::Utils::Cache;
use Slim::Utils::Log;
use Slim::Utils::Strings qw(cstring);

use constant BASE      => 'https://www.radiohelsinki.fi/wp-json/api';
use constant UA        => 'Lyrion-RadioHelsinki (+https://github.com/patapovich/rh-ondemand-lyrion)';
use constant TIMEOUT   => 30;
use constant STALE_TTL => 7 * 86400;    # keep a stale copy this long as a fallback
use constant META_TTL  => 30 * 86400;

# Bump to invalidate every cached menu, e.g. after changing what an item holds.
# Without this a bad payload would sit in the cache for a day after the fix shipped.
use constant CACHE_VER => 9;

# The site 504s under load, so nothing is fetched more often than it has to be.
use constant TTL_PROGRAMS => 24 * 3600;
use constant TTL_CONTENT  => 3600;
use constant TTL_ONDEMAND => 600;
use constant TTL_PODCASTS => 1800;
use constant TTL_POPULAR  => 3600;

my $log   = logger('plugin.radiohelsinki');
my $cache = Slim::Utils::Cache->new();

# A dedicated cache namespace for anything now-playing depends on. The default cache
# purges itself to stay small, which is why a track played some time after it was
# browsed used to lose its title/artist/cover. Third arg = 1 disables periodic purging.
my $metacache = Slim::Utils::Cache->new( 'radiohelsinki', 1, 1 );

# Menu-list cache keys are versioned so shipping a fix retires the previous version's
# derived menus. These live in the default (purgeable) cache — losing them just means a
# re-fetch.
sub _ck { 'rh' . CACHE_VER . '_' . $_[0] }

# Keys within the dedicated metadata cache. Not versioned: this data has to outlive
# plugin updates so a favourited or playing track keeps its metadata across releases.
sub metaKey  { 'meta_'  . $_[0] }               # per audio URL
sub tokenKey { 'token_' . lc( $_[0] ) }         # per program, keyed by URL filename token
sub progKey  { 'prog_'  . $_[0] }               # per program, by id

# On-demand filenames are <yyyymmdd>_<token>_...mp3, where the token identifies the
# program (e.g. Rakkaudesta, RHAamut, KMK). It is the one program handle recoverable
# from the audio URL alone, which is all the metadata provider gets — so a token ->
# {artist, cover} map lets now-playing resolve the real program name and artwork even
# for a track whose menu was never browsed in this session.
sub tokenFromUrl {
	my $url = shift;
	return $url =~ m{/\d{8}_([^_/]+)_}i ? $1 : undef;
}

# Read helpers (used by Metadata.pm at play time).
sub getMeta       { $metacache->get( metaKey( $_[0] ) ) }
sub getTokenMeta  { my $t = tokenFromUrl( $_[0] ); $t ? $metacache->get( tokenKey($t) ) : undef }

# ---------------------------------------------------------------------------
# Public endpoints
# ---------------------------------------------------------------------------

# Program directory, keyed for lookup. Everything else depends on this, because
# episodes carry no artwork of their own and only reference their program by id.
#
# Yields { list => [ $prog, ... ], byId => { $id => $prog } } where each $prog is
# { id, title, img, archive }.
sub getPrograms {
	my ( $cb, $ecb ) = @_;

	_fetch( 'programs', BASE . '/v2/programs', TTL_PROGRAMS, \&_parsePrograms, $cb, $ecb );
}

# One program's whole archive: { ondemand => [], podcasts => [], clips => [] },
# each already mapped to playable OPML items.
sub getProgramContent {
	my ( $prog, $cb, $ecb ) = @_;

	_fetch(
		'content_' . $prog->{id},
		programContentUrl( $prog->{id} ),
		TTL_CONTENT,
		sub { _parseProgramContent( shift, $prog ) },
		$cb, $ecb,
	);
}

# The program_content endpoint for a program. Doubles as the favorites_url for a
# favourited program: reopening the favourite refetches this and Parser.pm rebuilds
# the menu, so the program stays current as new episodes appear.
sub programContentUrl {
	my $id = shift;
	return BASE . '/v1/program_content/' . $id;
}

# Synchronous lookup of a single program, by id. The favourites parser runs
# synchronously and cannot wait on an async fetch, so it needs whatever is already
# cached. This reads a stable per-program key (see _parsePrograms) that survives
# restarts and CACHE_VER bumps — so a favourited program keeps its artwork long after
# the programs directory was last fetched. Falls back to the directory cache, then
# undef. Returns { id, title, img } or undef.
sub programById {
	my $id = shift;

	if ( my $prog = $metacache->get( progKey($id) ) ) {
		return $prog;
	}

	my $programs = $cache->get( _ck('programs') ) or return undef;

	return $programs->{byId}->{$id};
}

# The three flat "newest / most popular" lists. These reference many different
# programs, so each needs the program directory to resolve artwork.
sub getLatestOndemand {
	my ( $cb, $ecb ) = @_;
	_fetchWithPrograms( 'latest_ondemand', BASE . '/v1/ondemand', TTL_ONDEMAND, $cb, $ecb );
}

sub getLatestPodcasts {
	my ( $cb, $ecb ) = @_;
	_fetchWithPrograms( 'latest_podcasts', BASE . '/v1/podcasts', TTL_PODCASTS, $cb, $ecb );
}

sub getPopularPodcasts {
	my ( $cb, $ecb ) = @_;
	_fetchWithPrograms( 'popular_podcasts', BASE . '/v1/popularpodcasts', TTL_POPULAR, $cb, $ecb );
}

# ---------------------------------------------------------------------------
# Fetching
# ---------------------------------------------------------------------------

# Fetch $url, run the raw JSON through $parser, cache the *derived* structure.
# Parsing a 1.2 MB program_content payload on every menu open would be absurd.
sub _fetch {
	my ( $key, $url, $ttl, $parser, $cb, $ecb ) = @_;

	if ( my $hit = $cache->get( _ck($key) ) ) {
		main::DEBUGLOG && $log->is_debug && $log->debug("cache hit: $key");
		return $cb->($hit);
	}

	main::INFOLOG && $log->is_info && $log->info("fetching $url");

	Slim::Networking::SimpleAsyncHTTP->new(
		sub {
			my $http = shift;

			my $derived = eval {
				my $json = from_json( $http->content );
				$parser->($json);
			};

			if ( $@ || !$derived ) {
				$log->error("failed to parse $url: $@");
				return _fallback( $key, $cb, $ecb );
			}

			$cache->set( _ck($key),            $derived, $ttl );
			$cache->set( _ck("stale_$key"),    $derived, STALE_TTL );

			$cb->($derived);
		},
		sub {
			my ( $http, $error ) = @_;
			$log->warn("failed to fetch $url: $error");
			_fallback( $key, $cb, $ecb );
		},
		{
			timeout => TIMEOUT,
		},
	)->get( $url, 'User-Agent' => UA );
}

# The site is flaky. A stale menu beats an error menu.
sub _fallback {
	my ( $key, $cb, $ecb ) = @_;

	if ( my $stale = $cache->get( _ck("stale_$key") ) ) {
		$log->warn("serving stale data for $key");
		return $cb->($stale);
	}

	$ecb->( cstring( undef, 'PLUGIN_RADIOHELSINKI_ERROR' ) );
}

# Resolve the program directory first, then fetch a flat episode list and use the
# directory to decorate each episode with its program's artwork.
sub _fetchWithPrograms {
	my ( $key, $url, $ttl, $cb, $ecb ) = @_;

	getPrograms(
		sub {
			my $programs = shift;
			_fetch( $key, $url, $ttl,
				sub { _parseEpisodes( shift, $programs->{byId}, 'cross-program' ) },
				$cb, $ecb );
		},
		$ecb,
	);
}

# ---------------------------------------------------------------------------
# Parsing
# ---------------------------------------------------------------------------

sub _parsePrograms {
	my $json = shift;

	return unless ref $json eq 'ARRAY';

	my ( @list, %byId );

	for my $p (@$json) {
		next unless $p->{ID} && $p->{post_title};

		# A couple of programs are members-only; their audio is paywalled.
		next if $p->{only_membership};

		# post_content is the only description every program has (all 203 of them).
		# `hosts` covers barely a third, so it is not worth reaching for.
		#
		# desc is a one-line preview for list rows (skins truncate line2 by design);
		# descLong keeps the paragraphs and is shown in full inside the program's own
		# menu as a textarea.
		my $prog = {
			id       => $p->{ID},
			title    => _clean( $p->{post_title} ),
			desc     => _clean( $p->{post_content} ),
			descLong => _cleanLong( $p->{post_content} ),
			img      => _safeUrl( $p->{img} ),
			archive  => $p->{archive} ? 1 : 0,
		};

		push @list, $prog;
		$byId{ $prog->{id} } = $prog;

		# Stable per-program copy, so the favourites parser can resolve this program's
		# artwork even when the directory-list cache is cold (e.g. right after a
		# restart, opening a favourite without browsing first).
		$metacache->set( progKey( $prog->{id} ), $prog, META_TTL );
	}

	@list = sort { lc( $a->{title} ) cmp lc( $b->{title} ) } @list;

	main::INFOLOG && $log->is_info && $log->info( 'parsed ' . scalar(@list) . ' programs' );

	return { list => \@list, byId => \%byId };
}

sub _parseProgramContent {
	my ( $json, $prog ) = @_;

	return unless ref $json eq 'HASH';

	my $byId = { $prog->{id} => $prog };

	return {
		ondemand  => _parseEpisodes( $json->{ondemand},        $byId ),
		podcasts  => _parseEpisodes( $json->{latest_podcasts}, $byId ),
		clips     => _parseEpisodes( $json->{interviews},      $byId ),
		playlists => _parsePlaylists( $json->{playlists} ),
	};
}

# Tracklists. Returned keyed by broadcast timestamp so an episode can find its own
# (Plugin.pm::_episodeMenus does the matching): the key matches that episode's
# `begin`, and occasionally its `end`.
#
# Each track also carries a `created_at`, which looks temptingly like the moment the
# song went out and is not. It is when the row was written: Kuusikielinen taivas's
# tracks were entered ten days *before* broadcast, and Radio Helsingin aamut's were
# bulk-pasted in a single second *after* it. So there is no way to turn a track into
# an offset into the recording, and no jump-to-track. `spotify_id` is likewise a dead
# end: null on all but 2 of ~900 tracks. Both fields are ignored on purpose.
#
# Note these are plain data, not menu items. The items are built at browse time
# because they carry coderefs, and Storable cannot freeze a coderef into the cache.
sub _parsePlaylists {
	my $playlists = shift;

	return {} unless ref $playlists eq 'HASH';

	my %byWhen;

	for my $when ( keys %$playlists ) {
		my $tracks = $playlists->{$when};
		next unless ref $tracks eq 'ARRAY' && @$tracks;

		my @sorted =
			sort { ( $a->{sortable_rank} || 0 ) <=> ( $b->{sortable_rank} || 0 ) } @$tracks;

		my @out;
		for my $t (@sorted) {
			my $song   = _clean( $t->{song} );
			my $artist = _clean( $t->{artist} );

			next unless length $song || length $artist;

			push @out, { song => $song, artist => $artist };
		}

		next unless @out;

		$byWhen{$when} = \@out;
	}

	return \%byWhen;
}

# The one mapping that matters: a Radio Helsinki episode -> a playable OPML item.
#
# $cross marks a cross-program list (the flat "Uusimmat ..." menus): there the
# program is the headline, because a bare date row is meaningless when every row
# comes from a different program. Inside a single program's own menu the program
# name would be 346 rows of noise, so it stays out of the labels there.
sub _parseEpisodes {
	my ( $episodes, $byId, $cross ) = @_;

	return [] unless ref $episodes eq 'ARRAY';

	# Newest first. The API mostly returns them that way already, but not always.
	my @sorted = sort { ( $b->{begin} || '' ) cmp ( $a->{begin} || '' ) } @$episodes;

	my @items;

	for my $e (@sorted) {
		my $url = _safeUrl( $e->{audio_mp3_url} ) or next;

		my $prog     = $byId->{ $e->{prog} || '' };
		my $img      = $prog ? $prog->{img} : undef;
		my $duration = _duration( $e->{begin}, $e->{end} );
		my $date     = _date( $e->{begin} );

		# The program this belongs to. NOT $e->{program_title}: on a clip that field
		# holds the clip's *own* name ("Tavastian slotti:"), identical to its title,
		# which would otherwise be reported as the artist while it played.
		my $program = ( $prog && $prog->{title} ) || _clean( $e->{program_title} );

		# On-demand recordings have no title of their own — they are just "the show,
		# on that date", so the weekday earns its place: it is the only thing that
		# distinguishes one row from the next when the description is missing.
		my $dated    = _dateLong( $e->{begin} );
		my $ownTitle = _clean( $e->{title} );
		my $title    = $ownTitle || $dated || $program;

		my $desc = _clean( $e->{description_short} ) || _clean( $e->{description} );

		# The full text, paragraphs kept — shown in the episode's info view.
		my $descLong = _cleanLong( $e->{description} ) || _cleanLong( $e->{description_short} );

		# Never repeat what the name already says — 27 of 639 episodes have no
		# description at all, and those used to render the date twice.
		my $line2 = $desc || ( $title eq $dated ? $program : $date ) || $program;

		# Cross-program lists lead with the program. \x{2013}/\x{00B7} escapes, not
		# literals — no `use utf8` in this file.
		my $name = $title;
		if ( $cross && length $program ) {
			if ($ownTitle) {
				$line2 = "$program \x{2013} $dated" . ( length $desc ? " \x{00B7} $desc" : '' );
			}
			else {
				$name  = "$program \x{2013} $dated";
				$line2 = $desc;
			}
		}

		my $item = {
			name      => $name,
			line1     => $name,
			line2     => $line2,
			type      => 'audio',
			url       => $url,
			play      => $url,
			on_select => 'play',
			image     => $img,
			$duration ? ( duration => $duration ) : (),

			# Full episode text for the info view — XMLBrowser's audio-leaf card has a
			# DESCRIPTION field for exactly this. Only ever set on audio items: an item
			# with a `description` is treated as a leaf, so putting it on a browsable
			# link (e.g. a playlist episode wrapper) would kill its drill-down.
			length $descLong ? ( description => $descLong ) : (),

			# Not for display: how an episode finds its own tracklist. Playlists are
			# keyed by broadcast timestamp, which is this episode's `begin` — except
			# for the occasional one that keys off `end` instead.
			_begin => $e->{begin},
			_end   => $e->{end},
		};

		# Stash the metadata under the audio URL so Metadata.pm can serve it at play
		# time — including much later, from a favourite, when this menu is long gone.
		# Goes in the dedicated non-purging cache.
		$metacache->set(
			metaKey($url),
			{
				title    => $title,
				artist   => $program,
				album    => 'Radio Helsinki',
				cover    => $img,
				icon     => $img,
				type     => 'MP3',
				$duration ? ( duration => $duration ) : (),
			},
			META_TTL,
		);

		# Program-level fallback keyed by the URL's filename token, so now-playing can
		# still show the real program name and cover for a track whose per-URL entry was
		# never written (played straight from a favourite without a browse). One entry
		# per program; written from any of its episodes.
		if ( my $token = tokenFromUrl($url) ) {
			$metacache->set(
				tokenKey($token),
				{ artist => $program, cover => $img },
				META_TTL,
			) if length $program;
		}

		# Slim::Player::Protocols::HTTP reads this key directly for stream artwork, from
		# the default cache namespace.
		$cache->set( "remote_image_$url", $img, META_TTL ) if $img;

		push @items, $item;
	}

	return \@items;
}

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# WordPress serves a dozen image paths with combining diacritics — "neliö" stored
# as "nelio" plus U+0308 rather than a precomposed ö. That codepoint is above 255,
# and LMS's SQLite cache (Slim::Utils::DbCache) croaks with "Wide character in
# subroutine entry" when it binds a raw string containing one. Hashrefs escape this
# because Storable freezes them to bytes first; a bare string like an artwork URL
# does not.
#
# Percent-encoding the UTF-8 bytes gives a pure-ASCII URL that is byte-identical to
# the filename on the server, so it stays fetchable. Bytes already in the printable
# ASCII range — including '%' — pass through, so an already-encoded URL is untouched.
sub _safeUrl {
	my $url = shift;

	return undef unless defined $url && length $url;

	my $bytes = encode_utf8($url);
	$bytes =~ s/([^\x21-\x7E])/sprintf( '%%%02X', ord($1) )/ge;

	return $bytes;
}

# Program titles come through with HTML entities and soft hyphens embedded for
# the website's line breaking ("Yti\x{AD}mes\x{AD}sä"). Descriptions carry markup.
sub _clean {
	my $text = shift;

	return '' unless defined $text && length $text;

	$text = decode_entities($text);
	$text =~ s/<[^>]*>//g;      # strip markup
	$text =~ s/\x{00AD}//g;     # soft hyphens
	$text =~ s/\s+/ /g;
	$text =~ s/^\s+|\s+$//g;

	# Clip names are typed by hand and a dozen trail off mid-sentence
	# ("Tavastian slotti:"), which reads as truncation in a menu.
	$text =~ s/[\s:;,.\x{2013}\x{2014}-]+$//;

	return $text;
}

# Like _clean, but keeps paragraph structure: WordPress post_content separates
# paragraphs with blank lines and <p>/<br> markup, and flattening a five-paragraph
# programme description into one line makes it unreadable in the full-text view.
sub _cleanLong {
	my $text = shift;

	return '' unless defined $text && length $text;

	$text = decode_entities($text);
	$text =~ s/\r//g;                   # WordPress sends \r\n; normalise first
	$text =~ s{<br\s*/?>}{\n}gi;
	$text =~ s{</p>}{\n\n}gi;
	$text =~ s/<[^>]*>//g;
	$text =~ s/\x{00AD}//g;
	$text =~ s/[ \t]+/ /g;              # collapse spaces, never newlines
	$text =~ s/ *\n */\n/g;
	$text =~ s/\n{3,}/\n\n/g;           # at most one blank line between paragraphs
	$text =~ s/^\s+|\s+$//g;

	return $text;
}

# "2026-07-13 07:00:00" -> "13.07.2026"
sub _date {
	my $ts = shift;

	return '' unless $ts && $ts =~ /^(\d{4})-(\d{2})-(\d{2})/;

	return "$3.$2.$1";
}

# "2026-07-13 07:00:00" -> "ma 13.07.2026"
sub _dateLong {
	my $ts = shift;

	my $date = _date($ts) or return '';

	my $epoch = _epoch($ts) or return $date;

	# localtime's wday is 0=Sunday; the string tokens run 1=Monday .. 7=Sunday.
	my $wday = ( localtime($epoch) )[6] || 7;

	return cstring( undef, "PLUGIN_RADIOHELSINKI_DOW_$wday" ) . " $date";
}

# Duration in seconds, from the broadcast window. Seeking needs it: canSeek()
# returns 0 unless both bitrate and duration are known, and a 4-hour show is
# exactly the thing you want to seek around in.
#
# Podcasts and clips have begin == end, so they get nothing here and LMS derives
# the duration from the stream instead.
sub _duration {
	my ( $begin, $end ) = @_;

	my $b = _epoch($begin) or return 0;
	my $e = _epoch($end)   or return 0;

	my $secs = $e - $b;

	# Sanity bound: reject anything the schedule clearly got wrong rather than
	# handing LMS a duration that would make seeking land in the wrong place.
	return 0 if $secs <= 0 || $secs > 6 * 3600;

	return $secs;
}

sub _epoch {
	my $ts = shift;

	return 0 unless $ts && $ts =~ /^(\d{4})-(\d{2})-(\d{2}) (\d{2}):(\d{2}):(\d{2})$/;

	return eval { timelocal( $6, $5, $4, $3, $2 - 1, $1 ) } || 0;
}

1;
