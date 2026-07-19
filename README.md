# Radio Helsinki for Lyrion Music Server

Browse and play [Radio Helsinki](https://www.radiohelsinki.fi/ohjelmat/)'s
on-demand archive, podcasts and clips from any Squeezebox client — and get
proper now-playing for the live stream: song, artist, album, cover art and a
truthful progress bar, none of which the stream itself carries.

```
Radio Helsinki
├─ Kesken                 half-listened episodes, resume where you stopped
├─ Viimeksi kuunnellut    last 50 episodes played
├─ Uusimmat jaksot        newest full-show recordings
├─ Uusimmat podcastit     newest podcast episodes
├─ Suositut podcastit
├─ Ohjelmat               current programs
│    └─ <program>
│         ├─ Toista uusin jakso
│         ├─ Jaksot
│         │    └─ <episode>
│         │         ├─ Jatka kohdasta 12:34   when a position is saved
│         │         ├─ Toista alusta
│         │         └─ Kappalelista (N)       the broadcast's tracklist:
│         │              └─ <track> → Kirjastossa / Spotifyssa
│         ├─ Podcastit
│         └─ Klipit
├─ Arkisto                programs no longer running
└─ Hae ohjelmia           search program titles
```

- **Resume.** Stopping mid-episode saves the spot (persistent, 30 days); the
  episode reopens with "Jatka kohdasta". Positions clear when an episode plays
  to its natural end — including the natural-end case the bundled Podcast
  plugin misses.
- **Favourites.** Episodes, programs, and the Kesken/Viimeksi kuunnellut lists
  can all be favourited; a favourited program stays live as episodes appear.
- **Live stream.** While `stream.radiohelsinki.fi` plays, the plugin polls the
  station's own song log and shows the current song with album cover (iTunes,
  programme cover as fallback), the programme with its slot description and
  hosts between songs, and progress bars synced to what you *hear*, not to the
  transmitter. "Nyt soi" in the song-info view links to the programme's
  archive menu and lists what's coming up next.
- Correct artwork, titles and seeking on everything, surviving restarts and
  plugin updates. Finnish and English.

## Install

**Settings → Plugins → Additional Repositories**, add:

```
https://raw.githubusercontent.com/patapovich/rh-ondemand-lyrion/main/repo.xml
```

Apply, install *Radio Helsinki*, let the server restart. The plugin appears
under **Radio**. Requires Lyrion Music Server 8.2+.

Manual install: unzip `RadioHelsinki-<version>.zip` from
[Releases](https://github.com/patapovich/rh-ondemand-lyrion/releases) so that
`install.xml` sits at `.../Plugins/RadioHelsinki/install.xml`, restart.
Debian packages use `/usr/share/squeezeboxserver/Plugins/`; repository
installs live under `<cachedir>/InstalledPlugins/Plugins/`.

## Settings

**Settings → Advanced → Radio Helsinki** — all about the live stream:

| Setting | Default | |
|---|---|---|
| Live-stream now-playing from this plugin | on | Off hands the stream to another plugin (e.g. RadioNowPlaying); applies at restart. |
| Listening delay | 7 s | How far your audio runs behind the air signal (buffering). Shifts the bars to match your ears. |
| Update interval | 4 s | Song-log poll cadence while the stream plays (2–30). |
| Song grace | 90 s | How long a song outlives its nominal length before the programme takes over. |

## How it works

| File | Job |
|---|---|
| `Plugin.pm` | The menu tree (`Slim::Plugin::OPMLBased`) and the song-info entries. |
| `API.pm` | Every station-API call, JSON → menu mapping, all caching, saved positions. |
| `ProtocolHandler.pm` | The `radiohelsinki://` wrapper that powers resume. |
| `Metadata.pm` | Now-playing metadata for archive tracks. |
| `Live.pm` | Now-playing for the live stream: poll, decide, push. |
| `Search.pm` | Tracklist entries: find the song in your library or on Spotify. |
| `Parser.pm` | Rebuilds a favourited program's menu on reopen. |
| `Settings.pm` | The settings page. |

### Archive playback and resume

The audio is plain MP3 on hosting that honours range requests, so LMS's stock
HTTP machinery streams and seeks it natively. Episode URLs are nevertheless
wrapped as `radiohelsinki://<https-url>` — not for streaming, but because only
a protocol handler sees the play lifecycle needed for resume: `scanUrl`
unwraps and stashes the start position, `onStop` saves the spot on explicit
stops, and `onPlayout` catches the natural end (the decoder-done hook; a track
that plays out never reaches `onStop`, which is why the Podcast plugin's
positions go stale there). The archive spans several storage generations —
the current CDN, an S3 bucket for ~2017–2019, two older object stores — and
everything keying on audio URLs matches all of them.

Now-playing metadata for archive tracks lives in a dedicated cache namespace
with purging disabled (`Slim::Utils::Cache->new('radiohelsinki', 1, 1)`) —
the shared default cache purges itself, which used to cost a track its title
and cover hours after it was browsed. A URL-token → program map (filenames
are `<yyyymmdd>_<token>_….mp3`) resolves program name and artwork even for
tracks never browsed this session: favourites, or resume after a restart.
Saved positions live in the same namespace, alongside two small indexes that
back the Kesken and Viimeksi kuunnellut menus — DbCache keys are hashed, so
without an index maintained at write time there is nothing to enumerate.

### The live stream

The stream carries no usable metadata at all — its SHOUTcast server
advertises `icy-metaint` but only ever sends empty blocks — so the station's
`djonline.js` feed (the same document behind their website player) is the
only now-playing source in existence. `Live.pm` polls it on a short timer
while the stream plays (demand-gated: no listener, no traffic), decides
song-vs-programme itself — the newest logged row counts from its logged start
until its real length plus a grace period — and pushes the result to the
player. Measured behaviours the code leans on: the feed publishes a song
~5–8 s after its logged start, needs a unique `dt=` cache-buster or
Cloudflare serves stale copies, and its origin 502s in short bursts exactly
at song boundaries (failures keep the last state and keep polling).

One iTunes search per song yields both the album name and a 600×600 cover,
cached persistently; the programme's cover (upgraded to the full-resolution
original when one exists) is the fallback. Progress bars are shifted by the
listening delay so they track the ears: the audio you hear runs seconds
behind the air signal, and an air-synced bar would already read ~7 s when a
song's first note leaves the speakers.

