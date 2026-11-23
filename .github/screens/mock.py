import time
# A stand-in for the PC (test data only), so GitHub can run the app on an emulator and take screenshots.
import json, os, re, http.server, socketserver, urllib.parse

HERE = os.path.dirname(os.path.abspath(__file__))
IMG = os.path.join(HERE, "img")

def img(i, kind="Primary"): return f"/api/play/img/{i}/{kind}"

def it(id, type, name, **k):
    d = {"id": id, "type": type, "name": name, "label": k.pop("label", name), "length": "", "played": False, "resume": "",
         "resume_ticks": 0, "has_ad": True, "pct": 0, "overview": "", "year": "", "rating": "", "score": "", "genres": ""}
    d.update(k)
    if d["resume"] and not d["resume_ticks"]: d["resume_ticks"] = 5_400_000_000      # so Resume shows (the apps check both)
    return d

LOREM = ("Eleven teams race around the world, solving clues and doing tasks in every city they reach. The last team to "
         "arrive at each stop may be sent home, and the first to the finish line wins the prize.")
SERIES = [
    it("s_chase", "Series", "The Great Chase", poster=img("s_chase"), thumb=img("s_chase", "Backdrop"), backdrop=img("s_chase", "Backdrop"),
       year=2001, years="2001 - Present", unplayed=406, score=6.9, rating="TV-PG", genres="Reality", overview=LOREM),
    it("s_harbor", "Series", "Harbor Station", poster=img("s_harbor"), year=2012, years="2012 - Present", unplayed=299),
    it("s_town", "Series", "Quiet Town", poster=img("s_town"), year=1997, years="1997 - Present", unplayed=334),
]
MOVIES = [
    it("m_magic", "Movie", "Moonlit Magic 2", label="Moonlit Magic 2 (2026)", poster=img("m_magic"), thumb=img("m_magic", "Backdrop"),
       backdrop=img("m_magic", "Backdrop"), year=2026, rt="2h 10m", length="2 hours 10 minutes", rating="PG-13", score=7.1, genres="Romance",
       overview="The Owens-like sisters must face an old curse that threatens to pull their family apart once and for all."),
    it("m_west", "Movie", "Dust Riders", poster=img("m_west"), year=1966, played=True),
    it("m_run", "Movie", "The Runner", poster=img("m_run"), year=1987, pct=22, resume="25 minutes"),
    it("m_glad", "Movie", "Arena", poster=img("m_glad"), year=2000, has_ad=False),
]
EPS = [
    it("e1", "Episode", "The Race Begins", label="The Great Chase, season 1 episode 1: The Race Begins", se=1, ep=1, series_name="The Great Chase",
       series_id="s_chase", season_id="se1", thumb=img("e1"), poster=img("s_chase"), aired="Sep 5, 2001", rt="44m", length="44 minutes",
       overview="The teams begin in New York. They need to travel to Johannesburg, South Africa. Cooperation problems surface early on with a few of the couples."),
    it("e2", "Episode", "Divide and Conquer", label="The Great Chase, season 1 episode 2: Divide and Conquer", se=1, ep=2, series_name="The Great Chase",
       series_id="s_chase", season_id="se1", thumb=img("e2"), aired="Sep 12, 2001", rt="44m", pct=35, resume="15 minutes",
       overview="The teams start out in a small village, where they must find the museum without any signs to show the way."),
    it("e3", "Episode", "The Long Night", label="The Great Chase, season 1 episode 3: The Long Night", se=1, ep=3, series_name="The Great Chase",
       series_id="s_chase", season_id="se1", thumb=img("e3"), aired="Sep 19, 2001", rt="43m", has_ad=False,
       overview="An overnight train ride shakes up the order, and one team's map goes missing."),
]
NINE = it("e_nine", "Episode", "The Venue", label="Precinct 99, season 5 episode 6: The Venue", se=5, ep=6, series_name="Precinct 99",
          series_id="s_nine", thumb=img("e_nine"), pct=30, resume="9 minutes")
ENC = it("m_enc", "Movie", "Casa Verde", thumb=img("m_enc", "Backdrop"), poster=img("m_enc"), year=2021, pct=60, resume="1 hour")
SEASONS = [it(f"se{n}", "Season", f"Season {n}", poster=img(f"se{n}"), unplayed=u, series_name="The Great Chase", series_id="s_chase")
           for n, u in [(1, 13), (2, 6), (3, 6)]]
