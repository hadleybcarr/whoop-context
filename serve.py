"""Dev server for web/, plus the small backend that live WHOOP data needs.

WHOOP's OAuth flow needs a client secret, which can't live in browser code, so this server does
the sign-in, keeps each visitor's tokens in memory (keyed by an HttpOnly cookie), and proxies the
WHOOP API. It also trains the models on a visitor's own labels (POST /api/train), and reads a
Google Calendar's private iCal address for visitors who connect that way (POST /api/calendar/ics),
since browsers can't fetch it themselves.

The WHOOP app keys can come from the server's config, or each visitor can paste the keys of their
own WHOOP developer app (POST /auth/whoop/credentials); those stay in that visitor's session.

Config comes from environment variables or a .env file next to this script (all optional):
  WHOOP_CLIENT_ID, WHOOP_CLIENT_SECRET   from the WHOOP Developer Dashboard
  GOOGLE_CLIENT_ID   Google OAuth client for Calendar; overrides web/js/config.js
  PUBLIC_URL    where visitors reach this server (default http://localhost:<port>, or the URL
                Render, Railway or Fly.io gives the app); PUBLIC_URL + /auth/whoop/callback is
                the WHOOP redirect URL
  HOST          interface to listen on (default 127.0.0.1; the Docker image uses 0.0.0.0)
  PORT          port to listen on (default 8000, or the first argument)

Usage: ml/.venv/bin/python serve.py [port]
Training imports ml/train.py, so run with the ml venv's Python for /api/train to work.
"""
import functools
import http.server
import json
import logging
import os
import secrets
import sys
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
from http.cookies import SimpleCookie
from pathlib import Path

ROOT = Path(__file__).resolve().parent
WHOOP_AUTH_URL = "https://api.prod.whoop.com/oauth/oauth2/auth"
WHOOP_TOKEN_URL = "https://api.prod.whoop.com/oauth/oauth2/token"
WHOOP_API = "https://api.prod.whoop.com/developer"
# offline: needed for a refresh token, since access tokens last about an hour.
WHOOP_SCOPES = "offline read:profile read:sleep read:workout read:recovery read:cycles"
COOKIE = "ft_session"
MAX_BODY = 5_000_000
SESSION_DAYS = 30
MAX_SESSIONS = 5000
# Training is CPU-heavy; a couple at a time keeps a small server responsive.
TRAINING_SLOTS = threading.BoundedSemaphore(2)


def load_env():
    env_file = ROOT / ".env"
    if env_file.exists():
        for line in env_file.read_text().splitlines():
            key, sep, value = line.strip().partition("=")
            if sep and not key.startswith("#"):
                os.environ.setdefault(key.strip(), value.strip().strip('"').strip("'"))


load_env()
PORT = int(sys.argv[1]) if len(sys.argv) > 1 else int(os.environ.get("PORT", 8000))
HOST = os.environ.get("HOST", "127.0.0.1")


def default_public_url():
    """The app's public address on common hosts, so it needn't be set by hand there."""
    if os.environ.get("RENDER_EXTERNAL_URL"):
        return os.environ["RENDER_EXTERNAL_URL"]
    if os.environ.get("RAILWAY_PUBLIC_DOMAIN"):
        return f"https://{os.environ['RAILWAY_PUBLIC_DOMAIN']}"
    if os.environ.get("FLY_APP_NAME"):
        return f"https://{os.environ['FLY_APP_NAME']}.fly.dev"
    return f"http://localhost:{PORT}"


PUBLIC_URL = (os.environ.get("PUBLIC_URL") or default_public_url()).rstrip("/")
REDIRECT_URI = f"{PUBLIC_URL}/auth/whoop/callback"
CLIENT_ID = os.environ.get("WHOOP_CLIENT_ID", "")
CLIENT_SECRET = os.environ.get("WHOOP_CLIENT_SECRET", "")
GOOGLE_CLIENT_ID = os.environ.get("GOOGLE_CLIENT_ID", "")

# sid → {"state", "client", "access_token", "refresh_token", "expires_at", "lock", "seen"}.
# In memory: a restart signs everyone out.
sessions: dict[str, dict] = {}
sessions_lock = threading.Lock()


