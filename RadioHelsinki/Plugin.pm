package Plugins::RadioHelsinki::Plugin;

# Radio Helsinki on-demand for Lyrion Music Server.
#
# An OPML menu tree over the station's public WordPress REST API. All the
# JSON handling lives in API.pm; this file is only the shape of the menu.

use strict;
use warnings;

use base 'Slim::Plugin::OPMLBased';

use Slim::Menu::TrackInfo;
use Slim::Utils::DateTime;
use Slim::Utils::Log;
use Slim::Utils::Strings qw(cstring);

use Plugins::RadioHelsinki::API;
use Plugins::RadioHelsinki::Metadata;
use Plugins::RadioHelsinki::Search;
use Plugins::RadioHelsinki::Parser;

# Loading it is what registers radiohelsinki:// — must happen at plugin load, not
# first browse, so a wrapped favourite resumes correctly right after a restart.
use Plugins::RadioHelsinki::ProtocolHandler;

# Six programs have no artwork of their own; without this they render as a blank row.
use constant FALLBACK_ICON => 'plugins/RadioHelsinki/html/images/icon.png';

my $log = Slim::Utils::Log->addLogCategory( {
	category     => 'plugin.radiohelsinki',
	defaultLevel => 'ERROR',
	description  => 'PLUGIN_RADIOHELSINKI',
} );

sub initPlugin {
	my $class = shift;

	Plugins::RadioHelsinki::Metadata->init();

	# The episode info inside the now-playing "song info" view, for any of our
	# tracks — wrapped or legacy plain URL alike.
	Slim::Menu::TrackInfo->registerInfoProvider( radiohelsinki => (
		after => 'top',
		func  => \&trackInfoMenu,
	) );

	$class->SUPER::initPlugin(
		feed   => \&handleFeed,
		tag    => 'radiohelsinki',
		menu   => 'radios',
		weight => 10,
	);
}

sub getDisplayName { 'PLUGIN_RADIOHELSINKI' }

# The episode description as a song-info entry. getMeta normalises wrapped and
# plain URLs, and quietly returns nothing for foreign tracks. Shaped exactly
# like the core COMMENT provider (folder + unfold) — a bare text item renders
# as an empty row in menuMode.
sub trackInfoMenu {
	my ( $client, $url, $track, $remoteMeta ) = @_;

	my $meta = Plugins::RadioHelsinki::API::getMeta($url);
	return unless $meta && length( $meta->{description} || '' );

	return {
		name  => cstring( $client, 'PLUGIN_RADIOHELSINKI_EPISODE_INFO' ),
		items => [ {
			type => 'text',
			wrap => 1,
			name => $meta->{description},
		} ],

		unfold => 1,
	};
}

# ---------------------------------------------------------------------------
# Top level
# ---------------------------------------------------------------------------

sub handleFeed {
	my ( $client, $cb, $args ) = @_;

	$cb->( {
		items => [
			# Both lists are favouritable: the favourite stores the pseudo-URL
			# (a coderef could not be serialised) and ProtocolHandler.pm's
			# explodePlaylist serves the live list back when it is opened. The
			# `playlist` key is the same trick the program rows use — a skin
			# only offers "Add to favourites" on items it considers playable.
			{
				name => cstring( $client, 'PLUGIN_RADIOHELSINKI_IN_PROGRESS' ),
				type => 'link',
				url  => \&inProgress,

				favorites_url   => 'radiohelsinki://kesken',
				favorites_type  => 'link',
				favorites_title => cstring( $client, 'PLUGIN_RADIOHELSINKI_IN_PROGRESS' ),
				favorites_icon  => FALLBACK_ICON,
				playlist        => 'radiohelsinki://kesken',
			},
			{
				name => cstring( $client, 'PLUGIN_RADIOHELSINKI_RECENT' ),
				type => 'link',
				url  => \&recentlyPlayed,

				favorites_url   => 'radiohelsinki://recent',
				favorites_type  => 'link',
				favorites_title => cstring( $client, 'PLUGIN_RADIOHELSINKI_RECENT' ),
				favorites_icon  => FALLBACK_ICON,
				playlist        => 'radiohelsinki://recent',
			},
			{
				name => cstring( $client, 'PLUGIN_RADIOHELSINKI_LATEST_ONDEMAND' ),
				type => 'link',
				url  => \&latestOndemand,
			},
			{
				name => cstring( $client, 'PLUGIN_RADIOHELSINKI_LATEST_PODCASTS' ),
				type => 'link',
				url  => \&latestPodcasts,
			},
			{
				name => cstring( $client, 'PLUGIN_RADIOHELSINKI_POPULAR_PODCASTS' ),
				type => 'link',
				url  => \&popularPodcasts,
			},
			{
				name        => cstring( $client, 'PLUGIN_RADIOHELSINKI_PROGRAMS' ),
				type        => 'link',
				url         => \&programList,
				passthrough => [ { archive => 0 } ],
			},
			{
				name        => cstring( $client, 'PLUGIN_RADIOHELSINKI_ARCHIVE' ),
				type        => 'link',
				url         => \&programList,
				passthrough => [ { archive => 1 } ],
			},
			{
				name => cstring( $client, 'PLUGIN_RADIOHELSINKI_SEARCH' ),
				type => 'search',
				url  => \&searchPrograms,
			},
		],
	} );
}

