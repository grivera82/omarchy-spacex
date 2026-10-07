#!/usr/bin/env python3
"""Upcoming SpaceX launches, live countdowns and webcasts for the grivera.spacex
Omarchy plugin.

Launch data comes from The Space Devs' Launch Library 2 (no key). Its free tier
allows 15 requests an hour, so feeds are cached on disk, polled every 30
minutes normally and every few minutes around a launch, and the daemon never
spends more than REQUEST_BUDGET requests an hour. Webcasts (SpaceX on X,
YouTube restreams) play in mpv through yt-dlp, by default as a pinned
picture-in-picture window.

Standard library only.

  spacex status [--json]          the next launches from the cache
  spacex next                     one line: the next launch and its countdown
  spacex watch [ID] [--pip|--window|--fullscreen] [--liftoff]
                                  play the next (or given) launch's webcast
  spacex stop                     close the player
  spacex demo [SECONDS|off]       preview the next launch as if T-0 were SECONDS
                                  ago (negative = still counting down), for an hour
  spacex daemon                   JSON state lines on stdout, commands on stdin
"""

import concurrent.futures
import datetime
import gzip
import hashlib
import json
import os
import re
import shutil
import signal
import socket
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.request

HOME = os.path.expanduser("~")
STATE_DIR = os.path.join(os.environ.get("XDG_STATE_HOME") or os.path.join(HOME, ".local/state"), "grivera-spacex")
CACHE_DIR = os.path.join(os.environ.get("XDG_CACHE_HOME") or os.path.join(HOME, ".cache"), "grivera-spacex")
RUNTIME_DIR = os.environ.get("XDG_RUNTIME_DIR") or STATE_DIR
CONFIG_FILE = os.path.join(STATE_DIR, "config.json")
NOTIFIED_FILE = os.path.join(STATE_DIR, "notified.json")
PLAYER_FILE = os.path.join(STATE_DIR, "player.json")
PLAYER_LOG = os.path.join(STATE_DIR, "player.log")
DEMO_FILE = os.path.join(STATE_DIR, "demo.json")
BUDGET_FILE = os.path.join(CACHE_DIR, "budget.json")
FEED_FILE = os.path.join(CACHE_DIR, "%s.json")
IMG_DIR = os.path.join(CACHE_DIR, "img")
MPV_SOCKET = os.path.join(RUNTIME_DIR, "grivera-spacex-mpv.sock")
LIB = os.path.dirname(os.path.abspath(__file__))
ASSETS = os.path.join(os.path.dirname(LIB), "assets")
ICON = os.path.join(ASSETS, "rocket.svg")

API = "https://ll.thespacedevs.com/2.3.0/launches/%s/?lsp__id=121&mode=detailed&limit=%d"
FEEDS = {"upcoming": 25, "previous": 15}
UA = "grivera-spacex/1.0 (Omarchy plugin)"
REQUEST_BUDGET = 12          # per rolling hour; Launch Library allows 15
TICK = 5

DEFAULT_CONFIG = {
    "showStarlink": True,
    "starlinkAlerts": False,
    "notifyRemind": True,
    "remindMinutes": 30,
    "notifyLive": True,
    "notifyLiftoff": True,
    "notifyResult": True,
    "notifySlip": True,
    "source": "spacex",
    "playerMode": "pip",
    "quality": "1080",
    "barCountdown": True,
}

# Launch Library status ids.
GO, TBD, SUCCESS, FAILURE, HOLD, IN_FLIGHT, PARTIAL, TBC = 1, 2, 3, 4, 5, 6, 7, 8
FINAL = (SUCCESS, FAILURE, PARTIAL)
TIMED = ("exact", "rough")   # precision classes whose T-0 has a clock time

# Preferred webcast publisher → test on (publisher, source).
SOURCES = [
    {"value": "spacex", "label": "SpaceX (official)", "match": lambda p, s, o: p == "spacex"},
    {"value": "official", "label": "Any official", "match": lambda p, s, o: o},
    {"value": "nsf", "label": "NASASpaceflight", "match": lambda p, s, o: "nasaspaceflight" in p},
    {"value": "sfn", "label": "Spaceflight Now", "match": lambda p, s, o: "spaceflight now" in p},
    {"value": "ea", "label": "Everyday Astronaut", "match": lambda p, s, o: "everyday astronaut" in p},
    {"value": "tsd", "label": "The Space Devs", "match": lambda p, s, o: "space devs" in p},
]
PLAYABLE = ("x.com", "twitter.com", "youtube.com", "youtu.be", "www.youtube.com", "m.youtube.com")


# ---------------------------------------------------------------- helpers

def load_json(path, default):
    try:
        with open(path) as f:
            return json.load(f)
    except (OSError, ValueError):
        return default


def save_json(path, data, indent=None):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = "%s.%d.tmp" % (path, threading.get_ident())
    with open(tmp, "w") as f:
        json.dump(data, f, indent=indent, separators=None if indent else (",", ":"))
    os.replace(tmp, path)


class Throttled(Exception):
    def __init__(self, wait):
        super().__init__("rate limited for %ds" % wait)
        self.wait = wait


def http_get(url, timeout=20):
    req = urllib.request.Request(url, headers={"User-Agent": UA, "Accept-Encoding": "gzip"})
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            data = r.read()
    except urllib.error.HTTPError as e:
        if e.code == 429:
            body = e.read() or b""
            if body[:2] == b"\x1f\x8b":
                body = gzip.decompress(body)
            m = re.search(rb"available in (\d+)", body)
            raise Throttled(int(m.group(1)) if m else 900)
        raise
    if data[:2] == b"\x1f\x8b":
        data = gzip.decompress(data)
    return data


def parse_ts(s):
    if not s:
        return None
    try:
        return int(datetime.datetime.fromisoformat(s.replace("Z", "+00:00")).timestamp())
    except ValueError:
        return None


_DUR = re.compile(r"^(-)?P(?:(\d+)D)?(?:T(?:(\d+)H)?(?:(\d+)M)?(?:(\d+(?:\.\d+)?)S)?)?$")


