import base64
import http.cookiejar
import json
import os
import ssl
import sys
import threading
import time
import urllib.request

VIEWER = "http://127.0.0.1:8080/api"
SUNSHINE = "https://127.0.0.1:47990/api"
USER = "owner"
DEFAULT_SETTINGS = {
    "dataTransport": "websocket",
    "videoCodec": "h264",
    "videoSize": "native",
    "videoSizeCustom": {"width": 1920, "height": 1080},
    "fps": 60,
    "bitrate": 20000,
    "sidebarEdge": "left",
}


def pair() -> None:
    password = os.environ["VIEWER_PASSWORD"]
    jar = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(http.cookiejar.CookieJar()))

    def viewer(path: str, body: dict | None = None):
        request = urllib.request.Request(
            VIEWER + path, data=None if body is None else json.dumps(body).encode(),
            headers={"Content-Type": "application/json"}, method="GET" if body is None else "POST")
        return jar.open(request, timeout=90)

    tls = ssl._create_unverified_context()
    auth = "Basic " + base64.b64encode(f"{USER}:{os.environ['SUNSHINE_PASSWORD']}".encode()).decode()

    def sunshine(method: str, path: str, body: dict | None = None) -> dict:
        request = urllib.request.Request(
            SUNSHINE + path, data=None if body is None else json.dumps(body).encode(),
            headers={"Content-Type": "application/json", "Authorization": auth}, method=method)
        return json.load(urllib.request.urlopen(request, context=tls, timeout=90))

    viewer("/login", {"name": USER, "password": password})
    host = json.load(viewer("/host", {"address": "127.0.0.1", "http_port": 47989}))
    host = host.get("host", host)
    host_id = host["host_id"]
    if host.get("paired") != "Paired":
        reply = viewer("/pair", {"host_id": host_id})
        pin = json.loads(reply.readline())["Pin"]
        pending = []
        for _ in range(60):
            pending = sunshine("GET", "/pin").get("pairings", [])
            if pending:
                break
            time.sleep(1)
        if not pending:
            sys.exit("Sunshine never saw the pairing request")
        answer: dict = {}
        submit = threading.Thread(target=lambda: answer.update(sunshine(
            "POST", "/pin", {"pairing_id": pending[0]["id"], "pin": pin, "name": "Compute Base"})))
        submit.start()
        result = reply.readline().decode().strip()
        submit.join(60)
        if "Paired" not in result:
            sys.exit(f"Pairing failed: viewer {result[:200]}, Sunshine {answer}")
    apps = json.load(viewer(f"/apps?host_id={host_id}")).get("apps", [])
    desktop = next((a for a in apps if a.get("title") == "Desktop"), None)
    if not desktop:
        sys.exit(f"Sunshine offers no Desktop app: {apps}")
    print(json.dumps({"host_id": host_id, "app_id": desktop["app_id"]}))


def configure() -> None:
    data_file, config_file = "server/data.json", "server/config.json"
    settings = {**DEFAULT_SETTINGS, "videoSizeCustom": {
        "width": int(os.environ.get("VIDEO_WIDTH", 1920)), "height": int(os.environ.get("VIDEO_HEIGHT", 1080))}}
    fixed = os.environ.get("VIEWER_SIZE", "").split()
    if len(fixed) == 2 and all(n.isdigit() for n in fixed):
        settings["videoSize"] = "custom"
        settings["videoSizeCustom"] = {"width": int(fixed[0]), "height": int(fixed[1])}
    if os.environ.get("VIEWER_BITRATE", "").isdigit():
        settings["bitrate"] = int(os.environ["VIEWER_BITRATE"])
    data = json.load(open(data_file))
    user_id = next(iter(data["users"]))
    for role in data.get("roles", {}).values():
        role["default_settings"] = {**(role.get("default_settings") or {}), **settings}
    json.dump(data, open(data_file, "w"), indent=2)
    config = json.load(open(config_file))
    web = config.setdefault("web_server", {})
    web["bind_address"] = "127.0.0.1:8080"
    web["default_user_id"] = int(user_id) if str(user_id).isdigit() else user_id
    config["default_settings"] = settings
    json.dump(config, open(config_file, "w"), indent=2)


if __name__ == "__main__":
    {"pair": pair, "configure": configure}[sys.argv[1]]()