**Coexistence with RadioNowPlaying is automatic.** Plugins initialise
alphabetically and LMS hands a URL to the *first registered* matching entry
in each `Slim::Formats::RemoteMetadata` registry, so this plugin wins the
live stream deterministically. Both registries are claimed — the provider for
metadata, and the parser (returning "handled") because LMS consults the
parser registry independently for every in-stream metadata block and would
otherwise wake other handlers. RadioNowPlaying's polling only ever starts
from its own provider/parser being invoked, so it stays fully dormant for
this station while serving any other, and takes this one back if the plugin
is removed or the settings switch is turned off.

### Tracklists

Some programs publish a per-broadcast tracklist. **`created_at` in that data
is not airtime** — rows are entered days before or bulk-pasted after the
broadcast — so jump-to-song is impossible and deliberately not offered.
Selecting a track answers the question actually worth asking: do I own this,
and can I play it anyway? *Kirjastossa* searches your library (wide net on
the title, artist filtered loosely in both directions); *Spotifyssa* (with
Spotty) resolves the top hits in parallel — each hit costs an extra round
trip because Spotty exposes the playable `spotify://` URI only one level
down. Spotty's search node is addressed positionally; if a future Spotty
reorders its menu the section degrades to empty rather than breaking.

### Favouriting dynamic menus

A favourite stores a URL, not a coderef. Program rows carry `favorites_url`
(the program's feed) plus `parser => Plugins::RadioHelsinki::Parser`, so a
reopened favourite refetches and rebuilds — it stays current. The Kesken and
Viimeksi kuunnellut lists favourite as pseudo-URLs (`radiohelsinki://kesken`,
`://recent`) that the protocol handler's `explodePlaylist` turns back into
live menus. Skins only offer "Add to favourites" on rows they consider
playable, hence the `playlist =>` flag on program rows (the Podcast plugin's
trick); the favourites parser returns `nocache => 1` because its menu holds
coderefs that must never be Storable-frozen into DbCache.

### Seeking and caching

On-demand episodes get their duration from the broadcast window (`begin` →
`end`, accurate to ~1 %), which is what makes them seekable; podcasts and
clips report `begin == end` and LMS derives the duration from the stream.

The station's API is slow and 504s under load, so every response is cached as
*derived menu items* (a 1.2 MB payload parses once), with a 7-day stale copy
as fallback — a stale menu beats an error menu. Menu caches use
`CACHE_VER`-versioned keys (bump on shape changes); the metadata/position
namespace is deliberately unversioned so it survives updates. Endpoints:
`/wp-json/api/v2/programs` (directory; v1 504s), `v1/program_content/<ID>`,
`v1/ondemand`, `v1/podcasts`, `v1/popularpodcasts`, and
`/wp-content/djonline.js` for the live feed.

## Development

`build.sh` packages the zip and writes `repo.xml` (the `<sha>` is the zip's
SHA1, verified by LMS before extracting):

```bash
./build.sh                        # repo URL defaults to this machine, port 8000
python3 -m http.server 8000       # point Additional Repositories at it
```

The fastest loop skips repositories: copy the plugin files into the manual
plugin directory over SSH and `systemctl restart` the server. The repository
path makes the server restart itself mid-install, and a failed restart leaves
the plugin half-installed; a file copy has no such failure mode.

Release: the zip ships as a GitHub release asset (asset `download_count`
approximates installs — raw-file fetches are never counted):

```bash
RH_BASE_URL="https://github.com/patapovich/rh-ondemand-lyrion/releases/download/v<version>" ./build.sh
gh release create v<version> RadioHelsinki-<version>.zip --title "<version>" --notes "..."
git commit -am "release <version>" && git push   # repo.xml rides along
```

Debugging: enable the `plugin.radiohelsinki` log category under **Settings →
Advanced → Logging**. The whole menu tree is drivable over JSON-RPC (needs a
real player id; results come in `loop_loop`):

```bash
curl -s -X POST -H 'Content-Type: application/json' \
  -d '{"id":1,"method":"slim.request","params":["<playerid>",["radiohelsinki","items",0,20]]}' \
  http://<server>:9000/jsonrpc.js | jq '.result'
```

## Troubleshooting

- **Menus empty right after a restart** — the server is still settling; retry.
- **"Radio Helsinkiin ei saatu yhteyttä"** — the station's API is down and no
  stale copy exists yet. Try again later.
- **A track shows only a date** — its program was never browsed on this
  server, so the token map is empty for it. Open the program once under
  *Ohjelmat*; it resolves everywhere from then on.
- **Live stream shows the programme but no songs** — the station's DJ log is
  the only source; when nothing is logged (talk shows, unlogged sets),
  there is nothing to show and the programme is the honest answer.
- **Favourites from 1.0.x** play fine but don't get resume — re-favourite the
  episode to upgrade it to the wrapped URL.

## Caveats

The station API is undocumented and unversioned. All mapping lives in
`API.pm` and `Live.pm`; a breakage should be a one- or two-file fix.

## License

GPL-2.0 — the same license as Lyrion Music Server. See [LICENSE](LICENSE).
