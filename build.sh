#!/usr/bin/env bash
#
# Package the plugin and generate the repository manifest Lyrion installs from.
#
# The zip must have install.xml at its top level (no wrapping directory) and the
# <sha> in repo.xml must be the zip's SHA1 — Lyrion verifies it before extracting.
#
#   ./build.sh                                  # serve from this machine's LAN IP
#   RH_BASE_URL=https://you.github.io/rh ./build.sh   # for a real release

set -euo pipefail

cd "$(dirname "$0")"

PLUGIN=RadioHelsinki
VERSION=$(sed -n 's:.*<version>\(.*\)</version>.*:\1:p' "$PLUGIN/install.xml" | head -1)

if [[ -z "$VERSION" ]]; then
	echo "error: no <version> in $PLUGIN/install.xml" >&2
	exit 1
fi

# Default to serving straight off this machine — the dev loop is a local
# `python3 -m http.server`, not a round trip through GitHub.
LAN_IP=$(ip -4 -o addr show scope global 2>/dev/null | awk 'NR==1 {sub(/\/.*/,"",$4); print $4}')
BASE_URL="${RH_BASE_URL:-http://${LAN_IP:-127.0.0.1}:8000}"

ZIP="$PLUGIN-$VERSION.zip"

rm -f "$PLUGIN"-*.zip

( cd "$PLUGIN" && zip -qr "../$ZIP" . -x '*.DS_Store' -x '__MACOSX/*' )

SHA=$(sha1sum "$ZIP" | cut -d' ' -f1)

cat > repo.xml <<XML
<?xml version="1.0" encoding="utf-8"?>
<extensions>
  <plugins>
    <plugin name="$PLUGIN" version="$VERSION" minTarget="8.0" maxTarget="*">
      <title lang="EN">Radio Helsinki</title>
      <title lang="FI">Radio Helsinki</title>
      <desc lang="EN">Browse and play Radio Helsinki on-demand programs, podcasts and clips.</desc>
      <desc lang="FI">Selaa ja kuuntele Radio Helsingin ohjelmia, podcasteja ja klippejä.</desc>
      <creator>Miska</creator>
      <category>musicservices</category>
      <link>https://github.com/patapovich/rh-ondemand-lyrion</link>
      <url>$BASE_URL/$ZIP</url>
      <sha>$SHA</sha>
    </plugin>
  </plugins>
  <details>
    <title lang="EN">Radio Helsinki Repository</title>
  </details>
</extensions>
XML

echo "built  $ZIP  ($(du -h "$ZIP" | cut -f1), sha1 $SHA)"
echo "repo   $BASE_URL/repo.xml"