def prune_sessions():
    """Forget sessions idle longer than the cookie lasts, and the oldest ones past the cap."""
    cutoff = time.time() - SESSION_DAYS * 86400
    with sessions_lock:
        for sid in [sid for sid, s in sessions.items() if s["seen"] < cutoff]:
            del sessions[sid]
        for sid in sorted(sessions, key=lambda sid: sessions[sid]["seen"])[:max(0, len(sessions) - MAX_SESSIONS + 1)]:
            del sessions[sid]


def client_keys(session):
    """(client_id, client_secret): the visitor's own WHOOP app if they gave one, else the server's."""
    own = (session or {}).get("client")
    return (own["id"], own["secret"]) if own else (CLIENT_ID, CLIENT_SECRET)


class WhoopError(Exception):
    def __init__(self, status, message):
        super().__init__(message)
        self.status = status


def post_form(url, fields):
    req = urllib.request.Request(url, data=urllib.parse.urlencode(fields).encode(),
                                 headers={"Content-Type": "application/x-www-form-urlencoded"})
    try:
        with urllib.request.urlopen(req, timeout=20) as res:
            return json.load(res)
    except urllib.error.HTTPError as err:
        raise WhoopError(err.code, f"WHOOP sign-in failed ({err.code})") from err


def save_tokens(session, body):
    session["access_token"] = body["access_token"]
    session["refresh_token"] = body.get("refresh_token", session.get("refresh_token"))
    session["expires_at"] = time.time() + int(body.get("expires_in", 3600)) - 60


def access_token(session):
    """A valid access token, refreshing first if it's about to expire. One refresh at a time per
    session: WHOOP invalidates the old refresh token, so a second concurrent refresh would fail."""
    with session["lock"]:
        if "access_token" not in session:
            raise WhoopError(401, "WHOOP not connected")
        if time.time() >= session["expires_at"]:
            if not session.get("refresh_token"):
                raise WhoopError(401, "WHOOP session expired; connect again")
            client_id, client_secret = client_keys(session)
            save_tokens(session, post_form(WHOOP_TOKEN_URL, {
                "grant_type": "refresh_token", "refresh_token": session["refresh_token"],
                "client_id": client_id, "client_secret": client_secret, "scope": "offline",
            }))
        return session["access_token"]


def whoop_get(session, path, params=None):
    url = f"{WHOOP_API}{path}" + (f"?{urllib.parse.urlencode(params)}" if params else "")
    req = urllib.request.Request(url, headers={"Authorization": f"Bearer {access_token(session)}"})
    try:
        with urllib.request.urlopen(req, timeout=20) as res:
            return json.load(res)
    except urllib.error.HTTPError as err:
        raise WhoopError(err.code, f"WHOOP request failed ({err.code})") from err


def whoop_collection(session, path, start, end):
    records, token = [], None
    while True:
        params = {"limit": 25, "start": start, "end": end, **({"nextToken": token} if token else {})}
        body = whoop_get(session, path, params)
        records += body.get("records", [])
        token = body.get("next_token")
        if not token:
            return records


def whoop_data(session, start, end):
    """Sleep, workouts and recovery between start and end, trimmed to what the page uses."""
    scored = lambda r: r.get("score_state") == "SCORED" and r.get("score")
    sleeps = whoop_collection(session, "/v2/activity/sleep", start, end)
    workouts = whoop_collection(session, "/v2/activity/workout", start, end)
    recoveries = whoop_collection(session, "/v2/recovery", start, end)
    cycles = whoop_collection(session, "/v2/cycle", start, end)
    sleep_end = {s["id"]: s["end"] for s in sleeps}
    return {
        "sleep": [{"start": s["start"], "end": s["end"]} for s in sleeps if not s.get("nap") and s.get("end")],
        "workouts": [{
            "id": w["id"], "start": w["start"], "end": w["end"], "sport": w.get("sport_name") or "Workout",
            "strain": w["score"]["strain"], "avg_hr": w["score"]["average_heart_rate"], "max_hr": w["score"]["max_heart_rate"],
        } for w in workouts if scored(w) and w.get("end")],
        # Each recovery is dated by the wake-up of the sleep it was scored on.
        "recovery": [{
            "wake": sleep_end[r["sleep_id"]], "score": r["score"]["recovery_score"],
            "rhr": r["score"]["resting_heart_rate"], "hrv": r["score"]["hrv_rmssd_milli"],
        } for r in recoveries if scored(r) and r.get("sleep_id") in sleep_end],
        "cycles": [{
            "start": c["start"], "end": c.get("end"), "strain": c["score"]["strain"],
            "avg_hr": c["score"]["average_heart_rate"], "max_hr": c["score"]["max_heart_rate"],
        } for c in cycles if scored(c)],
    }


