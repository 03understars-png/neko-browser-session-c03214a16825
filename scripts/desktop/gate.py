
from __future__ import annotations

import base64
import hashlib
import hmac
import html
import json
import os
import sys
import threading
import time
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlsplit

SECRET = os.environ.get("GATE_SECRET", "").encode()
_SALT = os.urandom(16)
LOGIN_HASH = hashlib.pbkdf2_hmac("sha256", os.environ.get("GATE_LOGIN", "").encode(), _SALT, 200_000)
VIEW_HASH = (hashlib.pbkdf2_hmac("sha256", os.environ["GATE_VIEW_LOGIN"].encode(), _SALT, 200_000)
             if os.environ.get("GATE_VIEW_LOGIN") else b"")
AUTH = {"full": os.environ.get("GATE_AUTH_FULL", ""), "view": os.environ.get("GATE_AUTH_VIEW", "")}
METRICS_URL = os.environ.get("GATE_METRICS_URL", "")
REPORT_URL = os.environ.get("GATE_REPORT_URL", "")
COOKIE = "__Host-cb_gate"
DEVICE = "__Host-cb_device"
COOKIE_SECONDS = 12 * 3600
FREE_TRIES = 3
MAX_WAIT = 15 * 60
LOCK_AFTER = 12
LOCK_SECONDS = 30 * 60

_lock = threading.Lock()
_per_ip: dict[str, tuple[int, float]] = {}
_recent: list[float] = []
_locked_until = 0.0
_viewed: dict[str, float] = {}
_passes: dict[str, float] = {}
PASS_SECONDS = 60
REMOVED = "The owner removed you from this desktop."
PIN_GEN = 0
PIN_BASE = hmac.new(SECRET, b"pin-base:" + os.environ.get("GATE_LOGIN", "").encode(), hashlib.sha256).hexdigest()[:24]

PIN_SCRIPT = ("(()=>{const i=document.getElementById('p'),c=[...document.querySelectorAll('.chip')],"
              "f=i.form,go=()=>{i.value=i.value.replace(/\\D/g,'').slice(0,4);"
              "c.forEach((e,n)=>{e.classList.toggle('on',n<i.value.length);e.classList.toggle('at',n===i.value.length)});"
              "if(i.value.length===4){f.querySelector('button').disabled=true;f.submit()}};"
              "i.addEventListener('input',go);i.addEventListener('focus',go);i.addEventListener('blur',()=>c.forEach(e=>e.classList.remove('at')));go();i.focus()})()")
PIN_SCRIPT_HASH = base64.b64encode(hashlib.sha256(PIN_SCRIPT.encode()).digest()).decode()