def parse_duration(s):
    """ISO 8601 duration ('-PT38M', 'P0D', 'PT1M4S', 'P57DT3H7M13S') to seconds."""
    m = _DUR.match(s or "")
    if not m:
        return None
    sign, d, h, mi, sec = m.groups()
    total = int(d or 0) * 86400 + int(h or 0) * 3600 + int(mi or 0) * 60 + float(sec or 0)
    return -total if sign else total


def ordinal(n):
    n = int(n)
    suffix = "th" if 10 <= n % 100 <= 20 else {1: "st", 2: "nd", 3: "rd"}.get(n % 10, "th")
    return "%d%s" % (n, suffix)


def pad_short(name):
    name = name or ""
    for pat, rep in ((r"^Space Launch Complex (\w+)", r"SLC-\1"), (r"^Launch Complex (\w+)", r"LC-\1"),
                     (r"^Orbital Launch (?:Pad|Mount) (\w+)", r"Pad \1"), (r"^Unknown Pad$", "Pad TBD")):
        if re.match(pat, name):
            return re.sub(pat, rep, name)
    return name


def place_short(name):
    name = re.sub(r",\s*USA$", "", name or "")
    name = re.sub(r"^SpaceX\s+", "", name)
    name = re.sub(r"\s+(SFS|SFB|AFS|AFB)\b", "", name)
    return name.replace("Kennedy Space Center", "Kennedy")


def precision_of(np, sid):
    """Launch Library net_precision → (class, label for dates without a clock time)."""
    pid = np.get("id") if np else None
    if pid is None:
        return ("exact" if sid in (GO, IN_FLIGHT) + FINAL else "day"), None
    if pid in (0, 1):
        return "exact", None
    if pid in (2, 3, 4):
        return "rough", None
    return ("day" if pid == 5 else "coarse"), pid