# Only Google Calendar's own iCal addresses, so the server can't be pointed at anything else.
ICS_HOSTS = {"calendar.google.com"}
MAX_ICS = 10_000_000


def ics_events(url, start, end):
    """Timed events (repeats expanded) between start and end from a calendar's iCal address."""
    from datetime import datetime

    import icalendar
    import recurring_ical_events

    url = url.strip()
    if url.startswith("webcal://"):
        url = "https://" + url[len("webcal://"):]
    parts = urllib.parse.urlsplit(url)
    if parts.scheme != "https" or parts.hostname not in ICS_HOSTS or not parts.path.endswith(".ics"):
        raise ValueError("Paste the calendar's \"Secret address in iCal format\" (it starts with https://calendar.google.com and ends in .ics).")
    req = urllib.request.Request(url, headers={"User-Agent": "Context calendar reader"})
    try:
        with urllib.request.urlopen(req, timeout=20) as res:
            data = res.read(MAX_ICS + 1)
    except urllib.error.HTTPError as err:
        raise ValueError("Google didn't return that calendar. Check the address, or reset it in Google Calendar's settings and paste the new one.") from err
    if len(data) > MAX_ICS:
        raise ValueError("That calendar is too large to read.")
    try:
        calendar = icalendar.Calendar.from_ical(data)
    except ValueError as err:
        raise ValueError("That address didn't return a calendar file.") from err

    parse = lambda s: datetime.fromisoformat(s.replace("Z", "+00:00"))
    # Expanded occurrences lose their repeat rule, so note which events repeat from the source.
    repeating = {str(c.get("UID")) for c in calendar.walk("VEVENT") if c.get("RRULE") or c.get("RDATE") or c.get("RECURRENCE-ID")}
    events = []
    for ev in recurring_ical_events.of(calendar).between(parse(start), parse(end)):
        begin, finish = ev.get("DTSTART"), ev.get("DTEND")
        # All-day events have dates, not times, so there's no window to compare heart rate against.
        if not begin or not isinstance(begin.dt, datetime) or str(ev.get("STATUS", "")).upper() == "CANCELLED":
            continue
        begin = begin.dt
        finish = finish.dt if finish else begin + ev.get("DURATION").dt if ev.get("DURATION") else begin
        attendees = ev.get("ATTENDEE") or []
        events.append({
            "id": f"ics-{ev.get('UID', '')}-{begin.isoformat()}",
            "title": str(ev.get("SUMMARY") or "(No title)"),
            # Floating times (no zone) stay without an offset, so the browser reads them as local.
            "start": begin.isoformat(),
            "end": finish.isoformat(),
            "attendees": len(attendees) if isinstance(attendees, list) else 1,
            "recurring": str(ev.get("UID")) in repeating,
        })
    return events


def train(payload):
    import io

    import pandas as pd

    sys.path.insert(0, str(ROOT / "ml"))
    import train as ml

    days = pd.DataFrame(payload.get("days") or [])
    events = pd.read_csv(io.StringIO(payload["events_csv"])) if payload.get("events_csv") else pd.DataFrame()
    try:
        insights = ml.build_insights(events, "your data", days if len(days) else None)
    except (ValueError, KeyError):
        # Too few heart-rate-scored events for the event models; the recovery model may still train.
        insights = {"source": "your data", "n_events": int(len(events)), "events": [], "words": {},
                    "models": {"stress": None, "feeling": None}}
        if len(days):
            insights["recovery"] = ml.build_recovery_insights(days)
        if not insights.get("recovery") or "mae" not in insights["recovery"]:
            raise ValueError(f"Not enough data yet: rate {ml.MIN_ROWS}+ events with heart rate, or connect "
                             f"Google Calendar and WHOOP for {ml.MIN_DAYS}+ days of recovery.")
    return insights