PEOPLE = [{"id": "p1", "name": "Phil Host", "role": "Host", "image": img("p1")}, {"id": "p2", "name": "Rachel Runner", "role": "Rachel", "image": img("p2")},
          {"id": "p3", "name": "Andrew Simpson", "role": "Andrew Simpson", "image": ""}, {"id": "p4", "name": "Dana Doe", "role": "Dana", "image": img("p4")}]
BOOKS = [{"type": "Book", "id": "b1", "label": "The Bank Job", "author": "Ben Writer", "narrator": "Sam Voice", "length": "9 hours 12 minutes",
          "chapters": 3, "resume": "2 hours 1 minute", "pct": 22, "poster": "/api/play/books/cover/b1"},
         {"type": "Book", "id": "b2", "label": "Night Train", "author": "Ann Author", "length": "7 hours", "chapters": 3, "poster": "/api/play/books/cover/b2"}]

def info(i):
    if i == "s_chase":
        d = dict(SERIES[0]); d.update(logo="/api/play/img/logo_the/Logo", studio="CBS", season_count=39, seasons=SEASONS, people=PEOPLE,
                                      next_up=EPS[1], similar=SERIES[1:] + MOVIES[:2], favorite=False, series_id="s_chase")
        return d
    if i == "m_magic":
        d = dict(MOVIES[0]); d.update(logo="/api/play/img/logo_moonlit/Logo", video_info="1080p H264", audio_info="AAC 5.1 (Default)",
                                       trailer="https://example.com/trailer", tagline="Everything you've wished for.", directors="Susan Director",
                                       people=PEOPLE, similar=MOVIES[1:], chapters=[{"start": 0, "name": "Opening", "image": "/api/play/chapimg/m/0"},
                                       {"start": 600, "name": "The Return", "image": "/api/play/chapimg/m/1"}, {"start": 1800, "name": "The Curse", "image": "/api/play/chapimg/m/2"}])
        return d
    if i == "se1":
        d = dict(SEASONS[0]); d.update(logo="/api/play/img/logo_the/Logo", backdrop=img("s_chase", "Backdrop"), series_name="The Great Chase", overview=LOREM)
        return d
    for e in EPS + MOVIES + SERIES + [NINE, ENC]:
        if e["id"] == i:
            d = dict(e); d.update(logo="/api/play/img/logo_the/Logo" if e.get("series_id") == "s_chase" else "", chapters=[], people=PEOPLE[:2],
                                  video_info="1080p H264", audio_info="AAC Stereo (Default)", directors="Jean Director")
            return d
    return {"error": "Not found"}

DL = {}
MOCK = {"invite": False}
SIGHT = {"sight": "full", "sight_chosen": False,   # the TV asks first
         "sight_opts": {"size": "large", "screen": "dark", "video": True, "focus": True, "still": True, "posters": True}}

