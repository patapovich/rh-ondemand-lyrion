# Changelog

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