class Handler(http.server.SimpleHTTPRequestHandler):
    def end_headers(self):
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("X-Frame-Options", "DENY")
        self.send_header("Referrer-Policy", "same-origin")
        super().end_headers()

    def list_directory(self, path):
        self.send_error(404)

    # ---- helpers ----

    def session(self, create=False):
        sid = SimpleCookie(self.headers.get("Cookie", "")).get(COOKIE)
        sid = sid.value if sid else None
        if sid in sessions:
            sessions[sid]["seen"] = time.time()
            return sid, sessions[sid]
        if not create:
            return None, None
        prune_sessions()
        sid = secrets.token_urlsafe(32)
        sessions[sid] = {"lock": threading.Lock(), "seen": time.time()}
        return sid, sessions[sid]

    def cookie_header(self, sid, max_age=30 * 86400):
        secure = "; Secure" if PUBLIC_URL.startswith("https://") else ""
        # Lax, so the cookie comes back on the top-level redirect from WHOOP.
        return f"{COOKIE}={sid}; Path=/; HttpOnly; SameSite=Lax; Max-Age={max_age}{secure}"

    def send_json(self, body, status=200, cookie=None):
        data = json.dumps(body).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        if cookie:
            self.send_header("Set-Cookie", cookie)
        self.end_headers()
        self.wfile.write(data)

    def redirect(self, location, cookie=None):
        self.send_response(302)
        self.send_header("Location", location)
        if cookie:
            self.send_header("Set-Cookie", cookie)
        self.end_headers()

    def query(self):
        return {k: v[0] for k, v in urllib.parse.parse_qs(urllib.parse.urlsplit(self.path).query).items()}

    # ---- routes ----

    def do_GET(self):
        path = urllib.parse.urlsplit(self.path).path
        if path == "/healthz":
            return self.send_json({"ok": True})
        if path == "/js/config.js" and GOOGLE_CLIENT_ID:
            return self.google_config()
        try:
            if path == "/auth/whoop/login":
                return self.whoop_login()
            if path == "/auth/whoop/callback":
                return self.whoop_callback()
            if path == "/api/whoop/status":
                return self.whoop_status()
            if path == "/api/whoop/data":
                return self.whoop_data()
        except WhoopError as err:
            return self.send_json({"error": str(err)}, err.status if err.status in (401, 429) else 502)
        super().do_GET()

    def do_POST(self):
        path = urllib.parse.urlsplit(self.path).path
        # Only the page itself may call these (blocks cross-site form posts).
        origin = self.headers.get("Origin")
        if origin and origin != PUBLIC_URL and origin != f"http://localhost:{PORT}":
            return self.send_json({"error": "Bad origin"}, 403)
        if path == "/auth/whoop/credentials":
            return self.whoop_credentials()
        if path == "/auth/whoop/logout":
            sid, _ = self.session()
            sessions.pop(sid, None)
            return self.send_json({"ok": True}, cookie=self.cookie_header("", max_age=0))
        if path == "/api/calendar/ics":
            length = int(self.headers.get("Content-Length", 0))
            body = json.loads(self.rfile.read(min(length, 10_000)) or b"{}")
            try:
                return self.send_json({"events": ics_events(str(body.get("url", "")), body["start"], body["end"])})
            except ImportError:
                return self.send_json({"error": "Run the server with ml/.venv/bin/python to read calendars"}, 500)
            except (ValueError, KeyError) as err:
                return self.send_json({"error": str(err) if isinstance(err, ValueError) else "Missing start or end"}, 400)
            except Exception:
                logging.exception("Reading a calendar failed")
                return self.send_json({"error": "Couldn't read that calendar right now. Try again in a moment."}, 502)
        if path == "/api/train":
            length = int(self.headers.get("Content-Length", 0))
            if length > MAX_BODY:
                return self.send_json({"error": "Too much data"}, 413)
            payload = self.rfile.read(length)
            if not TRAINING_SLOTS.acquire(blocking=False):
                return self.send_json({"error": "Busy training other models. Try again in a moment."}, 503)
            try:
                return self.send_json(train(json.loads(payload)))
            except ImportError:
                return self.send_json({"error": "Run the server with ml/.venv/bin/python to train"}, 500)
            except ValueError as err:  # too little data, or data the models can't use: say so
                return self.send_json({"error": str(err)}, 400)
            except Exception:
                logging.exception("Training failed")
                return self.send_json({"error": "Training failed on this data."}, 500)
            finally:
                TRAINING_SLOTS.release()
        self.send_error(404)

    def google_config(self):
        """web/js/config.js with the deployment's Google client ID filled in."""
        source = (ROOT / "web" / "js" / "config.js").read_text()
        data = source.replace("export const GOOGLE_CLIENT_ID = '';", f"export const GOOGLE_CLIENT_ID = {json.dumps(GOOGLE_CLIENT_ID)};").encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/javascript")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def whoop_credentials(self):
        length = int(self.headers.get("Content-Length", 0))
        body = json.loads(self.rfile.read(min(length, 10_000)) or b"{}")
        client_id, client_secret = str(body.get("client_id", "")).strip(), str(body.get("client_secret", "")).strip()
        if not (0 < len(client_id) <= 200 and 0 < len(client_secret) <= 200):
            return self.send_json({"error": "Paste both the client ID and the client secret."}, 400)
        sid, session = self.session(create=True)
        session["client"] = {"id": client_id, "secret": client_secret}
        self.send_json({"ok": True}, cookie=self.cookie_header(sid))

    def whoop_login(self):
        sid, session = self.session(create=True)
        client_id, client_secret = client_keys(session)
        if not (client_id and client_secret):
            return self.redirect("/?whoop=setup", cookie=self.cookie_header(sid))
        session["state"] = secrets.token_urlsafe(16)
        params = {"response_type": "code", "client_id": client_id, "redirect_uri": REDIRECT_URI,
                  "scope": WHOOP_SCOPES, "state": session["state"]}
        self.redirect(f"{WHOOP_AUTH_URL}?{urllib.parse.urlencode(params)}", cookie=self.cookie_header(sid))

    def whoop_callback(self):
        q = self.query()
        sid, session = self.session()
        if not session or not q.get("state") or q["state"] != session.pop("state", None):
            return self.redirect("/?whoop=error")
        if "code" not in q:
            return self.redirect("/?whoop=denied")
        client_id, client_secret = client_keys(session)
        try:
            save_tokens(session, post_form(WHOOP_TOKEN_URL, {
                "grant_type": "authorization_code", "code": q["code"], "redirect_uri": REDIRECT_URI,
                "client_id": client_id, "client_secret": client_secret,
            }))
        except WhoopError:
            return self.redirect("/?whoop=error")
        self.redirect("/?whoop=connected")

    def whoop_status(self):
        _, session = self.session()
        body = {
            "backend": True,
            # server_keys: the site owner set up a WHOOP app, so visitors can just sign in.
            "server_keys": bool(CLIENT_ID and CLIENT_SECRET),
            "configured": all(client_keys(session)),
            "connected": bool(session and "access_token" in session),
            "redirect_uri": REDIRECT_URI,
        }
        if body["connected"]:
            profile = whoop_get(session, "/v2/user/profile/basic")
            body["name"] = profile.get("first_name", "")
        self.send_json(body)

    def whoop_data(self):
        _, session = self.session()
        if not session:
            raise WhoopError(401, "WHOOP not connected")
        q = self.query()
        self.send_json(whoop_data(session, q["start"], q["end"]))


if __name__ == "__main__":
    handler = functools.partial(Handler, directory=str(ROOT / "web"))
    print(f"Serving on {PUBLIC_URL} (WHOOP keys {'from .env' if CLIENT_ID else 'pasted by each visitor'})", flush=True)
    http.server.ThreadingHTTPServer((HOST, PORT), handler).serve_forever()