def route(path, q):
    if path == "/api/play/books/book":
        return {"id": "b1", "title": "The Bank Job", "author": "Ben Writer", "narrator": "Sam Voice", "duration": 120.0, "position": 50.0,
                "finished": False, "cover": "/api/play/books/cover/b1", "series": "The Ernest Mysteries", "year": "2025", "genres": "Mystery, Crime",
                "description": "A heist goes wrong in the most polite way possible, and one man in the queue is sure he knows who did it. " * 3,
                "chapters": [{"start": 0, "end": 40, "title": "The Queue"}, {"start": 40, "end": 80, "title": "The Vault"}, {"start": 80, "end": 120, "title": "The Parrot"}],
                "tracks": [{"start": 0, "duration": 60, "url": "/media/book.mp3"}, {"start": 60, "duration": 60, "url": "/media/book.mp3"}]}
    if path == "/api/play/download/prepare" or path.startswith("/api/play/download/job/"):
        n = DL.setdefault("n", 0); DL["n"] = n + 1
        if n < 12:
            return {"id": "dl1", "state": "working", "progress": min(99, n * 8), "method": "gpu", "eta": max(0, 90 - n * 8),
                    "speed_x": 4.2, "made_bytes": n * 31_000_000, "est_bytes": 420_000_000, "title": "Moonlit Magic 2 (2026)", "kind": "video"}
        return {"id": "dl1", "state": "ready", "progress": 100, "url": "/media/test.mp4", "bytes": 826788, "runtime_ticks": 78000000000}
    if path in ("/api/play/download/done", "/api/play/download/cancel"): return {"message": "OK"}
    if path == "/api/play/login": return {"token": "tok", "message": "Signed in as Yoh."}
    if path == "/api/play/me": return dict({"signed_in": True, "name": "Yoh", "role": "watch", "server_id": "mock", "home_urls": []}, **SIGHT)
    if path == "/api/play/sight":
        for k, v in q.items():
            if k == "sight": SIGHT["sight"] = v; SIGHT["sight_chosen"] = True
            elif k in ("size", "screen"): SIGHT["sight_opts"][k] = v
            else: SIGHT["sight_opts"][k] = v == "1"
        return dict(SIGHT)
    if path == "/api/play/devices": return {"devices": [], "other": []}
    if path == "/mock/invite": MOCK["invite"] = True; return {"ok": True}
    if path == "/api/play/together/list":
        return {"rooms": [{"id": "r9", "title": "Moonlit Magic 2 (2026)", "by": "Ann", "kind": "video", "item": "m_magic", "names": ["Ann", "Bob"],
                           "invited": True, "invited_by": "Ann", "invited_ago": 4}] if MOCK["invite"] else []}
    if path == "/api/play/people": return {"people": [{"name": "Ann", "online": True, "notify": True}, {"name": "Bob", "online": False, "notify": False}]}
    if path in ("/api/play/together/start", "/api/play/together/join", "/api/play/together/beat", "/api/play/together/control"):
        if path == "/api/play/together/start": MOCK["room_t"] = time.time()
        waiting = time.time() - MOCK.get("room_t", 0) < 25
        return {"id": "r1", "kind": "video", "item": q.get("item") or "m_magic", "title": "Moonlit Magic 2 (2026)", "iseq": 1, "seq": 1, "run": not waiting,
                "want": True, "waiting": waiting, "hold": [], "pos": 5.0 + max(0, time.time() - MOCK.get("room_t", 0) - 25), "jseq": 0, "rate": 1, "runtime": 7800,
                "has_next": False, "by": "Yoh", "role": "video", "msg": "", "msg_by": "", "msg_seq": 1,
                "members": [], "others": ["Ann"], "not_ready": ["Ann"] if waiting else [], "away": [],
                "status": "Waiting for Ann to load." if waiting else "Playing with Ann.", "paused_by": "",
                "people": [{"name": "Yoh", "me": True, "state": "ready", "state_text": "ready"},
                           {"name": "Ann", "state": "loading" if waiting else "playing", "state_text": "loading the video" if waiting else "playing"},
                           {"name": "Bob", "state": "invited", "state_text": "invited"}],
                "events": [{"ago": 20, "text": "Yoh started playing together."}, {"ago": 15, "text": "Yoh invited Ann and Bob."}, {"ago": 4, "text": "Ann joined."}]}
    if path == "/api/play/together/invite": return {"message": "Invited " + q.get("names", "") + "."}
    if path == "/api/play/video/stats":
        return {"item": "m_magic", "max_mbps": 6, "bytes": 48234567, "out_kbps": 5400, "seg_kb": 2210, "seg_ms": 340, "sub_burned": False,
                "emby": {"video": "copied", "audio": "remade as AAC 2 ch", "size": "1920x1080", "mbps": 5.8, "fps": 0, "hw": "", "done_pct": 41.2, "reasons": "audio codec not supported"},
                "source": {"container": "mkv", "size_mb": 1450, "mbps": 8.4, "video": "H264 High 1920x1080 23.976fps SDR 7.6 Mbps",
                           "audio": "AC3 5.1 640 kbps (audio description)", "audio_name": "English - Dolby Digital - 5.1"}}
    if path == "/api/play/home":
        return {"libraries": [{"id": "v1", "name": "Movies", "type": "movies", "image": img("v1")},
                              {"id": "v2", "name": "TV shows", "type": "tvshows", "image": img("v2")},
                              {"id": "v3", "name": "Collections", "type": "boxsets", "image": img("v3")}],
                "resume": [NINE, ENC], "next_up": [EPS[1]],
                "latest": [{"id": "v1", "name": "Movies", "type": "movies", "items": MOVIES},
                           {"id": "v2", "name": "TV shows", "type": "tvshows", "items": SERIES}]}
    if path == "/api/play/info": return info(q.get("id", ""))
    if path == "/api/play/tracks":
        return {"audio": [{"index": 1, "label": "English - AAC - 5.1 - Default"}, {"index": 2, "label": "Audio description: English - AC3 - 5.1", "ad": True}],
                "subs": [{"index": 3, "label": "English - SUBRIP", "text": True}, {"index": 4, "label": "English (SDH) - SUBRIP", "text": True}],
                "ad_index": 2, "main_index": 1}
    if path == "/api/play/list":
        k = q.get("kind", "")
        if k == "episodes": return {"items": EPS}
        if k == "library": return {"items": MOVIES * 4 if q.get("parent") == "v1" else SERIES * 4}
        if k == "favorites": return {"items": SERIES[:1] + MOVIES[:2]}
        if k == "search": return {"items": SERIES[:1] + MOVIES[:2] + EPS[:1]}
        if k == "continue": return {"items": [NINE, ENC, EPS[1]]}                      # the web page's home rows
        if k.startswith("continue_"): return {"items": [NINE, EPS[1]] if k == "continue_shows" else [ENC]}   # the audio-only layout
        if k == "recent": return {"items": [EPS[0], MOVIES[0], EPS[2]]}
        if k == "shows": return {"items": SERIES * 3}
        if k == "movies": return {"items": MOVIES * 3}
        return {"items": []}
    if path == "/api/play/books/list":
        k = q.get("kind", "")
        if k == "books_chapters": return {"items": [{"type": "Chapter", "id": f"b1|{n}", "label": t, "at": a, "start": s, "book": "b1", "book_title": "The Bank Job"}
                                                    for n, (t, a, s) in enumerate([("Chapter 1", "0 seconds", 0), ("Chapter 2", "41 minutes", 2460), ("Chapter 3", "1 hour 30 minutes", 5400)])]}
        return {"items": BOOKS[:1] if k == "books_continue" else BOOKS}
    if path == "/api/play/video/prepare":
        return {"url": "/media/test.mp4", "tok": "t", "title": "Moonlit Magic 2 (2026)", "has_next": False, "runtime_ticks": 78000000000, "mbps": 6}
    if path in ("/api/play/save", "/api/play/video/stop", "/api/play/played", "/api/play/favorite"): return {"message": "OK"}
    return None

