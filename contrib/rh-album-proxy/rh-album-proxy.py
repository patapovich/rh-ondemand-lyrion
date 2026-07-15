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
ITUNES = "https://itunes.apple.com/search"
FEED_TIMEOUT = 6
ITUNES_TIMEOUT = 4
ENRICH_ROWS = 3          # only the newest rows matter for now-playing
CACHE_MAX = 500          # (artist, title) -> album; in-memory is plenty

UA = "Mozilla/5.0 (X11; Linux x86_64; rv:128.0) Gecko/20100101 Firefox/128.0"

_cache = {}              # key -> (album_or_None, stored_at)
NEG_TTL = 6 * 3600       # retry failed lookups eventually

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

        body = raw
        try:
            doc = json.loads(raw)
            for row in (doc.get("last_playing") or [])[:ENRICH_ROWS]:
                if (row.get("album") or "").strip():
                    continue
                artist = (row.get("artist") or "").strip()
                title = (row.get("song") or "").strip()
                if not artist or not title:
                    continue
                album = lookup_album(artist, title)
                if album:
                    row["album"] = album
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