# ---------------------------------------------------------------------------
# In progress ("Kesken") and recently played ("Viimeksi kuunnellut")
# ---------------------------------------------------------------------------

# Both lists render URL indexes maintained by the protocol handler. Fully
# synchronous — the indexes and the metadata all live in the local cache — and a
# coderef feed is re-invoked on every open, so the lists are always current.

# Everything with a saved resume position, newest-stopped first.
sub inProgress {
	my ( $client, $cb, $args ) = @_;
	$cb->( inProgressFeed($client) );
}

# Everything that has been played, newest first — half-listened entries open the
# resume submenu, finished or barely-touched ones replay with one tap.
sub recentlyPlayed {
	my ( $client, $cb, $args ) = @_;
	$cb->( recentFeed($client) );
}

# The feeds themselves, separated from the browse callbacks because the protocol
# handler serves the same lists when a favourited "radiohelsinki://kesken" or
# "://recent" is opened (explodePlaylist).
sub inProgressFeed {
	my $client = shift;

	my @items = map { _inProgressItem( $client, $_ ) }
		@{ Plugins::RadioHelsinki::API::getInProgress() };

	return { items => @items ? \@items : [ {
		name => cstring( $client, 'PLUGIN_RADIOHELSINKI_NO_IN_PROGRESS' ),
		type => 'text',
	} ] };
}

sub recentFeed {
	my $client = shift;

	my @items = map {
		my $item = _urlItem( $client, $_ );
		$item ? _maybeResume( $client, $item ) : ();
	} @{ Plugins::RadioHelsinki::API::getRecent() };

	return { items => @items ? \@items : [ {
		name => cstring( $client, 'PLUGIN_RADIOHELSINKI_NO_RECENT' ),
		type => 'text',
	} ] };
}

# One in-progress row, or () when there is nothing worth showing.
sub _inProgressItem {
	my ( $client, $url ) = @_;

	my $item = _urlItem( $client, $url ) or return ();

	my $menu = _maybeResume( $client, $item );

	# Returned unchanged means _resumeItem judged the position practically
	# finished (a duration learned after the save) — not in progress after all.
	return $menu == $item ? () : $menu;
}

