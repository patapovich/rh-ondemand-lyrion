# Changelog

## 1.3.0 — 2026-07-15

- "Nyt soi" in the live stream's song info: shows the programme on air right
  now (name, hosts, airtime, episode text) with a "Siirry ohjelmaan" link
  into its archive menu — the live stream, the programme and its episodes
  are now linked from now-playing, matching what episodes already had. The
  entry's label carries the programme name once fetched.
- "Tulossa" rows underneath: the channel's next three programmes with their
  times (weekday-prefixed past midnight). Each opens to the slot's own notes
  (when the station wrote any), the hosts, and the programme's menu.

## 1.2.0 — 2026-07-15

- "Siirry ohjelmaan" in the now-playing song info: opens the playing episode's
  programme menu (description, play newest, episodes, clips), linking playback
  back to browsing. Episode metadata now carries the programme id; episodes
  played before this version gain the link once they are next browsed.

## 1.1.3 — 2026-07-15

- Live-stream now-playing fixed: the metadata matcher no longer claims
  stream.radiohelsinki.fi. LMS hands a URL to the first matching provider
  (plugins register alphabetically), so our empty answer for the live stream
  was silently shadowing RadioNowPlaying's rich song/programme/artwork data,
  leaving only bare ICY titles.

## 1.1.2 — 2026-07-14

- The resume/play rows inside an episode's submenu no longer repeat the
  episode name as their subtitle — the submenu header already says it, so it
  used to appear three times.
- Episode rows inside a programme's own menu now lead with the programme name
  ("Rakkaudesta – su 12.07.2026"), so the submenu header names the programme
  too, matching the cross-programme lists.
- The broadcast tracklist moved into its own "Kappalelista (N)" submenu with a
  hint of what it does (find a track in your library or on Spotify) — it used
  to sit inline under the play rows as one long, confusing list.

## 1.1.1 — 2026-07-14

- Tapping a half-listened episode in Kesken, Viimeksi kuunnellut or the flat
  lists on a touch skin now opens the resume submenu as intended; it used to
  start playback from the beginning, making resume unreachable there. The
  play button and favouriting still work on the row itself.

## 1.1.0 — 2026-07-14

- Resume from last position. Stopping mid-episode saves the spot (persistent,
  30 days); the episode's menu then opens with a "Jatka kohdasta 12:34" row
  above "Toista alusta". Episodes in the flat lists (Uusimmat/Suositut) gain
  the same choice via a small submenu that appears only when a saved position
  exists. Positions clear automatically when an episode plays to the end.
- New "Kesken" top-level menu: every half-listened episode, newest-stopped
  first, with progress on the second line ("20:09 / 2:00:00") and the same
  resume/from-start submenu. Entries leave the list when an episode plays to
  the end, is stopped inside its first 15 seconds, or its 30-day position
  expires. Capped at the 50 most recent; survives server restarts.
- New "Viimeksi kuunnellut" top-level menu: the last 50 episodes that have
  started playing, newest first — half-listened ones open the resume submenu,
  everything else replays with one tap. Both lists show the episode info,
  just like the programme menus.
- "Jakson tiedot": the episode description appears in the now-playing song
  info view for any Radio Helsinki track.
- Both lists can be added to LMS favourites. The favourite stores a pseudo-URL
  (radiohelsinki://kesken, ://recent); opening it serves the live list,
  complete with resume submenus. Playing such a favourite queues the episodes.
- Station-logo artwork for programmes the station publishes no image for
  (Moderni aika and five others). Ships a 600×600 logo used as the cover
  fallback everywhere: programme rows, episode lists, now-playing.
- Technically: episode URLs are now wrapped as radiohelsinki://… so a new
  protocol handler (a port of the bundled Podcast plugin's) sees the play
  lifecycle; the natural-end case additionally uses the decoder-done hook
  (onPlayout), which the Podcast plugin lacks — its positions go stale when an
  episode finishes on its own.
- Favourites saved from 1.0.x (plain https URLs) keep playing with full
  metadata but do not get resume; re-favourite the episode to upgrade it.
- Requires LMS 8.2+ (was 8.0).

## 1.0.1 — 2026-07-14

- Artwork for clips inside a programme's menu. The clip list mixes in episodes
  belonging to other programmes (e.g. Viikon levy inside the aamut page) and
  one-off guest pages the programme directory has never heard of. Foreign clips
  now resolve their artwork through the full programme directory, and clips from
  unknown guest pages inherit the hosting programme's artwork instead of none.
- Now-playing metadata for such clips is no longer cached without a cover, and a
  cover already cached is never overwritten with an empty one.

## 1.0.0 — 2026-07-14

Initial release.

- Browse and play Radio Helsinki's full on-demand archive, podcasts and clips — the
  current CDN and the older storage generations back to ~2017 alike.
- Uniform menus everywhere: every programme opens with its full description, a
  ▶ play-the-newest shortcut and its content sections; every episode, podcast and
  clip opens with its full description and a ▶ play row.
- Per-broadcast tracklists attached to their episode. Selecting a track searches
  your local library (matches are playable) and, with Spotty installed, Spotify.
  Deliberately no jump-to-song: the station's tracklist timestamps record data
  entry, not airtime.
- Programmes and episodes can be favourited; a favourited programme reopens live
  and stays current as new episodes appear.
- Correct artwork, title, programme name and seeking on everything played,
  persistent across server restarts and plugin updates.
- Plain-MP3 playback through LMS's built-in HTTP handler — no protocol handler.
- Async fetching with aggressive caching and stale-copy fallback; the station's
  API is slow and 504s under load.
- Finnish and English strings.
