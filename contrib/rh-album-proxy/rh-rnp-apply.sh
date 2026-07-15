#!/bin/sh
# Re-apply the customised Radio Helsinki station file for RadioNowPlaying.
# A plugin update replaces the whole plugin directory, wiping the customised
# songurl/songheaders/forcemetapoll; this restores them and restarts LMS once.
# No-op when the deployed file already matches the master.

MASTER=/usr/local/lib/rh-rnp-stationdata.json
TARGET=/var/lib/squeezeboxserver/cache/InstalledPlugins/Plugins/RadioNowPlaying/stationdata/stationdata-radiohelsinkifi.json

[ -f "$MASTER" ] || exit 0
[ -d "$(dirname "$TARGET")" ] || exit 0

if ! cmp -s "$MASTER" "$TARGET"; then
	cp "$MASTER" "$TARGET"
	chown squeezeboxserver "$TARGET"
	logger -t rh-rnp-apply "restored customised stationdata-radiohelsinkifi.json, restarting LMS"
	systemctl restart lyrionmusicserver
fi