# Rebuild a playable episode row from nothing but a plain audio URL, using the
# cached now-playing metadata. Returns undef when nothing displayable survives —
# the position/history entry still works via the episode's own menu, it is just
# left out of these lists.
sub _urlItem {
	my ( $client, $url ) = @_;

	my $meta = Plugins::RadioHelsinki::API::getMeta($url) || {};

	# Meta entry gone (cache wiped, entry outlived it): synthesise what the
	# now-playing provider would — date from the filename, program name and
	# cover from the token map.
	my $title = $meta->{title};
	$title = "$3.$2.$1" if !$title && $url =~ m{/(\d{4})(\d{2})(\d{2})_}i;

	my $tok    = $meta->{artist} ? undef : Plugins::RadioHelsinki::API::getTokenMeta($url);
	my $artist = $meta->{artist} || ( $tok && $tok->{artist} ) || '';
	my $cover  = $meta->{cover}  || ( $tok && $tok->{cover} );

	return undef unless defined $title && length $title;

	# Cross-program list, so lead with the program, same style as Uusimmat.
	# \x{2013}, not a literal dash — no `use utf8` here.
	my $name = length($artist) && $artist ne $title ? "$artist \x{2013} $title" : $title;

	# Progress when a position exists, otherwise just the length when known —
	# followed by the first paragraph of the episode info (skins truncate line2
	# by design, and the full text is one level down as a textarea).
	# \x{00B7} escape, not a literal middle dot — no `use utf8` here.
	my $pos  = Plugins::RadioHelsinki::API::getPosition($url);
	my $time =
		  $pos ? _shortTime($pos) . ( $meta->{duration} ? ' / ' . _shortTime( $meta->{duration} ) : '' )
		: $meta->{duration} ? _shortTime( $meta->{duration} )
		:                     '';

	my $preview = $meta->{description} || '';
	$preview =~ s/\n.*//s;

	my $line2 = join " \x{00B7} ", grep { length } $time, $preview;

	my $wrapped = Plugins::RadioHelsinki::API::wrapUrl($url);

	return {
		name      => $name,
		line1     => $name,
		line2     => $line2,
		type      => 'audio',
		url       => $wrapped,
		play      => $wrapped,
		on_select => 'play',
		image     => $cover || FALLBACK_ICON,
		$meta->{duration} ? ( duration => $meta->{duration} ) : (),

		# The episode info: _maybeResume lifts it into the submenu as a
		# textarea; on a one-tap row it feeds the info view, like everywhere
		# else. Older meta entries lack it until their episode is re-browsed.
		length( $meta->{description} || '' ) ? ( description => $meta->{description} ) : (),
	};
}

# ---------------------------------------------------------------------------
# Flat episode lists
# ---------------------------------------------------------------------------

sub latestOndemand {
	my ( $client, $cb, $args ) = @_;
	Plugins::RadioHelsinki::API::getLatestOndemand( _episodesCb( $client, $cb ), _errorCb( $client, $cb ) );
}

sub latestPodcasts {
	my ( $client, $cb, $args ) = @_;
	Plugins::RadioHelsinki::API::getLatestPodcasts( _episodesCb( $client, $cb ), _errorCb( $client, $cb ) );
}

sub popularPodcasts {
	my ( $client, $cb, $args ) = @_;
	Plugins::RadioHelsinki::API::getPopularPodcasts( _episodesCb( $client, $cb ), _errorCb( $client, $cb ) );
}

# ---------------------------------------------------------------------------
# Programs
# ---------------------------------------------------------------------------

sub programList {
	my ( $client, $cb, $args, $opts ) = @_;

	Plugins::RadioHelsinki::API::getPrograms(
		sub {
			my $programs = shift;

			my @items = map { _programItem($_) }
				grep { $_->{archive} == $opts->{archive} } @{ $programs->{list} };

			$cb->( { items => @items ? \@items : [ _empty($client) ] } );
		},
		_errorCb( $client, $cb ),
	);
}

sub searchPrograms {
	my ( $client, $cb, $args ) = @_;

	my $query = lc( $args->{search} || '' );

	Plugins::RadioHelsinki::API::getPrograms(
		sub {
			my $programs = shift;

			my @items = map { _programItem($_) }
				grep { index( lc( $_->{title} ), $query ) >= 0 } @{ $programs->{list} };

			$cb->( {
				items => @items ? \@items : [ {
					name => cstring( $client, 'PLUGIN_RADIOHELSINKI_NO_MATCH' ),
					type => 'text',
				} ],
			} );
		},
		_errorCb( $client, $cb ),
	);
}

sub _programItem {
	my $prog = shift;

	return {
		name        => $prog->{title},
		line1       => $prog->{title},
		line2       => $prog->{desc},
		type        => 'link',
		image       => $prog->{img} || FALLBACK_ICON,
		url         => \&programContent,
		passthrough => [$prog],

		# Make the program itself favouritable, not just its episodes. The favourite
		# stores this plain URL (not the coderef above) plus the parser; reopening it
		# refetches and rebuilds the menu, so the program stays current. See Parser.pm.
		favorites_url   => Plugins::RadioHelsinki::API::programContentUrl( $prog->{id} ),
		favorites_type  => 'link',
		favorites_title => $prog->{title},
		favorites_icon  => $prog->{img} || FALLBACK_ICON,
		parser          => 'Plugins::RadioHelsinki::Parser',

		# The row has to be *playable* for a skin to offer "Add to favourites":
		# XMLBrowser only attaches the favourites handle (presetParams) to playable
		# items. This is the same trick the bundled Podcast plugin uses to favourite a
		# show — playlist points at the program feed, so "play" queues its episodes,
		# while a plain tap still browses (the coderef url / go action; type is link, so
		# it is not touch-to-play).
		playlist => Plugins::RadioHelsinki::API::programContentUrl( $prog->{id} ),
	};
}

