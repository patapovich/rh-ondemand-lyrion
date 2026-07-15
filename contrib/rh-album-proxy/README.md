# rh-album-proxy

A tiny enrichment proxy between the [RadioNowPlaying](http://radionowplaying.com/)
LMS plugin and Radio Helsinki's now-playing feed. Not part of the RadioHelsinki
plugin — it improves the **live stream's** metadata, which RadioNowPlaying owns.

## Why

- The station's feed (`https://www.radiohelsinki.fi/wp-content/djonline.js`)
  has an `album` field but never fills it (`label` and `year` are empty too).
- Cloudflare in front of the station intermittently bot-blocks LMS's default
  User-Agent.
- RadioNowPlaying's own cover-search service (radionowplaying.com/coversearch)
  is gone (404), so nothing else fills the gap.

The proxy impersonates the feed: fetches the real `djonline.js` with a browser
User-Agent, fills the empty `album` field on the newest rows via the free
iTunes Search API (`country=FI`, cached in memory, failed lookups retried
after 6 h), and returns the document otherwise unchanged. Every failure mode
degrades to passing the original content (or error status) through.

## Install (on the LMS host)

```sh
cp rh-album-proxy.py /usr/local/lib/rh-album-proxy.py
cp rh-album-proxy.service /etc/systemd/system/rh-album-proxy.service
systemctl daemon-reload
systemctl enable --now rh-album-proxy
curl 'http://127.0.0.1:9099/djonline.js?dt=0000000000000_0'   # should return feed JSON
```

Then point RadioNowPlaying at it: copy `stationdata-radiohelsinkifi.json` into
RadioNowPlaying's `stationdata/` directory (the non-`init-` filename marks it
as a user override that survives plugin updates) — its `songurl` is
`http://127.0.0.1:9099/djonline.js?dt=${unixtime}000_0` — and restart LMS.

## Rollback

Point `songurl` in the stationdata file back at
`https://www.radiohelsinki.fi/wp-content/djonline.js?dt=${unixtime}000_0`,
restart LMS, `systemctl disable --now rh-album-proxy`.

## Caveats

- Album names come from iTunes: singles show as "Song – Single", and releases
  missing from the iTunes catalogue stay albumless.
- The station's feed itself lags song changes by ~30–60 s; the proxy does not
  (and cannot) change that.
- RadioNowPlaying logs "Cloudflare is blocking your access" for *any* failed
  response with Cloudflare headers — with the proxy in place the usual real
  cause is the station's origin answering 502/504.
