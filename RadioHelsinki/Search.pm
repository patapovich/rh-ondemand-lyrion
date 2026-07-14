package Plugins::RadioHelsinki::Search;

# What to do with a track you heard on the radio.
#
# Radio Helsinki's playlists carry no usable timestamps (see _parsePlaylists in
# API.pm), so a track cannot seek into the recording. What it *can* do is answer the
# only question worth asking about a song you liked: do I already own this, and if
# not, can I play it anyway?
#
# So a track opens a menu with local library matches and, when Spotty is installed,
# Spotify hits. Both are rendered as our own playable OPML items, so they work in the
# web UI as well as on players.
#
# Everything here goes through Slim::Control::Request::executeRequest with a
# callback. That matters: the local library query answers synchronously, but Spotty
# has to reach Spotify and does not. The callback fires on completion either way, so
# the same code path is correct for both.

use strict;
use warnings;

use Slim::Control::Request;
use Slim::Utils::Log;
use Slim::Utils::PluginManager;
use Slim::Utils::Strings qw(cstring);

use constant SPOTTY => 'Plugins::Spotty::Plugin';

# Spotty's search node, addressed positionally because it exposes no stable named
# entry point. Verified against Spotty on LMS 9.1. Should a future Spotty reorder its
# top-level menu, this lands somewhere harmless and the section simply comes back
# empty — _spotify() treats anything unexpected as "no hits" rather than an error.
use constant SPOTTY_SEARCH_ID => '1.0';

use constant LIBRARY_SCAN  => 50;    # titles to sift before filtering by artist
use constant SPOTIFY_SCAN  => 20;    # Spotty puts category rows first; look past them
use constant SPOTIFY_LIMIT => 5;     # each hit costs one more round trip (see below)

my $log = logger('plugin.radiohelsinki');

sub trackItem {
	my ( $client, $track, $prog ) = @_;

	return {
		name        => _label($track),
		line1       => $track->{song},
		line2       => $track->{artist},
		type        => 'link',
		image       => $prog->{img},
		url         => \&trackMenu,
		passthrough => [$track],
	};
}

sub trackMenu {
	my ( $client, $cb, $args, $track ) = @_;

	my %section;
	my $outstanding = 2;

	my $done = sub {
		return if --$outstanding > 0;

		my @items = grep { $_ } $section{library}, $section{spotify};

		$cb->( {
			items => @items ? \@items : [ {
				name => cstring( $client, 'PLUGIN_RADIOHELSINKI_NO_HITS' ),
				type => 'text',
			} ],
		} );
	};

	_library( $client, $track, sub { $section{library} = shift; $done->() } );
	_spotify( $client, $track, sub { $section{spotify} = shift; $done->() } );
}

# ---------------------------------------------------------------------------
# Your own library
# ---------------------------------------------------------------------------

# LMS can only free-text search titles, so cast a wide net on the song title and
# filter by artist ourselves.
sub _library {
	my ( $client, $track, $cb ) = @_;

	return $cb->(undef) unless length( $track->{song} || '' );

	Slim::Control::Request::executeRequest(
		$client,
		[ 'titles', 0, LIBRARY_SCAN, 'search:' . $track->{song}, 'tags:uladce' ],
		sub {
			my $request = shift;

			my @hits;

			for my $t ( @{ $request->getResult('titles_loop') || [] } ) {
				next unless $t->{url};
				next unless _artistMatches( $track->{artist}, $t->{artist} );

				push @hits, {
					name      => $t->{title},
					line1     => $t->{title},
					line2     => $t->{artist},
					type      => 'audio',
					url       => $t->{url},
					play      => $t->{url},
					on_select => 'play',
					$t->{duration} ? ( duration => $t->{duration} ) : (),
					$t->{coverid} ? ( image => '/music/' . $t->{coverid} . '/cover.jpg' ) : (),
				};
			}

			$cb->( @hits ? _section( $client, 'PLUGIN_RADIOHELSINKI_IN_LIBRARY', \@hits ) : undef );
		},
	);
}