def net_label(net, cls, pid):
    """Coarse NETs are UTC period ends (Dec 31 00:00Z = "December"), so format them in UTC."""
    if not net or cls in TIMED:
        return ""
    d = datetime.datetime.fromtimestamp(net, datetime.timezone.utc)
    if pid == 5:
        return "NET " + d.strftime("%a %b %-d")
    if pid == 6:
        return "Week of " + (d - datetime.timedelta(days=d.weekday())).strftime("%b %-d")
    if pid == 7:
        return "NET " + d.strftime("%B %Y")
    if pid in (8, 9, 10, 11):
        return "NET Q%d %d" % (pid - 7, d.year)
    if pid in (12, 13):
        return "NET H%d %d" % (pid - 11, d.year)
    if pid in (14, 15):
        return "NET %d" % d.year
    return "NET %ds" % (d.year // 10 * 10)


def vehicle_kind(full_name):
    n = (full_name or "").lower()
    if "starship" in n:
        return "starship"
    if "heavy" in n:
        return "heavy"
    return "falcon9"


def img_name(url):
    if not url:
        return ""
    ext = os.path.splitext(url.split("?")[0])[1].lower()
    if ext not in (".png", ".jpg", ".jpeg", ".webp", ".gif", ".svg"):
        ext = ".img"
    return hashlib.sha1(url.encode()).hexdigest()[:20] + ext


def open_url(url):
    if not url or not re.match(r"^https?://", url):
        return False
    for cmd in (["omarchy-launch-browser", url], ["xdg-open", url]):
        if shutil.which(cmd[0]):
            subprocess.Popen(cmd, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                             start_new_session=True)
            return True
    return False


# ---------------------------------------------------------------- normalizing

def norm_video(v, net):
    src = (v.get("source") or "").lower()
    kind = (v.get("type") or {}).get("name") or ""
    publisher = v.get("publisher") or src
    start = parse_ts(v.get("start_time"))
    out = {
        "url": v.get("url") or "",
        "title": v.get("title") or "",
        "publisher": publisher,
        "source": src,
        "official": kind.startswith("Official"),
        "kind": kind,
        "live": bool(v.get("live")),
        "start": start,
        "end": parse_ts(v.get("end_time")),
        "lang": ((v.get("language") or {}).get("code") or "").lower(),
        "playable": src in PLAYABLE,
        "priority": v.get("priority") or 99,
        "liftoffAt": None,
    }
    # Seconds into the recording that land just before T-0, for "watch liftoff".
    if start and net and not out["live"]:
        off = net - start - 90
        if 0 < off < 6 * 3600:
            out["liftoffAt"] = off
    return out


def rank_videos(videos, source, final):
    pick = next((s for s in SOURCES if s["value"] == source), SOURCES[0])
    now = time.time()
    for v in videos:
        # Recordings of an earlier, scrubbed attempt on a launch that hasn't flown yet.
        v["stale"] = bool(not final and not v["live"] and v["end"] and v["end"] < now)

    def key(v):
        p = v["publisher"].lower()
        return (not v["playable"], v["stale"], not v["live"] and any(x["live"] for x in videos),
                not pick["match"](p, v["source"], v["official"]),
                p != "spacex", not v["official"], v["lang"] not in ("", "en"), v["priority"])
    return sorted(videos, key=key)


def norm_stage(s):
    launcher = s.get("launcher") or {}
    landing = s.get("landing") or {}
    loc = landing.get("landing_location") or {}
    ltype = (landing.get("type") or {}).get("abbrev") or ""
    serial = launcher.get("serial_number") or ""
    if serial.lower().startswith("unknown") or launcher.get("is_placeholder"):
        serial = ""  # booster not assigned yet
    return {
        "type": s.get("type") or "Core",
        "serial": serial,
        "flight": s.get("launcher_flight_number"),
        "reused": bool(s.get("reused")),
        "turnaround": parse_duration(s.get("turn_around_time")),
        "landing": {
            "attempt": bool(landing.get("attempt")),
            "success": landing.get("success"),
            "where": loc.get("abbrev") or loc.get("name") or "",
            "whereName": loc.get("name") or "",
            "type": ltype,
            "description": landing.get("description") or "",
        } if landing else None,
    }


def norm_spacecraft(s):
    craft = s.get("spacecraft") or {}
    conf = craft.get("spacecraft_config") or {}
    crew = []
    for c in s.get("launch_crew") or []:
        a = c.get("astronaut") or {}
        crew.append({
            "name": a.get("name") or "",
            "role": (c.get("role") or {}).get("role") or "",
            "agency": (a.get("agency") or {}).get("abbrev") or "",
            "photo": ((a.get("image") or {}).get("thumbnail_url")) or "",
        })
    return {
        "name": craft.get("name") or conf.get("name") or "",
        "serial": craft.get("serial_number") or "",
        "config": conf.get("name") or "",
        "destination": s.get("destination") or "",
        "crew": crew,
    }


def norm_launch(l, source):
    status = l.get("status") or {}
    sid = status.get("id") or TBD
    rocket = l.get("rocket") or {}
    conf = rocket.get("configuration") or {}
    mission = l.get("mission") or {}
    orbit = mission.get("orbit") or {}
    pad = l.get("pad") or {}
    loc = pad.get("location") or {}
    net = parse_ts(l.get("net"))
    precision, ppid = precision_of(l.get("net_precision"), sid)
    ws, we = parse_ts(l.get("window_start")), parse_ts(l.get("window_end"))
    patches = sorted(l.get("mission_patches") or [], key=lambda p: -(p.get("priority") or 0))
    info = sorted(l.get("info_urls") or [], key=lambda u: u.get("priority") or 99)
    mname = mission.get("name") or (l.get("name") or "").split(" | ")[-1]
    stages = [norm_stage(s) for s in rocket.get("launcher_stage") or []]
    stages.sort(key=lambda s: s["type"] != "Core")
    craft = [norm_spacecraft(s) for s in rocket.get("spacecraft_stage") or []]
    timeline = []
    for ev in l.get("timeline") or []:
        t = parse_duration(ev.get("relative_time"))
        typ = ev.get("type") or {}
        if t is not None and typ.get("abbrev"):
            timeline.append({"t": t, "label": typ["abbrev"], "description": typ.get("description") or ""})
    timeline.sort(key=lambda e: e["t"])
    videos = rank_videos([norm_video(v, net) for v in l.get("vid_urls") or [] if v.get("url")], source, sid in FINAL)
    updates = [{"text": u.get("comment") or "", "ts": parse_ts(u.get("created_on")), "url": u.get("info_url") or ""}
               for u in (l.get("updates") or [])[:4] if u.get("comment")]
    image = l.get("image") or {}
    return {
        "id": l.get("id"),
        "name": mname,
        "fullName": l.get("name") or mname,
        "rocket": conf.get("name") or "Falcon 9",
        "rocketFull": conf.get("full_name") or conf.get("name") or "",
        "vehicle": vehicle_kind(conf.get("full_name") or conf.get("name")),
        "net": net,
        "precision": precision,
        "netLabel": net_label(net, precision, ppid),
        "windowStart": ws,
        "windowEnd": we,
        "status": {"id": sid, "abbrev": status.get("abbrev") or "", "name": status.get("name") or "",
                   "description": status.get("description") or ""},
        "phase": "done" if sid in FINAL else "flight" if sid == IN_FLIGHT else "upcoming",
        "probability": l.get("probability"),
        "weather": l.get("weather_concerns") or "",
        "failreason": l.get("failreason") or "",
        "webcastLive": bool(l.get("webcast_live")),
        "pad": {
            "name": pad.get("name") or "",
            "short": pad_short(pad.get("name")),
            "location": loc.get("name") or "",
            "place": place_short(loc.get("name")),
            "lat": pad.get("latitude"),
            "lon": pad.get("longitude"),
            "mapUrl": pad.get("map_url") or "",
            "timezone": loc.get("timezone_name") or "",
        },
        "mission": {
            "description": mission.get("description") or "",
            "type": mission.get("type") or "",
            "orbit": orbit.get("name") or "",
            "orbitAbbr": orbit.get("abbrev") or "",
            "customers": [a.get("name") for a in mission.get("agencies") or [] if a.get("name")],
        },
        "boosters": stages,
        "spacecraft": craft,
        "timeline": timeline,
        "videos": videos,
        "updates": updates,
        "infoUrl": info[0]["url"] if info else "",
        "flightclubUrl": l.get("flightclub_url") or "",
        "yearCount": l.get("agency_launch_attempt_count_year"),
        "padYearCount": l.get("pad_launch_attempt_count_year"),
        "padTurnaround": parse_duration(l.get("pad_turnaround")),
        "starlink": "starlink" in (l.get("name") or "").lower(),
        "patchUrl": patches[0].get("image_url") if patches else "",
        "imageUrl": image.get("thumbnail_url") or image.get("image_url") or "",
        "imageCredit": image.get("credit") or "",
        "updated": parse_ts(l.get("last_updated")),
    }


def norm_stats(results):
    for l in results:
        lsp = l.get("launch_service_provider") or {}
        if lsp.get("total_launch_count"):
            return {
                "total": lsp.get("total_launch_count"),
                "successes": lsp.get("successful_launches"),
                "failures": lsp.get("failed_launches"),
                "streak": lsp.get("consecutive_successful_launches"),
                "landings": lsp.get("successful_landings"),
                "landingAttempts": lsp.get("attempted_landings"),
                "landingStreak": lsp.get("consecutive_successful_landings"),
                "pending": lsp.get("pending_launches"),
            }
    return {}


# ---------------------------------------------------------------- request budget

class Budget:
    def __init__(self):
        data = load_json(BUDGET_FILE, {})
        self.stamps = [t for t in data.get("stamps", []) if t > time.time() - 3600]
        self.blocked_until = data.get("blockedUntil", 0)
        self.lock = threading.Lock()

    def save(self):
        try:
            save_json(BUDGET_FILE, {"stamps": self.stamps, "blockedUntil": self.blocked_until})
        except OSError:
            pass

    def used(self):
        now = time.time()
        self.stamps = [t for t in self.stamps if t > now - 3600]
        return len(self.stamps)

    def available_at(self):
        now = time.time()
        if self.blocked_until > now:
            return self.blocked_until
        if self.used() < REQUEST_BUDGET:
            return now
        return min(self.stamps) + 3601

    def take(self):
        with self.lock:
            if self.available_at() > time.time():
                return False
            self.stamps.append(time.time())
            self.save()
            return True

    def block(self, seconds):
        with self.lock:
            self.blocked_until = time.time() + max(60, seconds)
            self.save()


# ---------------------------------------------------------------- images

class Images:
    """Mission patches and launch photos, cached by URL hash."""

    def __init__(self, on_done):
        self.on_done = on_done
        self.pending = set()
        self.failed = {}
        self.lock = threading.Lock()
        self.pool = concurrent.futures.ThreadPoolExecutor(2)
        os.makedirs(IMG_DIR, exist_ok=True)

    def have(self, url):
        name = img_name(url)
        return name if name and os.path.exists(os.path.join(IMG_DIR, name)) else ""

    def want(self, url):
        name = img_name(url)
        if not name or not url.startswith("https://"):
            return
        with self.lock:
            if name in self.pending or self.failed.get(name, 0) > time.time() - 3600:
                return
            if os.path.exists(os.path.join(IMG_DIR, name)):
                return
            self.pending.add(name)
        self.pool.submit(self.fetch, url, name)

    def fetch(self, url, name):
        try:
            data = http_get(url, timeout=30)
            if len(data) > 12 * 1024 * 1024:
                raise ValueError("image too large")
            path = os.path.join(IMG_DIR, name)
            with open(path + ".tmp", "wb") as f:
                f.write(data)
            os.replace(path + ".tmp", path)
            self.on_done()
        except Exception:
            with self.lock:
                self.failed[name] = time.time()
        finally:
            with self.lock:
                self.pending.discard(name)

    def prune(self, keep):
        cutoff = time.time() - 45 * 86400
        try:
            for name in os.listdir(IMG_DIR):
                path = os.path.join(IMG_DIR, name)
                if name not in keep and os.path.getmtime(path) < cutoff:
                    os.remove(path)
        except OSError:
            pass


# ---------------------------------------------------------------- player

def proc_start(pid):
    try:
        with open("/proc/%d/stat" % pid) as f:
            return f.read().rsplit(")", 1)[1].split()[19]
    except (OSError, IndexError):
        return None


def player_info():
    info = load_json(PLAYER_FILE, {})
    pid = info.get("pid")
    if not pid or proc_start(pid) != info.get("procStart"):
        return None
    return info


def mpv_command(cmd):
    try:
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        s.settimeout(1.5)
        s.connect(MPV_SOCKET)
        s.sendall((json.dumps({"command": cmd}) + "\n").encode())
        s.close()
        return True
    except OSError:
        return False


def mpv_query(sock, prop):
    sock.sendall((json.dumps({"command": ["get_property", prop], "request_id": 1}) + "\n").encode())
    buf = b""
    while b"request_id" not in buf:
        chunk = sock.recv(4096)
        if not chunk:
            return None
        buf += chunk
    for line in buf.splitlines():
        try:
            msg = json.loads(line)
        except ValueError:
            continue
        if msg.get("request_id") == 1:
            return msg.get("data") if msg.get("error") == "success" else None
    return None


def seek_after_load(offset, pid, deadline=120):
    """Skip `offset` seconds into the recording once mpv has it open.

    X replays are HLS whose timestamps start at the broadcast's own clock
    (often 1700+ s), which mpv doesn't rebase, so `--start` lands before the
    first frame. A relative seek from wherever playback begins always works."""
    end = time.time() + deadline
    while time.time() < end:
        if proc_start(pid) is None:
            return False
        try:
            s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            s.settimeout(2)
            s.connect(MPV_SOCKET)
            if mpv_query(s, "playback-time") is not None:
                s.sendall((json.dumps({"command": ["seek", offset, "relative"]}) + "\n").encode())
                s.close()
                return True
            s.close()
        except OSError:
            pass
        time.sleep(0.4)
    return False


def stop_player():
    info = player_info()
    if not info:
        return False
    if not mpv_command(["quit"]):
        try:
            os.kill(info["pid"], signal.SIGTERM)
        except OSError:
            return False
    return True


def play(launch, mode="pip", video=None, liftoff=False, quality="1080", on_fail=None, wait_seek=False):
    """Start mpv on one of the launch's webcasts. Returns (ok, error)."""
    if not shutil.which("mpv"):
        return False, "mpv isn't installed"
    if not shutil.which("yt-dlp"):
        return False, "yt-dlp isn't installed"
    vids = [v for v in launch.get("videos") or [] if v["playable"] and not v.get("stale")]
    if video:
        vids = [v for v in launch.get("videos") or [] if v["url"] == video] or vids
    if not vids:
        return False, "no webcast posted for %s yet; it usually appears about an hour before launch" % launch["name"]
    v = vids[0]
    stop_player()

    q = str(quality if quality in ("480", "720", "1080", "1440") else "1080")
    if mode == "pip" and int(q) > 720:
        q = "720"
    label = "%s · %s" % (launch["name"], v["publisher"])
    args = ["mpv", "--force-window=immediate", "--keep-open=no", "--no-terminal",
            "--input-ipc-server=" + MPV_SOCKET,
            "--ytdl-format=bv*[height<=%s]+ba/b[height<=%s]/bv*+ba/b" % (q, q)]
    # Omarchy's pip.lua floats, pins and corners windows titled exactly "Picture-in-Picture".
    # Its own app id keeps mpv's centered floating-window rules from overriding that.
    if mode == "pip":
        args += ["--title=Picture-in-Picture", "--wayland-app-id=grivera-spacex-pip"]
    else:
        args.append("--title=SpaceX · %s" % label.replace("$", ""))
    if mode == "fullscreen":
        args.append("--fs")
    args += ["--", v["url"]]
    os.makedirs(STATE_DIR, exist_ok=True)
    log = open(PLAYER_LOG, "w")
    # Its own session keeps the video playing through shell restarts and plugin reloads.
    proc = subprocess.Popen(args, stdin=subprocess.DEVNULL, stdout=log, stderr=subprocess.STDOUT,
                            start_new_session=True)
    log.close()
    started = time.time()
    save_json(PLAYER_FILE, {"pid": proc.pid, "procStart": proc_start(proc.pid), "launchId": launch["id"],
                            "name": launch["name"], "publisher": v["publisher"], "url": v["url"],
                            "mode": mode, "liftoff": bool(liftoff and v.get("liftoffAt")), "started": started})

    seeker = None
    if liftoff and v.get("liftoffAt"):
        seeker = threading.Thread(target=seek_after_load, args=(v["liftoffAt"], proc.pid), daemon=True)
        seeker.start()

    def watch():
        code = proc.wait()
        if code and time.time() - started < 20 and on_fail:
            tail = ""
            try:
                with open(PLAYER_LOG) as f:
                    lines = [x.strip() for x in f if "rror" in x]
                tail = lines[-1][:140] if lines else ""
            except OSError:
                pass
            on_fail("couldn't play %s's stream%s" % (v["publisher"], (": " + tail) if tail else ""))
    threading.Thread(target=watch, daemon=True).start()
    if wait_seek and seeker:
        seeker.join()
    return True, None


# ---------------------------------------------------------------- notifications

class Notifier:
    def __init__(self, on_action):
        self.on_action = on_action
        self.ids = {}
        self.mem = load_json(NOTIFIED_FILE, {})
        for k in ("remind", "live", "liftoff", "result", "net", "status"):
            self.mem.setdefault(k, {})

    def save(self):
        cutoff = time.time() - 30 * 86400
        for k in ("remind", "live", "liftoff", "result"):
            self.mem[k] = {i: t for i, t in self.mem[k].items() if (t or 0) > cutoff}
        try:
            save_json(NOTIFIED_FILE, self.mem)
        except OSError:
            pass

    def send(self, key, summary, body, actions=(), urgency="normal", icon=""):
        if not shutil.which("notify-send"):
            return
        args = ["notify-send", "-a", "SpaceX", "-i", icon or ICON, "-u", urgency, "-p",
                "-h", "string:x-grivera-spacex:" + key]
        if actions:
            args.append("-w")
            for name, label in actions:
                args += ["-A", "%s=%s" % (name, label)]
        if key in self.ids:
            args += ["-r", str(self.ids[key])]
        args += [summary, body]

        def run():
            try:
                proc = subprocess.Popen(args, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)
                first = proc.stdout.readline().strip()
                if first.isdigit():
                    self.ids[key] = int(first)
                action = proc.stdout.read().strip()
                proc.wait()
                if action:
                    self.on_action(key, action)
            except OSError:
                pass

        threading.Thread(target=run, daemon=True).start()


def fmt_local(ts, with_day=True):
    d = datetime.datetime.fromtimestamp(ts)
    t = d.strftime("%-I:%M %p")
    if not with_day:
        return t
    today = datetime.date.today()
    if d.date() == today:
        return "today " + t
    if d.date() == today + datetime.timedelta(days=1):
        return "tomorrow " + t
    return d.strftime("%a %b %-d ") + t


def fmt_span(seconds):
    seconds = int(abs(seconds))
    d, h, m = seconds // 86400, seconds % 86400 // 3600, seconds % 3600 // 60
    if d:
        return "%dd %dh" % (d, h)
    if h:
        return "%dh %02dm" % (h, m)
    return "%d min" % max(1, m)


def booster_line(l):
    bits = []
    for b in l["boosters"]:
        if not b["serial"]:
            continue
        s = b["serial"]
        if b.get("flight"):
            s += " (%s flight)" % ordinal(b["flight"])
        land = b.get("landing")
        if land and land["attempt"] and land["where"]:
            s += " → " + land["where"]
        elif land and land["type"] == "EXP":
            s += " expended"
        bits.append(s)
    return ", ".join(bits)


def landing_result(l):
    bits = []
    for b in l["boosters"]:
        land = b.get("landing")
        if not b["serial"] or not land or not land["attempt"]:
            continue
        if land["success"] is True:
            bits.append("%s landed on %s" % (b["serial"], land["where"]))
        elif land["success"] is False:
            bits.append("%s was lost (%s)" % (b["serial"], land["where"]))
    return "; ".join(bits)


def check_notifications(launches, recent, config, notifier):
    now = time.time()
    mem = notifier.mem
    changed = False
    lead = int(config.get("remindMinutes") or 30) * 60

    for l in launches + recent:
        lid, net = l["id"], l["net"]
        if not lid or not net:
            continue
        sid = l["status"]["id"]
        prev_net = mem["net"].get(lid)
        prev_status = mem["status"].get(lid)
        mem["net"][lid], mem["status"][lid] = net, sid
        changed = changed or prev_net != net or prev_status != sid
        if l["starlink"] and not config.get("starlinkAlerts"):
            continue
        title = "%s · %s" % (l["rocket"], l["name"])
        where = "%s, %s" % (l["pad"]["short"], l["pad"]["place"]) if l["pad"]["place"] else l["pad"]["short"]
        watch = [("watch", "Watch"), ("default", "Open")]

        # NET moved (a scrub or a slip) on a launch inside the next three days.
        if (config.get("notifySlip") and prev_net and abs(net - prev_net) >= 1800 and l["phase"] == "upcoming"
                and min(net, prev_net) - now < 72 * 3600 and prev_net > now - 6 * 3600):
            when = fmt_local(net) if l["precision"] in TIMED else l["netLabel"].replace("NET ", "")
            fresh = [u for u in l["updates"] if u["ts"] and now - u["ts"] < 6 * 3600]
            note = fresh[0]["text"] if fresh else ""
            notifier.send("slip:" + lid, ("Delayed: " if net > prev_net else "Moved up: ") + title,
                          "Now NET %s (was %s)%s" % (when, fmt_local(prev_net), ("\n" + note) if note else ""),
                          [("default", "Open")])
            mem["remind"].pop(lid, None)
        elif config.get("notifySlip") and prev_status and prev_status != sid and sid == HOLD and net - now < 24 * 3600:
            notifier.send("slip:" + lid, "Hold: " + title, l["status"]["description"] or "The countdown is holding.",
                          [("default", "Open")], "normal")

        if (config.get("notifyRemind") and sid in (GO, TBC) and l["precision"] == "exact"
                and 0 < net - now <= lead and mem["remind"].get(lid) != net):
            mem["remind"][lid] = net
            body = "Liftoff %s from %s" % (fmt_local(net, False), where)
            if booster_line(l):
                body += "\nBooster " + booster_line(l)
            if l["probability"]:
                body += "\n%d%% chance of favorable weather" % l["probability"]
            notifier.send("remind:" + lid, "%s in %s" % (title, fmt_span(net - now)), body, watch)
            changed = True

        if (config.get("notifyLive") and l["webcastLive"] and not mem["live"].get(lid)
                and l["phase"] != "done" and abs(net - now) < 4 * 3600):
            mem["live"][lid] = now
            notifier.send("live:" + lid, "Webcast live: " + title,
                          "T-0 %s · %s" % (fmt_local(net, False), where), watch)
            changed = True

        if (config.get("notifyLiftoff") and sid == IN_FLIGHT and not mem["liftoff"].get(lid)
                and now - net < 3 * 3600):
            mem["liftoff"][lid] = now
            notifier.send("liftoff:" + lid, "Liftoff! " + title, "%s lifted off from %s" % (l["rocket"], where),
                          watch, "critical")
            changed = True

        if (config.get("notifyResult") and sid in FINAL and not mem["result"].get(lid)
                and prev_status and prev_status not in FINAL and now - net < 12 * 3600):
            mem["result"][lid] = now
            head = {SUCCESS: "Success", FAILURE: "Failure", PARTIAL: "Partial failure"}[sid]
            body = landing_result(l) or l["status"]["description"]
            if sid != SUCCESS and l["failreason"]:
                body = l["failreason"]
            notifier.send("result:" + lid, "%s: %s" % (head, title), body,
                          [("replay", "Watch liftoff"), ("default", "Open")], "normal" if sid == SUCCESS else "critical")
            changed = True

    live_ids = {l["id"] for l in launches + recent}
    for k in ("net", "status"):
        for lid in [i for i in mem[k] if i not in live_ids]:
            del mem[k][lid]
    if changed:
        notifier.save()


# ---------------------------------------------------------------- engine

class Engine:
    def __init__(self, emit=None):
        self.emit = emit or (lambda obj: None)
        self.config = dict(DEFAULT_CONFIG, **load_json(CONFIG_FILE, {}))
        self.wake = threading.Event()
        self.budget = Budget()
        self.images = Images(self.wake.set)
        self.notifier = Notifier(self.on_action)
        self.feeds = {k: load_json(FEED_FILE % k, {}) for k in FEEDS}
        self.norm = {}
        self.error = ""
        self.retry_at = {k: 0 for k in FEEDS}
        self.force = set()
        self.fetching = set()
        self.player_error = ""
        self.player_error_at = 0
        self.ui_open = False

    # -- feeds

    def normalized(self, kind):
        feed = self.feeds.get(kind) or {}
        key = (feed.get("fetchedAt"), self.config.get("source"))
        cached = self.norm.get(kind)
        if cached and cached[0] == key:
            return cached[1]
        out = []
        for l in feed.get("results") or []:
            try:
                out.append(norm_launch(l, self.config.get("source")))
            except Exception as exc:  # one odd record shouldn't hide the rest
                self.emit({"type": "log", "error": "skipped a launch: %r" % exc})
        self.norm[kind] = (key, out)
        return out

    def merged(self):
        up = self.normalized("upcoming")
        prev = self.normalized("previous")
        now = time.time()
        by_id = {}
        for l in prev + up:
            old = by_id.get(l["id"])
            if not old or (l["updated"] or 0) >= (old["updated"] or 0):
                by_id[l["id"]] = l
        launches = [l for l in by_id.values() if l["phase"] != "done" and l["net"]]
        recent = [l for l in by_id.values() if l["phase"] == "done" and l["net"]]
        # Launches that finished but haven't been confirmed yet stay in "upcoming".
        launches.sort(key=lambda l: l["net"])
        recent.sort(key=lambda l: -l["net"])
        return launches, recent[:20], now

    def interval(self, kind, launches, now):
        if kind == "previous":
            return 3 * 3600
        hot = any(l["webcastLive"] or l["phase"] == "flight" or
                  (l["precision"] in TIMED and -2 * 3600 < l["net"] - now < 2 * 3600)
                  for l in launches)
        if hot:
            return 6 * 60
        if any(0 < l["net"] - now < 24 * 3600 for l in launches) or self.ui_open:
            return 15 * 60
        return 30 * 60

    def due(self, launches, now):
        jobs = []
        for kind in FEEDS:
            feed = self.feeds.get(kind) or {}
            at = feed.get("fetchedAt") or 0
            due_at = at + self.interval(kind, launches, now)
            if kind == "previous":
                # Pull results soon after a launch time passes.
                passed = [l["net"] for l in launches if l["precision"] == "exact" and now - 6 * 3600 < l["net"] < now - 20 * 60]
                if passed and at < max(passed) + 20 * 60:
                    due_at = min(due_at, max(passed) + 20 * 60)
            if kind in self.force:
                due_at = now
            due_at = max(due_at, self.retry_at[kind])
            if due_at <= now and kind not in self.fetching:
                jobs.append((due_at, kind))
        jobs.sort()
        return [k for _, k in jobs]

    def fetch(self, kind):
        if not self.budget.take():
            return False
        self.fetching.add(kind)
        try:
            data = json.loads(http_get(API % (kind, FEEDS[kind])))
            feed = {"fetchedAt": int(time.time()), "results": data.get("results") or [], "count": data.get("count")}
            self.feeds[kind] = feed
            save_json(FEED_FILE % kind, feed)
            self.error = ""
            self.retry_at[kind] = 0
            self.force.discard(kind)
            return True
        except Throttled as t:
            self.budget.block(t.wait)
            self.error = "Launch Library rate limit, back in %s" % fmt_span(t.wait)
        except (urllib.error.URLError, OSError, ValueError) as exc:
            self.error = "can't reach Launch Library (%s)" % (getattr(exc, "reason", None) or exc)
            self.retry_at[kind] = time.time() + 300
        finally:
            self.fetching.discard(kind)
        return False

    # -- commands

    def find(self, lid):
        launches, recent, _ = self.merged()
        if not lid:
            nxt = next_launch(launches)
            return nxt
        return next((l for l in launches + recent if l["id"] == lid), None)

    def play(self, lid=None, mode=None, video=None, liftoff=False):
        l = self.find(lid)
        if not l:
            return False, "launch not found"
        if not (shutil.which("mpv") and shutil.which("yt-dlp")):
            # No player: open the webcast page instead.
            vids = [v for v in l["videos"] if v["url"] == video] or [v for v in l["videos"] if not v.get("stale")]
            if not vids:
                return False, "no webcast posted for %s yet" % l["name"]
            return (True, None) if open_url(vids[0]["url"]) else (False, "no browser launcher found")
        ok, err = play(l, mode or self.config.get("playerMode") or "pip", video, liftoff,
                       self.config.get("quality"), self.player_failed)
        self.player_error = "" if ok else err
        self.wake.set()
        return ok, err

    def player_failed(self, msg):
        self.player_error, self.player_error_at = msg, time.time()
        self.emit({"type": "result", "ok": False, "cmd": "watch", "error": msg})
        self.wake.set()

    def on_action(self, key, action):
        kind, _, lid = key.partition(":")
        if action == "watch":
            self.play(lid)
        elif action == "replay":
            self.play(lid, liftoff=True)
        elif action == "default":
            self.emit({"type": "open", "id": lid})

    def set_config(self, msg):
        for k, v in msg.items():
            if k in DEFAULT_CONFIG and isinstance(v, type(DEFAULT_CONFIG[k])):
                self.config[k] = v
        save_json(CONFIG_FILE, self.config, indent=2)
        self.norm.clear()

    # -- state

    def snapshot(self):
        launches, recent, now = self.merged()
        for l in launches[:15] + recent[:12]:
            self.images.want(l["patchUrl"])
            self.images.want(l["imageUrl"])
        shown = launches if self.config.get("showStarlink") else [l for l in launches if not l["starlink"]]
        shown = apply_demo(shown, now)
        out_l, out_r = [], []
        for src, dst in ((shown, out_l), (recent, out_r)):
            for l in src:
                l = dict(l)
                l["patch"] = self.images.have(l["patchUrl"])
                l["image"] = self.images.have(l["imageUrl"])
                dst.append(l)
        feeds = self.feeds.get("upcoming") or {}
        if not feeds.get("results") and not self.error:
            status = "loading"
        elif self.error and not feeds.get("results"):
            status = "offline"
        elif self.error:
            status = "stale"
        else:
            status = "ok"
        player = player_info()
        if self.player_error and time.time() - self.player_error_at > 20:
            self.player_error = ""
        state = {
            "status": status,
            "error": self.error,
            "fetchedAt": feeds.get("fetchedAt"),
            "requestsUsed": self.budget.used(),
            "requestBudget": REQUEST_BUDGET,
            "throttledUntil": self.budget.blocked_until if self.budget.blocked_until > now else 0,
            "config": self.config,
            "sources": [{"value": s["value"], "label": s["label"]} for s in SOURCES],
            "launches": out_l,
            "hiddenStarlink": len(launches) - len(shown),
            "recent": out_r,
            "pending": feeds.get("count"),
            "stats": norm_stats((self.feeds.get("previous") or {}).get("results") or feeds.get("results") or []),
            "imgDir": IMG_DIR,
            "player": {"playing": bool(player), "launchId": player.get("launchId"), "name": player.get("name"),
                       "publisher": player.get("publisher"), "mode": player.get("mode"),
                       "liftoff": player.get("liftoff")} if player else {"playing": False},
            "playerError": self.player_error,
            "tools": {"mpv": bool(shutil.which("mpv")), "ytdlp": bool(shutil.which("yt-dlp"))},
        }
        return state, launches, recent


def apply_demo(launches, now):
    """`spacex demo`: shift the next timed launch so T-0 is `offset` seconds ago.
    Only the panel sees it; alerts keep using the real data."""
    demo = load_json(DEMO_FILE, None)
    if not demo or now - demo.get("at", 0) > 3600:
        return launches
    for i, l in enumerate(launches):
        if l["precision"] in TIMED:
            vids = [dict(v, stale=False, live=(k == 0)) for k, v in enumerate(l["videos"])]
            l = dict(l, net=int(demo["at"] - demo.get("offset", 0)), webcastLive=True, videos=vids)
            if l["net"] <= now:
                l["status"] = {"id": IN_FLIGHT, "abbrev": "In Flight", "name": "Launch in Flight",
                               "description": "Demo: the mission clock is running."}
                l["phase"] = "flight"
            return launches[:i] + [l] + launches[i + 1:]
    return launches


def next_launch(launches, now=None):
    now = now or time.time()
    for l in launches:
        if l["phase"] == "flight" or l["net"] > now - 3 * 3600:
            return l
    return launches[0] if launches else None


def daemon():
    lock = threading.Lock()

    def emit(obj):
        with lock:
            try:
                sys.stdout.write(json.dumps(obj, separators=(",", ":")) + "\n")
                sys.stdout.flush()
            except BrokenPipeError:
                os._exit(0)

    engine = Engine(emit)

    def loop():
        last, pruned = None, 0
        while True:
            try:
                state, launches, recent = engine.snapshot()
                blob = json.dumps(state, sort_keys=True)
                if blob != last:
                    last = blob
                    emit({"type": "state", "state": state})
                for kind in engine.due(launches, time.time()):
                    engine.fetch(kind)
                state, launches, recent = engine.snapshot()
                check_notifications(launches, recent, engine.config, engine.notifier)
                blob = json.dumps(state, sort_keys=True)
                if blob != last:
                    last = blob
                    emit({"type": "state", "state": state})
                if time.time() - pruned > 86400:
                    pruned = time.time()
                    engine.images.prune({img_name(l[k]) for l in launches + recent for k in ("patchUrl", "imageUrl")})
            except Exception as exc:  # keep the bar alive on an API format change
                emit({"type": "log", "error": "update failed: %r" % exc})
            engine.wake.wait(TICK)
            engine.wake.clear()

    threading.Thread(target=loop, daemon=True).start()

    for line in sys.stdin:
        try:
            msg = json.loads(line)
        except ValueError:
            continue
        cmd, ok, err = msg.get("cmd"), True, None
        if cmd == "refresh":
            # Still inside the hourly budget; feeds fetched in the last 2 minutes are left alone.
            for kind in FEEDS:
                if time.time() - ((engine.feeds.get(kind) or {}).get("fetchedAt") or 0) > 120:
                    engine.force.add(kind)
                    engine.retry_at[kind] = 0
            if engine.budget.available_at() > time.time():
                ok, err = False, "request budget used up, next refresh in %s" % fmt_span(engine.budget.available_at() - time.time())
        elif cmd == "visible":
            engine.ui_open = bool(msg.get("open"))
        elif cmd == "config":
            engine.set_config({k: v for k, v in msg.items() if k not in ("cmd", "id")})
        elif cmd == "watch":
            ok, err = engine.play(msg.get("launch") or None, msg.get("mode") or None, msg.get("video") or None,
                                  bool(msg.get("liftoff")))
        elif cmd == "stop":
            ok = stop_player()
            err = None if ok else "nothing is playing"
        elif cmd == "player":
            ok = mpv_command(msg.get("args") or [])
            err = None if ok else "player isn't running"
        elif cmd == "open":
            ok = open_url(str(msg.get("url") or ""))
            err = None if ok else "no browser launcher found"
        elif cmd == "test":
            l = engine.find(None)
            if l:
                engine.notifier.send("test:" + l["id"], "%s · %s in 30 min" % (l["rocket"], l["name"]),
                                     "Notifications are working · %s, %s" % (l["pad"]["short"], l["pad"]["place"]),
                                     [("watch", "Watch"), ("default", "Open")])
            else:
                engine.notifier.send("test", "SpaceX", "Notifications are working")
        else:
            ok, err = False, "unknown command"
        engine.wake.set()
        emit({"type": "result", "id": msg.get("id"), "cmd": cmd, "ok": ok, "error": err})


# ---------------------------------------------------------------- CLI

def cli_engine():
    engine = Engine()
    launches, recent, now = engine.merged()
    if not launches:
        engine.fetch("upcoming")
        launches, recent, now = engine.merged()
    return engine, launches, recent


def countdown_text(l, now=None):
    now = now or time.time()
    s = int(l["net"] - now)
    if l["precision"] not in TIMED:
        return l["netLabel"]
    sign = "T-" if s >= 0 else "T+"
    s = abs(s)
    d, h, m, sec = s // 86400, s % 86400 // 3600, s % 3600 // 60, s % 60
    if d:
        return "%s%dd %02d:%02d:%02d" % (sign, d, h, m, sec)
    return "%s%02d:%02d:%02d" % (sign, h, m, sec)


def describe(l):
    if l["precision"] not in TIMED:
        return "%s · %s — %s · %s [%s]" % (l["rocket"], l["name"], l["netLabel"], l["pad"]["short"], l["status"]["abbrev"])
    return "%s · %s — %s · %s · %s [%s]" % (l["rocket"], l["name"], fmt_local(l["net"]), l["pad"]["short"],
                                           countdown_text(l), l["status"]["abbrev"])


def main(argv):
    cmd = argv[1] if len(argv) > 1 else "status"
    if cmd == "daemon":
        daemon()
    elif cmd == "status":
        engine, launches, recent = cli_engine()
        if "--json" in argv:
            print(json.dumps({"launches": launches, "recent": recent}, indent=2))
            return 0
        if not launches:
            print("No launch data yet: %s" % (engine.error or "try again in a minute"))
            return 1
        for l in launches[:10]:
            print(describe(l))
        if recent:
            print("\nRecent:")
            for l in recent[:5]:
                print("  %s · %s — %s · %s" % (l["rocket"], l["name"],
                                              datetime.datetime.fromtimestamp(l["net"]).strftime("%b %-d"),
                                              l["status"]["abbrev"]))
    elif cmd == "next":
        _, launches, _ = cli_engine()
        l = next_launch(launches)
        print(describe(l) if l else "No upcoming SpaceX launches in the cache.")
    elif cmd == "watch":
        engine, launches, recent = cli_engine()
        lid = next((a for a in argv[2:] if not a.startswith("--")), None)
        mode = next((m for m in ("pip", "window", "fullscreen") if "--" + m in argv), engine.config.get("playerMode"))
        l = next((x for x in launches + recent if x["id"] == lid), None) if lid else next_launch(launches)
        if not l:
            print("Launch not found.", file=sys.stderr)
            return 1
        # The CLI waits for the liftoff seek; the player's socket outlives it otherwise.
        ok, err = play(l, mode, None, "--liftoff" in argv, engine.config.get("quality"), wait_seek=True)
        if not ok:
            print(err, file=sys.stderr)
            return 1
        print("Playing %s" % l["name"])
    elif cmd == "stop":
        return 0 if stop_player() else 1
    elif cmd == "demo":
        arg = argv[2] if len(argv) > 2 else "120"
        if arg == "off":
            try:
                os.remove(DEMO_FILE)
            except OSError:
                pass
            print("Demo off.")
        else:
            save_json(DEMO_FILE, {"at": int(time.time()), "offset": int(arg)})
            print("Demo on for an hour: the next launch shows T%s%ds. `spacex demo off` ends it." % ("+" if int(arg) >= 0 else "", int(arg)))
    else:
        print(__doc__.strip())
        return 0 if cmd in ("-h", "--help", "help") else 2
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv) or 0)
