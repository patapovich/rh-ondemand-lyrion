#!/usr/bin/env python3
"""Radio Helsinki djonline.js enrichment proxy for RadioNowPlaying.

The station's now-playing feed has an `album` field but never fills it. This
proxy sits between RadioNowPlaying and the feed: it fetches the real
djonline.js (with a browser User-Agent, which also avoids Cloudflare's bot
scoring), looks up the album name for the most recent tracks via the free
iTunes Search API, fills it into the JSON and returns the document otherwise
unchanged. Any failure — feed down, iTunes down, weird JSON — degrades to
passing the original content (or the error) through, never blocking the feed.

Listens on 127.0.0.1 only; RadioNowPlaying's stationdata songurl points here.
"""

import json
import re
import time
import urllib.parse
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

LISTEN = ("127.0.0.1", 9099)
FEED = "https://www.radiohelsinki.fi/wp-content/djonline.js"
PROGRAMS = "https://www.radiohelsinki.fi/wp-json/api/v2/programs"
ITUNES = "https://itunes.apple.com/search"
FEED_TIMEOUT = 6
ITUNES_TIMEOUT = 4
PROGRAMS_TIMEOUT = 15
PROGRAMS_TTL = 24 * 3600
ENRICH_ROWS = 3          # only the newest rows matter for now-playing
CACHE_MAX = 500          # (artist, title) -> album; in-memory is plenty

UA = "Mozilla/5.0 (X11; Linux x86_64; rv:128.0) Gecko/20100101 Firefox/128.0"

_cache = {}              # key -> (album_or_None, stored_at)
NEG_TTL = 6 * 3600       # retry failed lookups eventually

_prog_images = {}        # programme id (str) -> image URL
_prog_fetched = 0.0

# "Song (feat. X)" / "[Radio Version]" etc. hurt search precision.
_noise = re.compile(r"\s*[\(\[][^)\]]*(feat\.|version|edit|remaster|mix)[^)\]]*[\)\]]\s*", re.I)


def lookup_album(artist, title):
    key = (artist.lower(), title.lower())
    hit = _cache.get(key)
    if hit and (hit[0] is not None or time.time() - hit[1] < NEG_TTL):
        return hit[0]

    album = None
    try:
        term = urllib.parse.quote_plus(f"{artist} {_noise.sub(' ', title).strip()}")
        url = f"{ITUNES}?term={term}&entity=song&limit=1&country=FI"
        req = urllib.request.Request(url, headers={"User-Agent": UA})
        with urllib.request.urlopen(req, timeout=ITUNES_TIMEOUT) as r:
            results = json.load(r).get("results") or []
        if results:
            album = results[0].get("collectionName") or None
    except Exception:
        album = None

    if len(_cache) >= CACHE_MAX:
        _cache.pop(next(iter(_cache)))
    _cache[key] = (album, time.time())
    return album


def _safe_url(url):
    """Percent-encode non-ASCII bytes; a dozen station image paths carry
    combining diacritics that trip various consumers downstream."""
    return urllib.parse.quote(url.encode(), safe=":/?&=%~._-")


def prog_image(prog_id):
    """Programme id -> image URL, from the station's programs API (24 h cache).
    Failures keep whatever map we had; an empty map just means no injection."""
    global _prog_fetched
    if prog_id is None:
        return None
    if time.time() - _prog_fetched > PROGRAMS_TTL:
        _prog_fetched = time.time()   # even on failure, don't hammer the site
        try:
            req = urllib.request.Request(PROGRAMS, headers={"User-Agent": UA})
            with urllib.request.urlopen(req, timeout=PROGRAMS_TIMEOUT) as r:
                progs = json.load(r)
            _prog_images.clear()
            for p in progs:
                img = (p.get("img") or "").strip()
                if img:
                    _prog_images[str(p.get("ID"))] = _safe_url(img)
        except Exception:
            pass
    return _prog_images.get(str(prog_id))


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        qs = urllib.parse.urlparse(self.path).query
        feed_url = FEED + ("?" + qs if qs else "")

        try:
            req = urllib.request.Request(feed_url, headers={
                "User-Agent": UA,
                "Accept": "application/json, text/javascript, */*; q=0.01",
                "Referer": "https://www.radiohelsinki.fi/",
            })
            with urllib.request.urlopen(req, timeout=FEED_TIMEOUT) as r:
                raw = r.read()
        except urllib.error.HTTPError as e:
            self.send_response(e.code)
            self.end_headers()
            return
        except Exception:
            self.send_response(502)
            self.end_headers()
            return

        # The feed is not entirely well-formed — e.g. last_playing sometimes
        # contains a literal false as a placeholder row — so every enrichment
        # guards itself and a failure in one must not spoil the others.
        body = raw
        try:
            doc = json.loads(raw)

            # Programme artwork: the feed has no image field, but the station's
            # programs API does — inject it so RadioNowPlaying's progicon
            # mapping can show the programme cover instead of the station logo.
            try:
                progs = doc.get("programs") or {}
                slots = [progs.get("current")] + list(progs.get("next") or [])
                for slot in slots:
                    if isinstance(slot, dict) and not slot.get("program_image"):
                        img = prog_image(slot.get("prog"))
                        if img:
                            slot["program_image"] = img
            except Exception:
                pass

            try:
                rows = doc.get("last_playing") or []
                rows = [r for r in rows if isinstance(r, dict)][:ENRICH_ROWS]
                for row in rows:
                    if (row.get("album") or "").strip():
                        continue
                    artist = (row.get("artist") or "").strip()
                    title = (row.get("song") or "").strip()
                    if not artist or not title:
                        continue
                    album = lookup_album(artist, title)
                    if album:
                        row["album"] = album
            except Exception:
                pass

            body = json.dumps(doc, ensure_ascii=False).encode()
        except Exception:
            body = raw   # pass the original through untouched

        self.send_response(200)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args):
        pass


if __name__ == "__main__":
    ThreadingHTTPServer(LISTEN, Handler).serve_forever()