# A program has up to four sections. Most have only one — sitting through an extra
# menu level to reach the only thing there is would be silly, so when a program has a
# single non-empty section its contents are listed directly.
sub programContent {
	my ( $client, $cb, $args, $prog ) = @_;

	Plugins::RadioHelsinki::API::getProgramContent(
		$prog,
		sub {
			$cb->( { items => programItems( $client, shift, $prog ) } );
		},
		_errorCb( $client, $cb ),
	);
}

# Build a program's menu items from its content. Shared by browsing (programContent)
# and by reopening a favourited program (Parser.pm), so both render identically.
sub programItems {
	my ( $client, $content, $prog ) = @_;

	my $icon = $prog->{img} || FALLBACK_ICON;

	# All three content types get the same episode submenus; only on-demand
	# recordings have tracklists to attach.
	my @sections = (
		[
			'PLUGIN_RADIOHELSINKI_SECTION_EPISODES',
			_episodeMenus( $client, $content->{ondemand}, $content->{playlists}, $prog )
		],
		[
			'PLUGIN_RADIOHELSINKI_SECTION_PODCASTS',
			_episodeMenus( $client, $content->{podcasts}, undef, $prog )
		],
		[
			'PLUGIN_RADIOHELSINKI_SECTION_CLIPS',
			_episodeMenus( $client, $content->{clips}, undef, $prog )
		],
	);

	my @populated = grep { @{ $_->[1] } } @sections;

	return [ _empty($client) ] if !@populated;

	# The full programme description, shown inside the programme's own menu. In
	# menuMode (Material, players) XMLBrowser lifts a textarea item out of the list
	# and renders it as a wrapped text block above the content — this is where the
	# whole description is readable; the line2 on the programme row is only a
	# preview that skins truncate.
	my @about = length( $prog->{descLong} || '' )
		? ( { name => $prog->{descLong}, type => 'textarea', wrap => 1 } )
		: ();

	# Every program renders the same shape — description, play-newest, then sections
	# (only the non-empty ones). Earlier versions flattened single-section programs
	# straight to their episode list, which made Aikakone and Rakkaudesta open with
	# visibly different structures for no reason a listener could see.
	my @items = map { {
		name  => cstring( $client, $_->[0] ) . ' (' . scalar( @{ $_->[1] } ) . ')',
		type  => 'link',
		image => $icon,
		items => $_->[1],
	} } @populated;

	# One tap to the newest episode, which is what you usually came for — the only
	# one-tap play left now that episodes open as submenus.
	#
	# Built from the raw episode ($content->{ondemand}[0]), not $episodes->[0]: the
	# latter is a browsable wrapper with no audio of its own.
	if ( my $newest = $content->{ondemand}->[0] ) {
		my $shortcut = _playItem( $client, $newest, cstring( $client, 'PLUGIN_RADIOHELSINKI_PLAY_NEWEST' ) );

		# Date plus the episode's description preview, so the shortcut says what it
		# will play. line2 is already the preview (or the program name as fallback);
		# skip the suffix when it would just repeat the program name. \x{00B7}, not a
		# literal middle dot — no `use utf8` here.
		my $preview = $newest->{line2} || '';
		$shortcut->{line2} = $newest->{name}
			. ( length($preview) && $preview ne $prog->{title} ? " \x{00B7} $preview" : '' );

		unshift @items, $shortcut;
	}

	return [ @about, @items ];
}

# ---------------------------------------------------------------------------
# Playlists
# ---------------------------------------------------------------------------

