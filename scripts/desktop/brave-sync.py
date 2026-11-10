
from __future__ import annotations

import base64
import json
import os
import socket
import struct
import sys
import time
import urllib.request

PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 9333
CODE_FILE = sys.argv[2] if len(sys.argv) > 2 else ""


def http(method: str, path: str) -> dict:
    request = urllib.request.Request(f"http://127.0.0.1:{PORT}{path}", method=method)
    with urllib.request.urlopen(request, timeout=10) as reply:
        return json.loads(reply.read() or b"{}")


class Socket:

    def __init__(self, url: str) -> None:
        rest = url.split("://", 1)[1]
        hostport, _, path = rest.partition("/")
        host, _, port = hostport.partition(":")
        self.sock = socket.create_connection((host, int(port or 80)), timeout=120)
        key = base64.b64encode(os.urandom(16)).decode()
        self.sock.sendall((f"GET /{path} HTTP/1.1\r\nHost: {hostport}\r\nUpgrade: websocket\r\n"
                           f"Connection: Upgrade\r\nSec-WebSocket-Key: {key}\r\nSec-WebSocket-Version: 13\r\n\r\n").encode())
        head = b""
        while b"\r\n\r\n" not in head:
            chunk = self.sock.recv(1)
            if not chunk:
                raise ConnectionError("DevTools closed the connection")
            head += chunk
        if b" 101 " not in head.split(b"\r\n", 1)[0]:
            raise ConnectionError(head.split(b"\r\n", 1)[0].decode(errors="replace"))
        self.next_id = 0

    def _read(self, n: int) -> bytes:
        data = b""
        while len(data) < n:
            chunk = self.sock.recv(n - len(data))
            if not chunk:
                raise ConnectionError("DevTools closed the connection")
            data += chunk
        return data

    def send(self, text: str) -> None:
        payload = text.encode()
        head = bytes([0x81])
        n = len(payload)
        head += bytes([0x80 | n]) if n < 126 else (bytes([0x80 | 126]) + struct.pack(">H", n) if n < 65536
                                                   else bytes([0x80 | 127]) + struct.pack(">Q", n))
        mask = os.urandom(4)
        self.sock.sendall(head + mask + bytes(b ^ mask[i % 4] for i, b in enumerate(payload)))

    def receive(self) -> str:
        message = b""
        while True:
            first, second = self._read(2)
            n = second & 0x7F
            if n == 126:
                n = struct.unpack(">H", self._read(2))[0]
            elif n == 127:
                n = struct.unpack(">Q", self._read(8))[0]
            data = self._read(n)
            if first & 0x0F == 0x8:
                raise ConnectionError("DevTools closed the page")
            if first & 0x0F in (0x9, 0xA):
                continue
            message += data
            if first & 0x80:
                return message.decode(errors="replace")

    def call(self, method: str, params: dict) -> dict:
        self.next_id += 1
        self.send(json.dumps({"id": self.next_id, "method": method, "params": params}))
        while True:
            reply = json.loads(self.receive())
            if reply.get("id") == self.next_id:
                return reply


SCRIPT = r"""
(async (code) => {
  const {sendWithPromise} = await import('chrome://resources/js/cr.js');
  const out = {};
  // Brave's own view of Sync, before anything here, for the report: a seed
  // it could not decrypt shows as an error here, not in the device list.
  const syncStatus = async () => {
    try {
      const s = await sendWithPromise('SyncSetupGetSyncStatus');
      return s && typeof s === 'object'
        ? {hasError: !!s.hasError, disabled: !!s.disabled, text: String(s.statusText || s.statusAction || '').slice(0, 160)}
        : null;
    } catch (e) { return {error: String(e && e.message || e).slice(0, 160)}; }
  };
  out.status_before = await syncStatus();
  let devices = [];
  try { devices = await sendWithPromise('SyncGetDeviceList'); } catch (e) {}
  out.devices = (devices || []).length;
  let inChain = (devices || []).some((d) => d.isCurrentDevice);
  const words = (text) => String(text || '').trim().split(/\s+/).slice(0, 24).join(' ');
  if (inChain && code) {
    let current = '';
    try { current = await sendWithPromise('SyncSetupGetSyncCode'); } catch (e) {}
    if (!current) {
      // In a chain by its device list, but Brave cannot read its own Sync
      // seed (it was locked with another machine's key): Brave then says "Sync
      // service could not be started" and Sync never runs. Brave's own fix is
      // to reset and join again; today's code puts it back in your chain.
      try { await sendWithPromise('SyncSetupReset'); } catch (e) { chrome.send('SyncSetupReset'); }
      await new Promise((r) => setTimeout(r, 4000));
      out.own_code_unreadable = true;
      inChain = false;
    } else if (words(current) !== words(code)) {
      // In a chain, but another one (an older code, or one made on this
      // machine): its code's 24 words are not yours, so this desktop leaves
      // it (its data stays) and joins yours, the one every desktop is in.
      try { await sendWithPromise('SyncSetupReset'); } catch (e) { chrome.send('SyncSetupReset'); }
      await new Promise((r) => setTimeout(r, 4000));
      out.left_other_chain = true;
      inChain = false;
    }
  }
  if (!inChain) {
    if (!code) return {...out, error: 'no code to join with'};
    try { await sendWithPromise('SyncSetupSetSyncCode', code); out.joined = true; }
    catch (e) { return {...out, error: 'join refused: ' + String(e && e.message || e)}; }
  } else {
    out.already = true;
  }
  // Sync everything, the way Brave's own page asks: its current settings,
  // every "...Synced" flag it has turned on. Chromium's handler CHECKs that
  // every flag it knows is present and crashes Brave otherwise, so a list
  // written here (which missed some) made Brave quit; nothing is guessed.
  try {
    const {addWebUiListener} = await import('chrome://resources/js/cr.js');
    // Brave answers only once its sync engine is up (seconds after a join
    // or a start), so it is asked again every 2 seconds, for up to a minute.
    const prefs = await new Promise((resolve) => {
      addWebUiListener('sync-prefs-changed', resolve);
      const ask = () => { try { chrome.send('SyncSetupShowSetupUI'); } catch (e) {} chrome.send('SyncPrefsDispatch'); };
      ask();
      const again = setInterval(ask, 2000);
      setTimeout(() => { clearInterval(again); resolve(null); }, 60000);
    });
    if (prefs && typeof prefs === 'object') {
      const all = {...prefs, syncAllDataTypes: true};
      for (const key of Object.keys(all)) {
        if (!key.endsWith('Synced')) continue;
        const type = key.slice(0, -'Synced'.length);
        if (all[type + 'Managed'] !== true && all[type + 'Registered'] !== false) all[key] = true;
      }
      await sendWithPromise('SyncSetupSetDatatypes', JSON.stringify(all));
      out.everything = true;
    } else {
      out.types_error = 'Brave gave no sync settings; types left as Brave set them';
    }
  } catch (e) { out.types_error = String(e && e.message || e); }
  // The other devices show once the first sync has run: asked again after 30 s.
  await new Promise((r) => setTimeout(r, 30000));
  try {
    const now = await sendWithPromise('SyncGetDeviceList');
    out.devices_now = (now || []).length;
    out.device_names = (now || []).map((d) => String(d.name || '?').slice(0, 40)).slice(0, 12);
  } catch (e) {}
  out.status_after = await syncStatus();
  return out;
})
"""