PAGE = """<!doctype html><html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1"><meta name="referrer" content="no-referrer">
<meta name="theme-color" content="#000000"><title>Compute Base desktop</title><style>
:root{color-scheme:dark}*{box-sizing:border-box}body{margin:0;min-height:100vh;min-height:100dvh;display:grid;
place-items:center;background:#000;color:#fff;font:16px/1.5 system-ui,-apple-system,"Segoe UI",sans-serif;padding:16px}
form{width:100%;max-width:400px;padding:32px 28px;border:1px solid #2a2a2a;border-radius:28px;background:#0b0b0b;text-align:center}
.k{margin:0;color:#8a8a8a;font-size:12px;font-weight:700;letter-spacing:.14em;text-transform:uppercase}
h1{margin:6px 0 8px;font-size:26px}p{color:#a6a6a6;margin:0 0 24px}
.pin{position:relative;display:flex;justify-content:center;gap:14px;margin:0 auto 6px;width:max-content}
.chip{width:58px;height:58px;border:1.5px solid #444;border-radius:50%;display:grid;place-items:center;transition:border-color .12s,background .12s}
.chip::after{content:"";width:14px;height:14px;border-radius:50%;background:#fff;transform:scale(0);transition:transform .12s}
.chip.on{border-color:#fff;background:#151515}.chip.on::after{transform:scale(1)}.chip.at{border-color:#fff;box-shadow:0 0 0 4px #ffffff22}
#p{position:absolute;inset:0;width:100%;height:100%;opacity:0;border:0;padding:0;font-size:16px;color:transparent;
background:transparent;caret-color:transparent;letter-spacing:40px;cursor:text}
button{width:100%;min-height:52px;margin-top:22px;border:0;border-radius:999px;background:#fff;color:#000;font-size:16px;
font-weight:700;cursor:pointer}button:disabled{opacity:.6}
.n{display:block;width:100%;min-height:46px;margin:0 0 22px;padding:0 16px;border:1px solid #333;border-radius:999px;background:#000;
color:#fff;font:inherit;text-align:center}.n:focus{outline:none;border-color:#fff}
.e{margin:16px 0 0;color:#ff8a8a;min-height:1.5em;font-size:14px}
@media (max-width:380px){.chip{width:52px;height:52px}.pin{gap:10px}}</style></head><body>
<form method="post" action="/__cb/login" autocomplete="off"><p class="k">Compute Base</p><h1>This desktop is locked</h1>
<p>Enter the 4-digit PIN you were shown when it started.</p>
<input class="n" name="name" maxlength="40" placeholder="Your name (optional)" autocomplete="nickname" aria-label="Your name, optional">
<label class="pin" for="p" aria-label="PIN, 4 digits"><span class="chip" aria-hidden="true"></span><span class="chip" aria-hidden="true"></span><span class="chip" aria-hidden="true"></span><span class="chip" aria-hidden="true"></span>
<input id="p" name="password" type="password" inputmode="numeric" pattern="[0-9]{4}" maxlength="4" required autocomplete="off" aria-label="PIN"></label>
<input type="hidden" name="next" value="{next}"><button type="submit">Unlock</button><p class="e" role="alert">{error}</p></form>
<script>""" + PIN_SCRIPT + """</script>
</body></html>"""


def b64(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).decode().rstrip("=")


def unb64(text: str) -> bytes:
    return base64.urlsafe_b64decode(text + "=" * (-len(text) % 4))


def sign(purpose: str, payload: str) -> str:
    return b64(hmac.new(SECRET, f"{purpose}:{payload}".encode(), hashlib.sha256).digest())


def valid(purpose: str, token: str) -> dict | None:
    try:
        payload, signature = token.split(".", 1)
    except ValueError:
        return None
    if not SECRET or not hmac.compare_digest(sign(purpose, payload), signature):
        return None
    try:
        data = json.loads(unb64(payload))
    except (ValueError, UnicodeDecodeError):
        return None
    return data if isinstance(data, dict) and data.get("exp", 0) > time.time() else None


def password_ok(given: str) -> bool:
    return role_of(given) is not None


def role_of(given: str) -> str | None:
    if not os.environ.get("GATE_LOGIN"):
        return None
    hashed = hashlib.pbkdf2_hmac("sha256", given.encode(), _SALT, 200_000)
    if hmac.compare_digest(hashed, LOGIN_HASH):
        return "full"
    if VIEW_HASH and AUTH["view"] and hmac.compare_digest(hashed, VIEW_HASH):
        return "view"
    return None


_opened: list[tuple[str, str]] = []

TAP_PORT = int(os.environ.get("GATE_TAP_PORT") or 9079)
UPSTREAM = os.environ.get("GATE_UPSTREAM", "")
_live: dict[int, dict] = {}
_banned_ids: set[str] = set()
_banned_ips: set[str] = set()
_kicked: set[str] = set()
_changed = threading.Event()
_SHUT = getattr(__import__("socket"), "SHUT_RDWR", 2)


LIVE_FILE = os.environ.get("GATE_LIVE_FILE", "")
STREAMER = os.environ.get("GATE_STREAMER", "")
SCALE_FILE = os.environ.get("GATE_SCALE_FILE", "")
PIN_HOOK = os.environ.get("GATE_PIN_HOOK", "")


def pin_hook(pin: str) -> None:
    if not PIN_HOOK:
        return
    import subprocess

    try:
        subprocess.run([PIN_HOOK], input=pin + "\n", text=True, timeout=60, capture_output=True, check=False)
    except (OSError, subprocess.SubprocessError):
        pass