# Every on-demand episode opens the same small menu: the full description (when there
# is one), a play row, and the broadcast's tracklist (when there is one).
#
# Why a submenu at all: an LMS row cannot be both play-on-tap and browse-into —
# XMLBrowser treats any `type => 'audio'` item as a playable leaf, and skins offer no
# reachable place to show its full description. Earlier versions kept plain episodes
# one-tap-play, which made them structurally different from tracklist episodes AND
# left their descriptions unreadable. Uniform submenus fix both; the one-tap case
# lives in the program-level "Toista uusin jakso" shortcut.
#
# The wrapper itself must NOT carry a `description` key — an item with one is treated
# as a leaf, which would kill the drill-down. The text goes inside as a textarea.
#
# Assembled here, not in API.pm, because these items hold coderefs and Storable cannot
# freeze a coderef into the cache.
sub _episodeMenus {
	my ( $client, $list, $playlists, $prog ) = @_;

	$playlists ||= {};

	my $icon = $prog->{img} || FALLBACK_ICON;

	my %used;
	my @episodes;

	for my $episode ( @{ $list || [] } ) {
		my $key =
			  $playlists->{ $episode->{_begin} || '' } ? $episode->{_begin}
			: $playlists->{ $episode->{_end}   || '' } ? $episode->{_end}
			:                                            undef;

		$used{$key} = 1 if defined $key;

		my $tracks = defined $key ? $playlists->{$key} : [];

		# The broadcast's tracklist, one level down. It used to sit inline under
		# the play rows, which read as one confusing flat list — 20 rows of
		# artists with no hint that tapping one searches the library/Spotify
		# rather than playing anything.
		my @trackSection = @$tracks
			? ( {
				name  => cstring( $client, 'PLUGIN_RADIOHELSINKI_TRACKLIST' ) . ' (' . scalar(@$tracks) . ')',
				line1 => cstring( $client, 'PLUGIN_RADIOHELSINKI_TRACKLIST' ) . ' (' . scalar(@$tracks) . ')',
				line2 => cstring( $client, 'PLUGIN_RADIOHELSINKI_TRACKLIST_DESC' ),
				type  => 'link',
				image => $episode->{image} || $icon,
				items => [ map { Plugins::RadioHelsinki::Search::trackItem( $client, $_, $prog ) } @$tracks ],
			} )
			: ();

		# Half-listened episodes get a resume row above the play row, which is then
		# relabelled so "from the beginning" is an explicit choice, not a surprise.
		my @resume = _resumeItem( $client, $episode );

		# Lead with the programme, same style as the cross-programme lists — the
		# name doubles as the submenu header, where a bare date says nothing
		# about what it belongs to. Skipped when the episode's own name already
		# carries it (some clips do). \x{2013} escape — no `use utf8` here.
		my $name =
			length( $prog->{title} || '' ) && index( $episode->{name}, $prog->{title} ) < 0
			? "$prog->{title} \x{2013} $episode->{name}"
			: $episode->{name};

		push @episodes, {
			name  => $name,
			line1 => $name,
			line2 => $episode->{line2},
			type  => 'link',
			image => $episode->{image} || $icon,
			items => [
				length( $episode->{description} || '' )
					? ( { name => $episode->{description}, type => 'textarea', wrap => 1 } )
					: (),
				@resume,
				_playItem( $client, $episode, cstring( $client,
					@resume ? 'PLUGIN_RADIOHELSINKI_PLAY_FROM_BEGINNING'
							: 'PLUGIN_RADIOHELSINKI_PLAY_EPISODE' ) ),
				@trackSection,
			],
		};
	}

	# A few playlists belong to broadcasts that were never recorded, so they have no
	# episode to hang from and nothing to listen to. Say so rather than dropping them
	# silently.
	my $orphans = ( scalar keys %$playlists ) - ( scalar keys %used );

	main::INFOLOG
		&& $orphans
		&& $log->is_info
		&& $log->info("$prog->{title}: $orphans playlist(s) with no recording");

	return \@episodes;
}

# Turn an episode into a plain playable row under a given label, dropping the internal
# bookkeeping keys. Used for the "play newest" shortcut and the "play this episode"
# entry inside a playlist submenu.
#
# Inside a playlist submenu this row sits above 20 track rows that look just like it, so
# it is marked as the odd one out two ways: a leading play glyph (visible in every skin,
# including the plain web UI) and playcontrol => 'play', which asks Jive/Material to give
# it the distinct play-action style. \x{25B6}, not a literal triangle — this file has no
# `use utf8`.
sub _playItem {
	my ( $client, $episode, $label ) = @_;

	my %item = %$episode;

	# No line2: these rows live inside the episode's own submenu, whose header
	# already names the episode — repeating it under every action row is noise.
	# The one caller that needs a subtitle (the "play newest" shortcut, which
	# sits outside the submenu) sets its own.
	delete @item{qw(items _begin _end line2)};

	$item{name} = $item{line1} = "\x{25B6} $label";
	$item{playcontrol} = 'play';

	return \%item;
}

