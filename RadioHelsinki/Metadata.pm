package Plugins::RadioHelsinki::Metadata;

# The audio is a plain MP3 on Cloudflare with Content-Length and Accept-Ranges,
# so Slim::Player::Protocols::HTTP streams and seeks it natively and there is no
# protocol handler here. But that also means LMS knows nothing about the track
# beyond its filename.
#
# Slim::Player::Protocols::HTTP::getMetadataFor() asks
# Slim::Formats::RemoteMetadata for a provider matching the URL, so we register
# one and serve back what API.pm cached under the same URL when it built the menu.
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
use constant MATCH =>
	qr{^https?://(?:[^/]*radiohelsinki[^/]*/|[^/]+/(?:swift/v1/)?(?:rh2017ondemand|cdn\.radiohelsinki\.fi)/)}i;

my $log = logger('plugin.radiohelsinki');

sub init {
	Slim::Formats::RemoteMetadata->registerProvider(
		match => MATCH,
		func  => \&provider,
	);
}

sub provider {
	my ( $client, $url ) = @_;

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

	# Nothing recognisable: this is not one of the station's on-demand files — most
	# likely the live stream, whose host also matches. Returning anything non-empty
	# here would suppress LMS's own ICY-title handling for it, so claim nothing.
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