SEARCH = r"""
(async () => {
  const {sendWithPromise} = await import('chrome://resources/js/cr.js');
  const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
  const isGoogle = (e) => e.keyword === ':g' || e.keyword === 'google.com' || /^google$/i.test(e.name || '');
  const current = async () => {
    const l = await sendWithPromise('getSearchEnginesList');
    return [...(l.defaults || []), ...(l.actives || []), ...(l.others || [])].find((e) => e.default);
  };
  const now = await current();
  if (now && isGoogle(now)) return {search: now.name, already: true};
  if (now && now.isManaged) return {search: now.name, managed: true};
  // The page's own engine rows, each with its "Make default" (onMakeDefaultClick_):
  // pressed as Settings presses it. Sent to Brave directly instead, the same
  // message made Brave quit or did nothing (2026-10-22).
  const rows = () => {
    const found = [];
    const walk = (n) => {
      if (!n) return;
      if (n.engine && typeof n.onMakeDefaultClick_ === 'function') found.push(n);
      if (n.shadowRoot) walk(n.shadowRoot);
      for (const c of n.children || []) walk(c);
    };
    walk(document.documentElement);
    return found;
  };
  let google;
  for (let i = 0; i < 20 && !google; i++) {
    google = rows().find((r) => r.engine.keyword === ':g' && r.engine.canBeDefault)
          || rows().find((r) => isGoogle(r.engine) && r.engine.canBeDefault);
    if (!google) await sleep(500);
  }
  // A restored profile can list Brave Search alone: Google is added first, as
  // Settings' "Add" does (a new engine: index -1; name, keyword, URL).
  if (!google) {
    chrome.send('searchEngineEditStarted', [-1]);
    chrome.send('searchEngineEditCompleted', ['Google', 'google.com', 'https://www.google.com/search?q=%s']);
    for (let i = 0; i < 20 && !google; i++) {
      await sleep(500);
      google = rows().find((r) => isGoogle(r.engine) && r.engine.canBeDefault);
    }
  }
  if (!google) return {search_error: 'Brave lists no Google'};
  try { google.onMakeDefaultClick_(); } catch (e) { return {search_error: String(e).slice(0, 200)}; }
  await sleep(1500);
  const after = await current();
  return {search: after ? after.name : ''};
})()
"""


def run_on(url: str, expression: str) -> dict:
    target = http("PUT", f"/json/new?{url}")
    try:
        page = Socket(target["webSocketDebuggerUrl"])
        time.sleep(3)
        reply = page.call("Runtime.evaluate", {"expression": expression, "awaitPromise": True, "returnByValue": True})
        return ((reply.get("result") or {}).get("result") or {}).get("value") or {"error": json.dumps(reply)[:300]}
    finally:
        try:
            http("GET", f"/json/close/{target['id']}")
        except Exception:
            pass


def main() -> int:
    code = ""
    if CODE_FILE and os.path.exists(CODE_FILE):
        with open(CODE_FILE, encoding="utf-8") as handle:
            code = " ".join(handle.read().split())
    for _ in range(90):
        try:
            http("GET", "/json/version")
            break
        except Exception:
            time.sleep(2)
    else:
        print(json.dumps({"error": "Brave's DevTools did not answer"}))
        return 1
    try:
        search = run_on("brave://settings/searchEngines", SEARCH)
    except Exception as error:
        search = {"search_error": str(error)[:200]}
    if not code:
        print(json.dumps(search))
        return 0
    result = {**search, **run_on("brave://settings/braveSync", f"{SCRIPT}({json.dumps(code)})")}
    if not result.get("error"):
        try:
            os.remove(CODE_FILE)
        except OSError:
            pass
    print(json.dumps(result))
    return 0 if not result.get("error") else 1


if __name__ == "__main__":
    sys.exit(main())