# Radio Helsinki shouts its artists ("ALICE COLTRANE"); a library says "Alice
# Coltrane", or "Alice Coltrane Quartet", or files the track under a compilation.
# Match loosely both ways and accept the odd false positive — a spurious row costs
# nothing, a missed match costs the whole feature.
sub _artistMatches {
	my ( $want, $got ) = @_;

	return 1 unless length( $want || '' );    # nothing to check against
	return 0 unless length( $got  || '' );

	my $a = lc $want;
	my $b = lc $got;

	return index( $b, $a ) >= 0 || index( $a, $b ) >= 0;
}

# ---------------------------------------------------------------------------
# Spotify, via Spotty
# ---------------------------------------------------------------------------

sub _spotify {
	my ( $client, $track, $cb ) = @_;

	return $cb->(undef) unless $client;
	return $cb->(undef) unless Slim::Utils::PluginManager->isEnabled(SPOTTY);

	my $query = join ' ', grep { length } $track->{artist}, $track->{song};

	return $cb->(undef) unless length $query;

	Slim::Control::Request::executeRequest(
		$client,
		[ 'spotty', 'items', 0, SPOTIFY_SCAN, 'item_id:' . SPOTTY_SEARCH_ID, "search:$query" ],
		sub {
			my $request = shift;

			# Spotty leads with category submenus (Artists, Albums, Playlists...) and
			# only then the direct track hits, which are the ones flagged isaudio.
			my @hits = grep { $_->{isaudio} && $_->{id} }
				@{ $request->getResult('loop_loop') || [] };

			splice @hits, SPOTIFY_LIMIT if @hits > SPOTIFY_LIMIT;

			return $cb->(undef) unless @hits;

			_resolve( $client, $query, \@hits, $cb );
		},
	);
}

# A Spotty search row is not playable: it carries a name and an internal item id, but
# no URL. Descending into it yields exactly one child whose name IS the playable URI
# ("spotify://track:2gG3ivmsfylVXLyIJvLXyN"). So each hit costs one more round trip,
# which is why SPOTIFY_LIMIT is small. They are fired together rather than in series.
sub _resolve {
	my ( $client, $query, $hits, $cb ) = @_;

	my @items;
	my $outstanding = scalar @$hits;

	for my $i ( 0 .. $#{$hits} ) {
		my $hit = $hits->[$i];

		Slim::Control::Request::executeRequest(
			$client,
			[ 'spotty', 'items', 0, 1, 'item_id:' . $hit->{id}, "search:$query" ],
			sub {
				my $request = shift;

				my $child = ( $request->getResult('loop_loop') || [] )->[0];
				my $url   = $child && $child->{name};

				if ( $url && $url =~ m{^spotify://}i ) {
					# Keep the original index so the results stay in Spotify's
					# relevance order despite completing out of order.
					$items[$i] = {
						name      => $hit->{name},
						type      => 'audio',
						url       => $url,
						play      => $url,
						on_select => 'play',
						$hit->{image} ? ( image => $hit->{image} ) : (),
					};
				}
				else {
					$log->warn("no spotify uri behind $hit->{id}");
				}

				return if --$outstanding > 0;

				my @ok = grep { $_ } @items;

				$cb->( @ok ? _section( $client, 'PLUGIN_RADIOHELSINKI_ON_SPOTIFY', \@ok ) : undef );
			},
		);
	}
}

# ---------------------------------------------------------------------------

sub _section {
	my ( $client, $token, $items ) = @_;

	return {
		name  => cstring( $client, $token ) . ' (' . scalar(@$items) . ')',
		type  => 'link',
		items => $items,
	};
}

sub _label {
	my $track = shift;

	# \x{2013}, not a literal en-dash: this file has no `use utf8`, so a literal one
	# would be read as three raw bytes and reach the menu as mojibake.
	return join " \x{2013} ", grep { length } $track->{artist}, $track->{song};
}

1;
