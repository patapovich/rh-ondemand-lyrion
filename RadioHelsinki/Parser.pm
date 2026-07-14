package Plugins::RadioHelsinki::Parser;

# Rebuilds a program's menu when a favourited program is reopened.
#
# A program row carries favorites_url => the program_content API endpoint, so the
# favourite stores a plain URL rather than a coderef (which could not be serialised).
# When you open the favourite, XMLBrowser fetches that URL and hands the response to
# this parser, which turns it back into the same episode/playlist menu you would get
# by browsing — so a favourited program stays current as new episodes appear, which is
# the whole reason to favourite the program rather than one episode.
#
# This mirrors how the bundled Podcast plugin favourites a show (favorites_url + a
# parser class), see Slim::Plugin::Podcast.

use strict;
use warnings;

use JSON::XS::VersionOneAndTwo;

use Slim::Utils::Log;

use Plugins::RadioHelsinki::API;

my $log = logger('plugin.radiohelsinki');

sub parse {
	my ( $class, $http ) = @_;

	my ($id) = ( $http->url || '' ) =~ m{/program_content/(\d+)};

	# Artwork and title come from the cached program directory; the program_content
	# payload alone does not carry them. A cold cache degrades to no artwork, never an
	# error.
	my $prog = ( $id && Plugins::RadioHelsinki::API::programById($id) )
		|| { id => $id, title => '', img => undef, archive => 0 };

	my $content = eval {
		Plugins::RadioHelsinki::API::_parseProgramContent(
			from_json( $http->content ), $prog
		);
	};

	if ( $@ || !$content ) {
		$log->warn("failed to parse favourited program $id: $@");
		return { items => [] };
	}

	# Plugin.pm is always loaded by the time a favourite can be opened.
	#
	# nocache => 1 is essential: the menu contains coderef items (the playlist track
	# submenus), and Slim::Formats::XML would otherwise Storable-freeze this feed into
	# DbCache and die with "Can't store CODE items". Skipping the parsed-feed cache
	# keeps the coderefs live; the raw HTTP response is still cached for speed.
	return {
		nocache => 1,
		items   => Plugins::RadioHelsinki::Plugin::programItems( undef, $content, $prog ),
	};
}

1;
