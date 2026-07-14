package Plugins::RadioHelsinki::Plugin;

# Radio Helsinki on-demand for Lyrion Music Server.
#
# An OPML menu tree over the station's public WordPress REST API. All the
# JSON handling lives in API.pm; this file is only the shape of the menu.

use strict;
use warnings;

use base 'Slim::Plugin::OPMLBased';

use Slim::Utils::Log;
use Slim::Utils::Strings qw(cstring);

use Plugins::RadioHelsinki::API;
use Plugins::RadioHelsinki::Metadata;
use Plugins::RadioHelsinki::Search;
use Plugins::RadioHelsinki::Parser;

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

	$class->SUPER::initPlugin(
		feed   => \&handleFeed,
		tag    => 'radiohelsinki',
		menu   => 'radios',
		weight => 10,
	);
}

sub getDisplayName { 'PLUGIN_RADIOHELSINKI' }

# ---------------------------------------------------------------------------
# Top level
# ---------------------------------------------------------------------------

sub handleFeed {
	my ( $client, $cb, $args ) = @_;

	$cb->( {
		items => [
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

		push @episodes, {
			name  => $episode->{name},
			line1 => $episode->{name},
			line2 => $episode->{line2},
			type  => 'link',
			image => $episode->{image} || $icon,
			items => [
				length( $episode->{description} || '' )
					? ( { name => $episode->{description}, type => 'textarea', wrap => 1 } )
					: (),
				_playItem( $client, $episode, cstring( $client, 'PLUGIN_RADIOHELSINKI_PLAY_EPISODE' ) ),
				map { Plugins::RadioHelsinki::Search::trackItem( $client, $_, $prog ) } @$tracks,
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

	delete @item{qw(items _begin _end)};

	$item{name} = $item{line1} = "\x{25B6} $label";
	$item{line2}      = $episode->{name};
	$item{playcontrol} = 'play';

	return \%item;
}

# ---------------------------------------------------------------------------
# Callback plumbing
# ---------------------------------------------------------------------------

sub _episodesCb {
	my ( $client, $cb ) = @_;

	return sub {
		my $items = shift;
		$cb->( { items => @$items ? $items : [ _empty($client) ] } );
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
