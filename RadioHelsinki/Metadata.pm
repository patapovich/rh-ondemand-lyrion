package Plugins::RadioHelsinki::Metadata;

# The audio is a plain MP3 on Cloudflare with Content-Length and Accept-Ranges,
# so the stock HTTP(S) machinery streams and seeks it natively. Episode URLs are
# nevertheless wrapped as radiohelsinki://<https-url> by API.pm — not for
# streaming, but so ProtocolHandler.pm gets the lifecycle hooks that power
# resume-from-position. LMS still knows nothing about the track beyond its
# filename, which is where this provider comes in.
#
# Slim::Player::Protocols::HTTP::getMetadataFor() asks
# Slim::Formats::RemoteMetadata for a provider matching the URL, so we register
# one and serve back what API.pm cached when it built the menu. The provider can
# be handed either form of the URL — the wrapped one once the handler's scanUrl
# has renamed the track, the plain one before that and for old favourites — so
# MATCH accepts both and the lookup key is normalised to the plain form the
# caches are keyed by.
#
# This is also what makes favourites work: the metadata outlives the menu that
# produced it.

use strict;
use warnings;

use Slim::Formats::RemoteMetadata;
use Slim::Utils::Log;

use Plugins::RadioHelsinki::API;

# The archive spans several storage generations, not just the current CDN:
#
#   https://cdn.radiohelsinki.fi/ondemand/2026/...            (current)
#   https://radiohelsinki-podcast.s3.amazonaws.com/...        (~2017-2019)
#   http://s3.eu-central-1.wasabisys.com/cdn.radiohelsinki.fi/...
#   http://objects.fi-1.nebulacloud.fi/swift/v1/rh2017ondemand/...
#
# So match any host containing "radiohelsinki", or any URL whose first path segment
# (optionally behind swift/v1/) is one of the station's bucket names. The wasabi and
# nebulacloud hosts are shared object storage — matching them by host alone would
# claim other tenants' streams.
# The live stream host is EXCLUDED here: Live.pm owns stream.radiohelsinki.fi
# with its own provider (and parser). This regex must never claim it — an
# accidental match would shadow Live.pm's registration or, historically,
# RadioNowPlaying's (Tie::RegexpHash gives a URL to the FIRST registered
# matching provider; within a plugin, whichever init runs first).
use constant MATCH =>
	qr{^(?:radiohelsinki://)?https?://(?:(?!stream\.)[^/]*radiohelsinki[^/]*/|[^/]+/(?:swift/v1/)?(?:rh2017ondemand|cdn\.radiohelsinki\.fi)/)}i;

my $log = logger('plugin.radiohelsinki');

sub init {
	Slim::Formats::RemoteMetadata->registerProvider(
		match => MATCH,
		func  => \&provider,
	);
}

sub provider {
	my ( $client, $url ) = @_;

	# All caches are keyed by the plain https URL; we may be handed the wrapped one.
	$url = Plugins::RadioHelsinki::API::plainUrl($url);

	# 1. Exact per-episode metadata, if this track's menu was ever browsed.
	my $meta = Plugins::RadioHelsinki::API::getMeta($url);

	if ( $meta && keys %$meta ) {
		main::DEBUGLOG && $log->is_debug && $log->debug("serving cached metadata for $url");
		return $meta;
	}

	# 2. Fallback for a track played without a browse (straight from a favourite, or
	#    resumed after a restart). Everything derivable from the URL: the date, plus the
	#    real program name and cover via the token map (one entry per program, written
	#    from any browse of any of its episodes, in the non-purging cache).
	my $title;
	$title = "$3.$2.$1" if $url =~ m{/(\d{4})(\d{2})(\d{2})_}i;

	my $tok = Plugins::RadioHelsinki::API::getTokenMeta($url);

	# Nothing recognisable: not one of the station's on-demand files. (The live
	# stream no longer even matches MATCH — see above — this is a last line of
	# defence for anything else on a shared host.) Returning anything non-empty
	# here would suppress other providers' and ICY handling for it.
	return {} unless $title || $tok;

	my %m = ( album => 'Radio Helsinki', type => 'MP3' );

	$m{title} = $title if $title;

	if ($tok) {
		$m{artist} = $tok->{artist} if $tok->{artist};
		$m{cover}  = $m{icon} = $tok->{cover} if $tok->{cover};
	}

	main::DEBUGLOG && $log->is_debug && $log->debug("synthesised metadata for $url");

	return \%m;
}

1;