class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, f, *a): print("mock:", f % a, flush=True)
    def send(self, code, body, ct):
        self.send_response(code); self.send_header("Content-Type", ct); self.send_header("Content-Length", str(len(body))); self.end_headers()
        self.wfile.write(body)
    def file(self, p, ct):
        if not os.path.isfile(p): return self.send(404, b"no", "text/plain")
        data = open(p, "rb").read()
        rng = self.headers.get("Range")
        if rng and ct.startswith(("video", "audio")):
            a, _, b = rng.replace("bytes=", "").partition("-"); a = int(a); b = int(b) if b else len(data) - 1
            self.send_response(206); self.send_header("Content-Type", ct); self.send_header("Accept-Ranges", "bytes")
            self.send_header("Content-Range", f"bytes {a}-{b}/{len(data)}"); self.send_header("Content-Length", str(b - a + 1)); self.end_headers()
            self.wfile.write(data[a:b + 1]); return
        self.send(200, data, ct)
    def do_GET(self):
        u = urllib.parse.urlparse(self.path); q = {k: v[0] for k, v in urllib.parse.parse_qs(u.query).items()}
        m = re.match(r"/api/play/img/(\w+)/(\w+)$", u.path)
        if m:
            i, kind = m.groups()
            if kind == "Logo": return self.file(os.path.join(IMG, f"{i}.png"), "image/png")
            p = os.path.join(IMG, f"{i}_{kind}.jpg")
            if not os.path.isfile(p) and kind in ("Backdrop", "Thumb"): p = os.path.join(IMG, f"{i}_Primary.jpg")
            return self.file(p, "image/jpeg")
        m = re.match(r"/api/play/chapimg/\w+/(\d+)$", u.path)
        if m: return self.file(os.path.join(IMG, f"ch_{m.group(1)}.jpg"), "image/jpeg")
        m = re.match(r"/api/play/books/cover/(\w+)$", u.path)
        if m: return self.file(os.path.join(IMG, f"book_{m.group(1)}.jpg"), "image/jpeg")
        if u.path == "/media/test.mp4": return self.file(os.path.join(HERE, "test.mp4"), "video/mp4")
        if u.path == "/media/book.mp3": return self.file(os.path.join(HERE, "book.mp3"), "audio/mpeg")
        r = route(u.path, q)
        if r is None: return self.send(404, b'{"error":"no"}', "application/json")
        self.send(200, json.dumps(r).encode(), "application/json")
    def do_POST(self):
        n = int(self.headers.get("Content-Length") or 0); body = self.rfile.read(n).decode()
        q = {k: v[0] for k, v in urllib.parse.parse_qs(body).items()}
        r = route(urllib.parse.urlparse(self.path).path, q)
        self.send(200, json.dumps(r if r is not None else {"message": "OK"}).encode(), "application/json")

socketserver.ThreadingTCPServer.allow_reuse_address = True
socketserver.ThreadingTCPServer(("0.0.0.0", 8080), H).serve_forever()