def save_scale(query: str) -> None:
    try:
        value = float((parse_qs(query).get("s") or [""])[0])
    except ValueError:
        return
    if not SCALE_FILE or not 0.5 <= value <= 4:
        return
    temp = SCALE_FILE + ".new"
    with open(temp, "w", encoding="utf-8") as handle:
        handle.write(f"{round(value, 3):g}\n")
    os.replace(temp, SCALE_FILE)


def streamers() -> set[int]:
    import subprocess

    if not STREAMER:
        return set()
    try:
        if sys.platform == "win32":
            out = subprocess.run(["tasklist", "/FI", f"IMAGENAME eq {STREAMER}", "/FO", "CSV", "/NH"],
                                 capture_output=True, text=True, timeout=10).stdout
            return {int(line.split('","')[1]) for line in out.splitlines() if line.startswith(f'"{STREAMER}"')}
        out = subprocess.run(["pgrep", "-x", STREAMER], capture_output=True, text=True, timeout=10).stdout
        return {int(pid) for pid in out.split()}
    except (OSError, ValueError, IndexError, subprocess.SubprocessError):
        return set()


def end_streamer(pid: int) -> None:
    import signal
    import subprocess

    try:
        if sys.platform == "win32":
            subprocess.run(["taskkill", "/F", "/PID", str(pid)], capture_output=True, timeout=10)
        else:
            os.kill(pid, signal.SIGTERM)
    except (OSError, subprocess.SubprocessError):
        pass


def _claim_streamer(key: int, before: set[int]) -> None:
    for _ in range(20):
        time.sleep(1)
        with _lock:
            conn = _live.get(key)
            if conn is None:
                return
            taken = {pid for c in _live.values() for pid in c.get("pids", ())}
        new = streamers() - before - taken
        if new:
            with _lock:
                if key in _live:
                    _live[key].setdefault("pids", set()).update(new)
            return


def changed() -> None:
    _changed.set()
    if LIVE_FILE:
        with _lock:
            count = len({c["id"] for c in _live.values()})
        try:
            with open(LIVE_FILE + ".new", "w", encoding="utf-8") as handle:
                handle.write(f"{count}\n")
            os.replace(LIVE_FILE + ".new", LIVE_FILE)
        except OSError:
            pass


def banned(viewer: str, ip: str) -> bool:
    return bool(viewer and viewer in _banned_ids) or bool(ip and ip in _banned_ips)


def kick(viewer: str) -> None:
    with _lock:
        if viewer in _kicked:
            return
        _kicked.add(viewer)
        _banned_ids.add(viewer)
        mine = [_live.pop(k) for k, c in list(_live.items()) if c["id"] == viewer]
        ips = {c["ip"] for c in mine} | set(_viewer_ips.get(viewer, ()))
        for ip in ips:
            others = {v for v, seen in _viewer_ips.items() if ip in seen and v not in _banned_ids}
            if not others:
                _banned_ips.add(ip)
    for c in mine:
        for pid in c.get("pids", ()):
            end_streamer(pid)
        for s in (c["client"], c["upstream"]):
            try:
                s.shutdown(_SHUT)
                if sys.platform == "win32":
                    s.close()
            except OSError:
                pass
    changed()


def reset_pins(gen: int, full: str, view: str) -> bool:
    global LOGIN_HASH, VIEW_HASH, PIN_GEN
    if gen <= PIN_GEN or not (len(full) == 4 and full.isdigit()):
        return False
    new_full = hashlib.pbkdf2_hmac("sha256", full.encode(), _SALT, 200_000)
    new_view = (hashlib.pbkdf2_hmac("sha256", view.encode(), _SALT, 200_000)
                if view and len(view) == 4 and view.isdigit() and view != full else b"")
    with _lock:
        LOGIN_HASH, PIN_GEN = new_full, gen
        if VIEW_HASH or new_view:
            VIEW_HASH = new_view
        gone = list(_live.values())
        _live.clear()
        _per_ip.clear()
    for c in gone:
        for pid in c.get("pids", ()):
            end_streamer(pid)
        for sock in (c["client"], c["upstream"]):
            try:
                sock.shutdown(_SHUT)
                if sys.platform == "win32":
                    sock.close()
            except OSError:
                pass
    changed()
    return True


_viewer_ips: dict[str, set[str]] = {}


