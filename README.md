# Radio Helsinki for Lyrion Music Server

Browse and play [Radio Helsinki](https://www.radiohelsinki.fi/ohjelmat/) on-demand
programs, podcasts and clips from any Squeezebox client.

```
Radio Helsinki
├─ Uusimmat jaksot        10 newest full-show recordings
├─ Uusimmat podcastit     100 newest podcast episodes
├─ Suositut podcastit
├─ Ohjelmat               46 current programs
│    └─ <program>
│         ├─ Toista uusin jakso
│         ├─ Jaksot       full show recordings (639 for Radio Helsingin aamut)
│         │    ├─ ma 13.07.2026            episode with no tracklist — plays on tap
│         │    └─ to 25.06.2026            episode WITH a tracklist — opens:
│         │         ├─ Toista jakso        plays the episode
│         │         └─ VEGA SUZANNE – Small Blue Thing
│         │              ├─ Kirjastossa    matches in your own library, playable
│         │              └─ Spotifyssa     matches on Spotify, playable via Spotty
│         ├─ Podcastit
│         └─ Klipit       short segments cut from the shows
├─ Arkisto                155 programs no longer running
└─ Haku                   search program titles
```

Episodes play with their program's artwork, title and description, and seek correctly
(including four hours into a four-hour show).

Both **episodes and whole programs can be favourited** — from the item's context menu
("…" in Material, long-press on hardware players). A favourited program reopens live,
so new episodes keep appearing in it.

## Install

In **Settings → Plugins → Additional Repositories**, add:

```
https://raw.githubusercontent.com/patapovich/rh-ondemand-lyrion/main/repo.xml
```

Apply, then install *Radio Helsinki* from the list. Lyrion restarts itself.

**Manual install** (no repository): download `RadioHelsinki-<version>.zip` from the
[Releases page](https://github.com/patapovich/rh-ondemand-lyrion/releases), unzip it
into your server's plugin directory so that `install.xml` sits at
`.../Plugins/RadioHelsinki/install.xml`, and restart the server.

| Install | Plugin directory |
|---|---|
| Debian/Ubuntu package | `/usr/share/squeezeboxserver/Plugins/` |
| Repository install | `<cachedir>/InstalledPlugins/Plugins/` (managed by Lyrion) |

Requires Lyrion Music Server 8.0 or newer. The plugin appears under **Radio**.

## How it works

Radio Helsinki runs WordPress with a public, unauthenticated REST API, and the
audio is plain MP3 on hosting that honours range requests. That makes the plugin
unusually simple: **there is no protocol handler**, because LMS's built-in HTTP
handler already streams and seeks these files natively. A protocol handler would
only be needed for HLS, DRM, or expiring token URLs.

The archive spans several storage generations — the current Cloudflare CDN, an
S3 bucket for ~2017–2019, and a couple of older object-storage hosts. The metadata
provider matches all of them (see `Metadata.pm`); anything that touches audio URLs
must not assume `cdn.radiohelsinki.fi`.

| File | Job |
|---|---|
| `Plugin.pm` | The menu tree. A `Slim::Plugin::OPMLBased` subclass, nothing more. |
| `API.pm` | Every call to the station's API, every JSON → menu-item mapping, all caching. |
| `Metadata.pm` | Attaches title/artist/artwork to the plain MP3 URLs at play time. |
| `Search.pm` | What a playlist track does when you select it. |
| `Parser.pm` | Rebuilds a favourited program's menu when the favourite is reopened. |

### Endpoints used

| Endpoint | Returns |
|---|---|
| `/wp-json/api/v2/programs` | The program directory (203 entries, ~386 KB) |
| `/wp-json/api/v1/program_content/<ID>` | One program's whole archive (~1.2 MB) |
| `/wp-json/api/v1/ondemand` | 10 newest full-show recordings |
| `/wp-json/api/v1/podcasts` | 100 newest podcast episodes |
| `/wp-json/api/v1/popularpodcasts` | Most-played podcasts |

`/wp-json/api/v1/programs` exists but returns HTTP 504 — `v2` is the working one.

Episodes reference their program only by numeric id and carry no artwork of their
own, so the program directory is fetched first and used to decorate every episode.
Two programs are flagged `only_membership` and are skipped; their audio is paywalled.

### Metadata

`Slim::Player::Protocols::HTTP::getMetadataFor` asks `Slim::Formats::RemoteMetadata`
for a provider matching the URL being played, so `Metadata.pm` registers one against
`cdn.radiohelsinki.fi`. When `API.pm` builds a menu it writes each episode's metadata
keyed by its audio URL; the provider reads it back at play time.

Two design points here were earned the hard way:

- **The metadata lives in a dedicated cache namespace with periodic purging disabled**
  (`Slim::Utils::Cache->new('radiohelsinki', 1, 1)`), never in LMS's shared default
  cache. The default cache purges itself to stay small, and metadata is only written
  when `program_content` is actually parsed — a rare event once menus are cached. Stored
  in the default cache, a track played hours after it was browsed would silently lose
  its title, program name and cover mid-session.
- **A URL-token → program map provides the fallback.** On-demand filenames are
  `<yyyymmdd>_<token>_….mp3`, where the token identifies the program — the only program
  handle recoverable from the URL alone, which is all the provider gets. One map entry
  per program (written whenever any of its episodes is parsed) lets now-playing resolve
  the real program name and artwork even for a track whose exact episode was never
  browsed in this session — e.g. played straight from a favourite, or resumed after a
  restart.

### Favouriting a program

A favourite can only store a plain URL, not the coderef our program rows browse with.
So a program row also carries `favorites_url` (its `program_content` endpoint) plus
`parser => Plugins::RadioHelsinki::Parser`; reopening the favourite refetches the feed
and the parser rebuilds the same menu, so the favourite stays current as new episodes
appear. This mirrors how the bundled Podcast plugin favourites a show.

Two LMS quirks worth recording:

- Skins only offer "Add to favourites" for items they consider *playable* — the
  favourites handle (`presetParams`) is attached to playable rows only. So the program
  row is flagged playable via `playlist => <program feed>` (the Podcast plugin's trick).
  A plain tap still browses; only the context menu gains Play/favourite actions.
- The parser returns `nocache => 1`. Its menu contains coderef items (the playlist
  track submenus), and without that flag `Slim::Formats::XML` would try to
  Storable-freeze the parsed feed into DbCache and die with `Can't store CODE items`.

### Playlists

Some programs publish a tracklist per broadcast. `program_content.playlists` is a dict
keyed by broadcast timestamp, holding `{ song, artist, created_at, spotify_id, sortable_rank }`.

**`created_at` is not airtime.** It is when the row was written to the database, and it
is worth being explicit about that, because it looks exactly like the field you would
use to seek to the moment a song played. It isn't: Kuusikielinen taivas's tracks were
entered *ten days before* the broadcast, and Radio Helsingin aamut's were bulk-pasted in
a single second *after* it. There is no way to derive an offset into the recording from
this data, which is why there is no jump-to-track. `spotify_id` is a dead end too — null
on all but 2 of ~900 tracks. Both fields are ignored deliberately.

A tracklist belongs to one broadcast, so it lives on that broadcast's episode rather than
in a separate menu. But an LMS row cannot be both play-on-tap and browse-into: XMLBrowser
treats any `type => 'audio'` item as a playable track and, on select, plays it or shows its
track-info card — a custom `items` list attached to it is never reached (verified in
`Slim::Control::XMLBrowser`). So an episode that *has* a tracklist becomes a browsable menu
instead — first entry **Toista jakso** plays the show, the rest is the tracklist. Episodes
with no tracklist stay one-tap-play, which is all but a handful. `Plugin.pm::_withPlaylists`
does this, matching each episode to its playlist by broadcast timestamp; a few playlists
belong to broadcasts that were never recorded and have no episode to attach to.

Selecting a track (`Search.pm`) answers the question actually worth asking about a song
you liked on the radio — do I own this, and if not, can I play it anyway?

- **Kirjastossa** — searches your library. LMS can only free-text search titles, so it
  casts a wide net on the song and filters by artist in Perl, loosely and in both
  directions (the station shouts `ALICE COLTRANE`; your tags say `Alice Coltrane`).
- **Spotifyssa** — only when Spotty is enabled. A Spotty search row carries no URL, only
  an internal item id; descending into it yields one child whose name *is* the playable
  URI (`spotify://track:…`). So each hit costs one extra round trip, which is why only
  the top few are resolved. They are fired in parallel, not in series.

Both go through `Slim::Control::Request::executeRequest` with a callback. That matters:
the library query answers synchronously and Spotty does not, and the callback fires on
completion either way.

Spotty's search node is addressed positionally (`item_id:1.0`) because it exposes no
stable named entry point. If a future Spotty reorders its menu, the section comes back
empty rather than breaking.

### Seeking

`canSeek()` returns false unless both bitrate and duration are known, so on-demand
items carry a `duration` derived from the broadcast window in the API (`begin` →
`end`). Spot-checked against the real files, that window implies a bitrate of
125.6–126.9 kbps against 128 kbps CBR MP3s, so it is accurate to within a percent.

Podcasts and clips report `begin == end`, so they get no duration and LMS derives one
from the stream instead.

### Caching

The site is slow and 504s under load, so every response is cached — as *derived menu
items*, not raw JSON, so a 1.2 MB payload is parsed once rather than on every menu open.

| Data | TTL | Cache |
|---|---|---|
| Program directory | 24 h | default (versioned keys) |
| Program content | 1 h | default (versioned keys) |
| Newest episodes | 10 min | default (versioned keys) |
| Newest podcasts | 30 min | default (versioned keys) |
| Popular podcasts | 1 h | default (versioned keys) |
| Per-episode metadata, per-program artwork, token map | 30 d | dedicated `radiohelsinki` namespace, no periodic purge |

Menu caches use keys versioned by `CACHE_VER` in `API.pm` — bump it when the shape of a
cached item changes, so a shipped fix is not masked for a day by yesterday's cache. The
metadata namespace is deliberately *not* versioned: it must outlive plugin updates so a
favourited or playing track keeps its metadata across releases.

Every fetch is async (`Slim::Networking::SimpleAsyncHTTP`), and a failed one falls
back to a stale copy kept for 7 days. A stale menu beats an error menu.

## Development

`build.sh` packages the plugin and writes the `repo.xml` that Lyrion installs from —
the zip needs `install.xml` at its top level and the `<sha>` must be the zip's SHA1,
which Lyrion verifies before extracting.

```bash
./build.sh                 # repo URL defaults to this machine's LAN IP, port 8000
python3 -m http.server 8000
```

Point Lyrion's *Additional Repositories* at `http://<this-machine>:8000/repo.xml`. To
iterate: bump `<version>` in `install.xml`, re-run `build.sh`, reload the plugins
settings page, and Lyrion offers the update.

The fastest dev loop of all skips the repository entirely: copy the plugin files
straight into the manual plugin directory (see Install above) over SSH and restart the
service. The repository path makes the server restart itself mid-install, and if that
restart fails for unrelated reasons (a scan holding the SQLite lock, `Restart=no` on
the systemd unit) the plugin is left half-installed. A file copy plus an explicit
`systemctl restart` has neither failure mode.

Releasing: the zip is distributed as a GitHub release asset, not from the git tree —
GitHub counts release-asset downloads (raw-file fetches are never counted), so this is
also the install counter. LMS re-checks `repo.xml` routinely but only fetches the zip
on an install or update, so the asset's `download_count` approximates installs+updates.

```bash
RH_BASE_URL="https://github.com/patapovich/rh-ondemand-lyrion/releases/download/v<version>" ./build.sh
gh release create v<version> RadioHelsinki-<version>.zip --title "<version>" --notes "..."
git commit -am "release <version>" && git push     # repo.xml (with the new sha) rides along
```

Watch the counter:

```bash
gh api repos/patapovich/rh-ondemand-lyrion/releases --jq '.[].assets[] | "\(.name): \(.download_count)"'
```

### Debugging

Enable the `plugin.radiohelsinki` log category under **Settings → Advanced → Logging**;
the server log is readable from the same page.

The whole menu tree is drivable over JSON-RPC without playing anything, which is the
fastest way to check a change. Note the command needs a player id — with an empty one
it returns nothing — and the results come back in `loop_loop`, not `item_loop`:

```bash
curl -s -X POST -H 'Content-Type: application/json' \
  -d '{"id":1,"method":"slim.request","params":["<playerid>",["radiohelsinki","items",0,20]]}' \
  http://lyrion.localdomain:9000/jsonrpc.js | jq '.result'
```

Descend by passing `"item_id:<id>"` as an extra parameter — `item_id:3` is Ohjelmat,
`item_id:3.36.0` is the episode list of the 37th program, and so on.

## Troubleshooting

- **Menus answer nothing right after a restart** — the server is still settling;
  retry after a few seconds.
- **"Radio Helsinkiin ei saatu yhteyttä"** — the station's API is flaky and 504s under
  load. The plugin serves a stale copy for up to 7 days when it has one; this error
  means it has nothing at all yet. Try again.
- **A track shows only a date, no program name or cover** — its program hasn't been
  browsed since the plugin was installed, so the token map has no entry for it yet.
  Open the program once under *Ohjelmat*; from then on it resolves everywhere,
  including favourites and across restarts.
- **The Spotify section is missing on playlist tracks** — Spotty isn't installed or
  enabled, or a Spotty update moved its search menu (the plugin addresses it
  positionally, and degrades to an empty section rather than an error).

## Caveats

The API is undocumented and unversioned and can change without notice. All of the
mapping lives in `API.pm`, so a breakage should be a one-file fix.

## License

GPL-2.0 — the same license as Lyrion Music Server. See [LICENSE](LICENSE).