# The "resume from 12:34" row — one element when a saved position exists, empty
# list otherwise, so callers can splice it in unconditionally. The row's URL
# carries the position as a {from=N} suffix; ProtocolHandler.pm turns it into a
# byte-offset seek before the stream starts.
#
# Copies $episode, never mutates it: the episode hashes live inside API.pm's
# cached lists and are shared across requests.
sub _resumeItem {
	my ( $client, $episode ) = @_;

	my $pos = Plugins::RadioHelsinki::API::getPosition( $episode->{url} ) or return ();

	# Practically finished counts as finished. Lenient when the duration is
	# unknown (podcasts and clips) — a stale row beats a lost position.
	return () if $episode->{duration} && $pos >= $episode->{duration} - 15;

	my $t = _shortTime($pos);

	my %item = %$episode;

	# line2 dropped for the same reason as in _playItem below.
	delete @item{qw(items _begin _end description line2)};

	$item{name} = $item{line1} =
		"\x{25B6} " . cstring( $client, 'PLUGIN_RADIOHELSINKI_PLAY_FROM_POSITION_X', $t );
	$item{playcontrol} = 'play';
	$item{url} = $item{play} = Plugins::RadioHelsinki::API::wrapUrl(
		Plugins::RadioHelsinki::API::plainUrl( $episode->{url} ), $pos );

	return \%item;
}

# Flat-list counterpart: those lists are one-tap audio leaves, so an episode with
# a saved position is converted (on a copy) into a small submenu — resume row,
# from-the-beginning row — exactly like the bundled Podcast plugin's recent list.
# Episodes without a position pass through untouched.
sub _maybeResume {
	my ( $client, $item ) = @_;

	my @resume = _resumeItem( $client, $item ) or return $item;

	my %wrapper = %$item;

	# Keep `play` so the wrapper still acts playable (play button,
	# presetParams/favouriting) — but drop `on_select`: with it a touch skin
	# plays the row from the start on tap instead of opening the submenu,
	# which is exactly the resume choice this wrapper exists to offer. Drop
	# `url` and `description` too so it browses instead of acting as a leaf.
	delete @wrapper{qw(url description on_select)};
	$wrapper{type}  = 'link';
	$wrapper{items} = [
		length( $item->{description} || '' )
			? ( { name => $item->{description}, type => 'textarea', wrap => 1 } )
			: (),
		@resume,
		_playItem( $client, $item, cstring( $client, 'PLUGIN_RADIOHELSINKI_PLAY_FROM_BEGINNING' ) ),
	];

	# {from=0}: differs from the wrapper's own play URL so XMLBrowser treats it
	# as a distinct playable row; a startTime of 0 is falsy, so it simply plays
	# from the start. (The Podcast plugin's little trick.)
	$wrapper{items}[-1]{url} = $wrapper{items}[-1]{play} =
		Plugins::RadioHelsinki::API::wrapUrl(
			Plugins::RadioHelsinki::API::plainUrl( $item->{url} ), 0 );

	return \%wrapper;
}

# "1:23:45", not "01:23:45" — the leading zero is just noise in a menu row.
sub _shortTime {
	my $t = Slim::Utils::DateTime::timeFormat(shift);
	$t =~ s/^0+[:\.]//;
	return $t;
}

# ---------------------------------------------------------------------------
# Callback plumbing
# ---------------------------------------------------------------------------

sub _episodesCb {
	my ( $client, $cb ) = @_;

	return sub {
		my $items = shift;

		# Never map over $items in place — it is a cached, shared list.
		my @out = map { _maybeResume( $client, $_ ) } @$items;

		$cb->( { items => @out ? \@out : [ _empty($client) ] } );
	};
}

# API.pm already falls back to stale data, so reaching here means there is
# genuinely nothing to show.
sub _errorCb {
	my ( $client, $cb ) = @_;

	return sub {
		my $error = shift;

		$log->warn("menu failed: $error");

		$cb->( {
			items => [ {
				name => $error || cstring( $client, 'PLUGIN_RADIOHELSINKI_ERROR' ),
				type => 'text',
			} ],
		} );
	};
}

sub _empty {
	my $client = shift;

	return {
		name => cstring( $client, 'PLUGIN_RADIOHELSINKI_EMPTY' ),
		type => 'text',
	};
}

1;