def viewers_now() -> list[dict]:
    with _lock:
        rows: dict[str, dict] = {}
        for c in _live.values():
            row = rows.setdefault(c["id"], {"id": c["id"], "name": c["name"], "role": c["role"], "ip": c["ip"],
                                            "browser": c["browser"][:200], "since": int(c["since"]), "connections": 0})
            row["connections"] += 1
            row["since"] = min(row["since"], int(c["since"]))
        return sorted(rows.values(), key=lambda r: r["since"])[:50]


def _pipe(source, target) -> None:
    try:
        while True:
            data = source.recv(262144)
            if not data:
                break
            target.sendall(data)
    except OSError:
        pass
    for s, how in ((target, 1), (source, 0)):
        try:
            s.shutdown(how)
        except OSError:
            pass


def _tap_one(client) -> None:
    import socket

    upstream = None
    key = id(client)
    try:
        client.settimeout(20)
        head = b""
        while b"\r\n\r\n" not in head:
            chunk = client.recv(65536)
            if not chunk or len(head) > 65536:
                return
            head += chunk
        lines = head.split(b"\r\n\r\n", 1)[0].decode("latin-1").split("\r\n")
        headers = {}
        for line in lines[1:]:
            name, _, value = line.partition(":")
            headers[name.strip().lower()] = value.strip()
        ip = visitor_ip(headers.get("cf-connecting-ip", ""), headers.get("x-forwarded-for", ""), headers.get("x-real-ip", ""))
        data = None
        for part in headers.get("cookie", "").split(";"):
            name, _, value = part.strip().partition("=")
            if name == COOKIE:
                data = valid("cookie", value) or data
        viewer = str((data or {}).get("vid") or "")
        if (not data or banned(viewer, ip) or not hmac.compare_digest(str(data.get("ip", "")), ip)
                or int(data.get("gen") or 0) != PIN_GEN):
            client.sendall(b"HTTP/1.1 403 Forbidden\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
            return
        before = streamers()
        host, _, port = UPSTREAM.rpartition(":")
        upstream = socket.create_connection((host or "127.0.0.1", int(port)), timeout=20)
        upstream.sendall(head)
        client.settimeout(None)
        upstream.settimeout(None)
        for s in (client, upstream):
            try:
                s.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
            except OSError:
                pass
        with _lock:
            _live[key] = {"id": viewer, "name": str(data.get("name") or "")[:40], "role": str(data.get("role") or "full"),
                          "ip": ip, "browser": headers.get("user-agent", ""), "since": time.time(),
                          "client": client, "upstream": upstream}
            _viewer_ips.setdefault(viewer, set()).add(ip)
        changed()
        if STREAMER:
            threading.Thread(target=_claim_streamer, args=(key, before), daemon=True).start()
        back = threading.Thread(target=_pipe, args=(upstream, client), daemon=True)
        back.start()
        _pipe(client, upstream)
        back.join()
    except (OSError, ValueError):
        pass
    finally:
        with _lock:
            gone = _live.pop(key, None)
        if gone:
            changed()
        for s in (client, upstream):
            try:
                if s:
                    s.close()
            except OSError:
                pass


def tap_server(bind: str) -> None:
    import socket

    server = socket.create_server((bind, TAP_PORT), backlog=256, reuse_port=False)
    changed()
    while True:
        client, _ = server.accept()
        threading.Thread(target=_tap_one, args=(client,), daemon=True).start()


def watching_now() -> int | None:
    if not METRICS_URL:
        return None
    try:
        with urllib.request.urlopen(METRICS_URL, timeout=5) as response:
            text = response.read(400_000).decode(errors="replace")
    except Exception:
        return None
    import re

    lines = [line for line in text.splitlines() if line.startswith("caddy_http_requests_in_flight{")]
    _metrics_seen[:] = [line[:160] for line in lines[:6]]
    server = lambda line: (re.search(r'server="([^"]*)"', line) or [None, ""])[1]
    counting = {server(line) for line in lines if 'handler="metrics"' in line}
    total = 0.0
    for line in lines:
        if 'handler="subroute"' in line and server(line) not in counting:
            try:
                total += float(line.rsplit(" ", 1)[1])
            except ValueError:
                pass
    return max(0, int(total) - (0 if counting else 1))


_metrics_seen: list[str] = []


_machine: dict[str, object] | None = None


def machine() -> dict[str, object]:
    global _machine
    if _machine is None and os.environ.get("GATE_MEASURE") != "1":
        _machine = {}
    if _machine is None:
        try:
            sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
            import measure

            _machine = measure.machine()
        except Exception:
            _machine = {}
    return _machine


def presence_loop() -> None:
    last, last_at = None, 0.0
    while True:
        now = watching_now()
        viewers = viewers_now()
        with _lock:
            opened = list(_opened)
        snapshot = (now, len(opened), json.dumps(viewers, sort_keys=True))
        if snapshot != last or time.time() - last_at > (5 if viewers else 10):
            body = {"event": "presence", "now": now, "opened": len(opened),
                    "people": len({ip for ip, _ in opened}),
                    "viewers_opened": sum(1 for _, role in opened if role == "view"),
                    "viewers": viewers, "tap": bool(UPSTREAM), "pin_gen": PIN_GEN, "pin_base": PIN_BASE,
                    "view_ok": bool(AUTH["view"] and os.environ.get("GATE_VIEW_LOGIN")),
                    "metrics": " | ".join(_metrics_seen)[:600], "machine": machine()}
            try:
                request = urllib.request.Request(REPORT_URL, data=json.dumps(body).encode(), method="PUT",
                                                 headers={"Content-Type": "application/json"})
                with urllib.request.urlopen(request, timeout=15) as response:
                    answer = json.loads(response.read(20000) or b"{}")
                last, last_at = snapshot, time.time()
                for viewer in answer.get("kick") or []:
                    if isinstance(viewer, str) and viewer:
                        kick(viewer)
                pins = answer.get("pins")
                if isinstance(pins, dict) and isinstance(pins.get("gen"), int):
                    if reset_pins(pins["gen"], str(pins.get("full") or ""), str(pins.get("view") or "")):
                        last = None
                        pin_hook(str(pins.get("full") or ""))
            except Exception:
                pass
        _changed.wait(5 if viewers else 10)
        _changed.clear()


def safe_next(path: str) -> str:
    if not path.startswith("/") or path.startswith("//") or "\\" in path or path.startswith("/__cb/"):
        return "/"
    return path[:2000]


def report(event: str, ip: str, browser: str, note: str = "") -> None:
    if not REPORT_URL:
        return

    def send() -> None:
        try:
            body = json.dumps({"event": event, "ip": ip, "browser": browser[:300], "note": note[:200]}).encode()
            request = urllib.request.Request(REPORT_URL, data=body, method="PUT",
                                             headers={"Content-Type": "application/json"})
            urllib.request.urlopen(request, timeout=15).close()
        except Exception:
            pass

    threading.Thread(target=send, daemon=True).start()


_countries: dict[str, tuple[bool, float]] = {}


IP_HEADER = os.environ.get("GATE_IP_HEADER", "").strip().lower()


def visitor_ip(cf_connecting: str, forwarded_for: str, real_ip: str = "") -> str:
    if IP_HEADER == "x-real-ip":
        return real_ip.strip()[:64]
    if cf_connecting.strip():
        return cf_connecting.strip()[:64]
    hops = [h.strip() for h in forwarded_for.split(",") if h.strip()]
    for hop in reversed(hops):
        if hop not in ("127.0.0.1", "::1"):
            return hop[:64]
    return ""


def country_allowed(ip: str, browser: str) -> bool | None:
    now = time.time()
    cached = _countries.get(ip)
    if cached and cached[1] > now:
        return cached[0]
    if not REPORT_URL:
        return None
    try:
        body = json.dumps({"event": "check", "ip": ip, "browser": browser[:300]}).encode()
        request = urllib.request.Request(REPORT_URL, data=body, method="PUT",
                                         headers={"Content-Type": "application/json"})
        with urllib.request.urlopen(request, timeout=10) as response:
            allowed = bool(json.loads(response.read(2000)).get("allow"))
    except Exception:
        return None
    _countries[ip] = (allowed, now + (600 if allowed else 60))
    return allowed


def wait_for(ip: str, now: float) -> int:
    if _locked_until > now:
        return int(_locked_until - now) + 1
    _, until = _per_ip.get(ip, (0, 0.0))
    return int(until - now) + 1 if until > now else 0


def wrong(ip: str, now: float) -> bool:
    global _locked_until
    count, _ = _per_ip.get(ip, (0, 0.0))
    count += 1
    _per_ip[ip] = (count, now + (0 if count < FREE_TRIES else min(MAX_WAIT, 2 ** (count - FREE_TRIES + 1))))
    _recent[:] = [t for t in _recent if now - t < 3600] + [now]
    if len(_recent) >= LOCK_AFTER:
        _locked_until = now + LOCK_SECONDS
        _recent.clear()
        return True
    return False


class Gate(BaseHTTPRequestHandler):
    server_version = "gate"
    sys_version = ""

    def log_message(self, format: str, *args) -> None:
        pass

    def client_ip(self) -> str:
        return visitor_ip(self.headers.get("CF-Connecting-IP") or "", self.headers.get("X-Forwarded-For") or "",
                          self.headers.get("X-Real-IP") or "") or self.client_address[0]

    def page(self, status: int, next_path: str, error: str = "") -> None:
        body = PAGE.replace("{next}", html.escape(next_path, quote=True)).replace("{error}", html.escape(error)).encode()
        self.send_response(status)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Frame-Options", "DENY")
        self.send_header("Content-Security-Policy",
                         f"default-src 'none'; style-src 'unsafe-inline'; script-src 'sha256-{PIN_SCRIPT_HASH}'; "
                         "form-action 'self'; frame-ancestors 'none'")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def not_found(self, status: int = 404) -> None:
        body = b"Not Found" if status == 404 else b"Service Unavailable"
        self.send_response(status)
        self.send_header("Content-Type", "text/plain; charset=utf-8")
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def self_check(self) -> bool:
        given = self.headers.get("X-Cb-Self") or ""
        expected = hmac.new(SECRET, b"self", hashlib.sha256).hexdigest()
        return bool(given) and bool(SECRET) and hmac.compare_digest(given, expected)

    def may_enter(self, ip: str) -> bool:
        if self.self_check():
            return True
        allowed = country_allowed(ip, self.headers.get("User-Agent") or "")
        if allowed is None:
            self.not_found(503)
            return False
        if not allowed:
            self.not_found()
            return False
        return True

    def cookie(self) -> dict | None:
        for part in (self.headers.get("Cookie") or "").split(";"):
            name, _, value = part.strip().partition("=")
            if name == COOKIE:
                data = valid("cookie", value)
                if data:
                    return data
        return None

    def device(self) -> str:
        for part in (self.headers.get("Cookie") or "").split(";"):
            name, _, value = part.strip().partition("=")
            if name == DEVICE:
                data = valid("device", value)
                if data and isinstance(data.get("vid"), str):
                    return data["vid"]
        return ""

    def cookie_ok(self) -> bool:
        return self.cookie() is not None

    def is_page_load(self) -> bool:
        mode = (self.headers.get("Sec-Fetch-Mode") or "").lower()
        dest = (self.headers.get("Sec-Fetch-Dest") or "").lower()
        if mode or dest:
            return mode == "navigate" and dest in {"document", ""}
        method = (self.headers.get("X-Forwarded-Method") or "GET").upper()
        return method == "GET" and (self.headers.get("Accept") or "").startswith("text/html")

    def authorized(self) -> bool:
        data = self.cookie()
        ip = self.client_ip()
        return (data is not None and hmac.compare_digest(str(data.get("ip", "")), ip)
                and int(data.get("gen") or 0) == PIN_GEN
                and not banned(str(data.get("vid") or ""), ip))

    def removed(self) -> bool:
        return (banned(str((self.cookie() or {}).get("vid") or ""), self.client_ip())
                or banned(self.device(), ""))

    def do_GET(self) -> None:
        if urlsplit(self.path).path == "/__cb/check" and self.authorized():
            self.send_response(200)
            auth = AUTH.get(str((self.cookie() or {}).get("role", "full"))) or AUTH["full"]
            if auth:
                self.send_header("X-Cb-Auth", auth)
            self.end_headers()
            return
        ip, now = self.client_ip(), time.time()
        if not self.may_enter(ip):
            return
        if not self.self_check() and now - _viewed.get(ip, 0) > 600:
            _viewed[ip] = now
            report("viewed", ip, self.headers.get("User-Agent") or "")
        self.page(401, safe_next(self.headers.get("X-Forwarded-Uri") or "/"),
                  REMOVED if self.removed() else "")

    do_HEAD = do_GET

    def do_POST(self) -> None:
        if urlsplit(self.path).path == "/__cb/scale":
            if self.authorized() and (self.cookie() or {}).get("role", "full") == "full":
                save_scale(urlsplit(self.path).query)
            self.send_response(204)
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            return
        if urlsplit(self.path).path != "/__cb/login":
            self.page(401, "/")
            return
        length = min(int(self.headers.get("Content-Length") or 0), 4096)
        form = parse_qs(self.rfile.read(length).decode(errors="replace"))
        given = (form.get("password") or [""])[0]
        next_path = safe_next((form.get("next") or ["/"])[0])
        ip, browser, now = self.client_ip(), self.headers.get("User-Agent") or "", time.time()
        if not self.may_enter(ip):
            return
        known = self.device()
        if banned(known, ip):
            report("failed", ip, browser, "removed by the owner, tried again")
            self.page(403, next_path, REMOVED)
            return
        name = " ".join((form.get("name") or [""])[0].split())[:40]
        with _lock:
            waiting = wait_for(ip, now)
            if waiting:
                report("blocked", ip, browser, f"wait {waiting} s")
                self.page(429, next_path, f"Too many wrong tries. Wait {waiting} seconds.")
                return
            role = role_of(given)
            if role is None:
                locked = wrong(ip, now)
                report("locked" if locked else "failed", ip, browser)
                left = max(0, FREE_TRIES - _per_ip[ip][0])
                if locked:
                    message = "Too many wrong tries: this desktop is locked for 30 minutes."
                elif left:
                    message = f"That is not right. {left} more {'try' if left == 1 else 'tries'} before a wait."
                else:
                    message = "That is not right. Wait before trying again."
                self.page(401, next_path, message)
                return
            _per_ip.pop(ip, None)
            _opened.append((ip, role))
        report("ok", ip, browser, ("watch only" if role == "view" else "") + (f" · {name}" if name else ""))
        exp = int(now) + COOKIE_SECONDS
        one_time = b64(os.urandom(12))
        viewer = known or b64(os.urandom(9))
        with _lock:
            _passes[one_time] = now + PASS_SECONDS
            _viewer_ips.setdefault(viewer, set()).add(ip)
        payload = b64(json.dumps({"exp": exp, "pass": one_time, "role": role, "ip": ip,
                                  "vid": viewer, "name": name, "gen": PIN_GEN}).encode())
        self.send_response(303)
        self.send_header("Set-Cookie", f"{COOKIE}={payload}.{sign('cookie', payload)}; Path=/; "
                                       f"Max-Age={COOKIE_SECONDS}; Secure; HttpOnly; SameSite=Lax")
        device = b64(json.dumps({"exp": int(now) + 30 * 86400, "vid": viewer}).encode())
        self.send_header("Set-Cookie", f"{DEVICE}={device}.{sign('device', device)}; Path=/; "
                                       f"Max-Age={30 * 86400}; Secure; HttpOnly; SameSite=Lax")
        self.send_header("Location", next_path)
        self.send_header("Cache-Control", "no-store")
        self.end_headers()


class Server(ThreadingHTTPServer):
    request_queue_size = 256
    daemon_threads = True

    def server_bind(self) -> None:
        import socketserver

        socketserver.TCPServer.server_bind(self)
        host, port = self.server_address[:2]
        self.server_name, self.server_port = str(host), port


def main() -> None:
    if not SECRET or not os.environ.get("GATE_LOGIN"):
        raise SystemExit("GATE_SECRET and GATE_LOGIN are needed")
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 9077
    bind = os.environ.get("GATE_BIND", "127.0.0.1")
    if UPSTREAM:
        threading.Thread(target=tap_server, args=(bind,), daemon=True).start()
    if REPORT_URL:
        threading.Thread(target=presence_loop, daemon=True).start()
    Server((bind, port), Gate).serve_forever()


if __name__ == "__main__":
    main()
