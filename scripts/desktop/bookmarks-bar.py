
from __future__ import annotations

import base64
import json
import os
import sqlite3
import struct
import sys
import time
import uuid
from pathlib import Path
from typing import Any

MARK = {"cb_import": "1"}
NAMESPACE = uuid.UUID("6b1c3a4e-2f0d-4f7e-9a51-0c8e5d2b7f31")
ROOTS = {"bookmark_bar": ("0bc5d13f-2cba-5d74-951f-3f233fe6c908", "Bookmarks bar", "1"),
         "other": ("82b081ec-3dd3-529c-8475-ab6c344590dd", "Other bookmarks", "2"),
         "synced": ("4cf2e351-0e85-532b-bb37-df045d8f8d0f", "Mobile bookmarks", "3")}


def now() -> str:
    return str(int((time.time() + 11644473600) * 1_000_000))


def tree_of(stored: dict[str, Any]) -> list[dict[str, Any]]:
    if isinstance(stored.get("bar"), list):
        return stored["bar"]
    return [n for n in stored.get("ManagedBookmarks", []) if "toplevel_name" not in n]


def split(tree: list[dict[str, Any]]) -> tuple[list[dict[str, Any]], list[dict[str, Any]]]:
    bar = next((n for n in tree if n.get("toolbar")), None)
    bar = bar or next((n for n in tree if "children" in n and n["name"].lower() in ("bookmarks bar", "favorites bar")), None)
    if bar is None:
        return tree, []
    return bar["children"], [n for n in tree if n is not bar]


class Ids:
    def __init__(self, start: int) -> None:
        self.next = start

    def take(self) -> str:
        self.next += 1
        return str(self.next)


def node(item: dict[str, Any], path: str, ids: Ids, stamp: str, top: bool) -> dict[str, Any]:
    key = f"{path}/{item['name']}|{item.get('url', '')}"
    out: dict[str, Any] = {"date_added": stamp, "date_last_used": "0", "guid": str(uuid.uuid5(NAMESPACE, key)),
                           "id": ids.take(), "name": item["name"]}
    if top:
        out["meta_info"] = dict(MARK)
    if "url" in item:
        out.update(type="url", url=item["url"])
    else:
        out.update(type="folder", date_modified=stamp,
                   children=[node(c, f"{path}/{item['name']}", ids, stamp, False) for c in item.get("children", [])])
    return out


def max_id(nodes: list[dict[str, Any]]) -> int:
    best = 0
    for n in nodes:
        try:
            best = max(best, int(n.get("id", 0)))
        except (TypeError, ValueError):
            pass
        best = max(best, max_id(n.get("children", [])))
    return best


def empty_root(name: str) -> dict[str, Any]:
    guid, title, rid = ROOTS[name]
    return {"children": [], "date_added": now(), "date_modified": "0", "guid": guid, "id": rid, "name": title,
            "type": "folder"}


def place(profile: Path, tree: list[dict[str, Any]]) -> tuple[int, int]:
    path = profile / "Bookmarks"
    data: dict[str, Any] = {"roots": {}, "version": 1}
    if path.exists():
        try:
            data = json.loads(path.read_text(encoding="utf-8"))
        except ValueError:
            pass
    roots = data.setdefault("roots", {})
    for name in ROOTS:
        roots.setdefault(name, empty_root(name))
    for name in ("bookmark_bar", "other"):
        roots[name]["children"] = [n for n in roots[name].get("children", []) if n.get("meta_info") != MARK]
    ids = Ids(max(3, *(max_id([roots[r]]) for r in ROOTS)))
    stamp = now()
    on_bar, other = split(tree)
    roots["bookmark_bar"]["children"] = [node(i, "bar", ids, stamp, True) for i in on_bar] + roots["bookmark_bar"]["children"]
    roots["other"]["children"] += [node(i, "other", ids, stamp, True) for i in other]
    data.pop("checksum", None)
    profile.mkdir(parents=True, exist_ok=True)
    temp = path.with_suffix(".cb-new")
    temp.write_text(json.dumps(data, indent=3, ensure_ascii=False), encoding="utf-8")
    os.replace(temp, path)
    return len(on_bar), len(other)


def png_size(data: bytes) -> tuple[int, int]:
    if data[:8] == b"\x89PNG\r\n\x1a\n" and len(data) >= 24:
        return struct.unpack(">II", data[16:24])
    return 16, 16


def icons(profile: Path, tree: list[dict[str, Any]]) -> int:
    store = profile / "Favicons"
    if not store.exists():
        return 0
    found: list[tuple[str, bytes]] = []

    def walk(nodes: list[dict[str, Any]]) -> None:
        for n in nodes:
            if "url" in n and str(n.get("icon", "")).startswith("data:image/png;base64,"):
                try:
                    found.append((n["url"], base64.b64decode(n["icon"].split(",", 1)[1])))
                except ValueError:
                    pass
            walk(n.get("children", []))

    walk(tree)
    added = 0
    stamp = int(now())
    with sqlite3.connect(store, timeout=10) as db:
        for url, image in found:
            if db.execute("SELECT 1 FROM icon_mapping WHERE page_url = ?", (url,)).fetchone():
                continue
            width, height = png_size(image)
            origin = url.split("/", 3)
            icon_url = "/".join(origin[:3]) + "/favicon.ico" if len(origin) >= 3 else url
            row = db.execute("SELECT id FROM favicons WHERE url = ?", (icon_url,)).fetchone()
            icon_id = row[0] if row else db.execute("INSERT INTO favicons (url, icon_type) VALUES (?, 1)", (icon_url,)).lastrowid
            if not row:
                db.execute("INSERT INTO favicon_bitmaps (icon_id, last_updated, image_data, width, height, last_requested) "
                           "VALUES (?, ?, ?, ?, ?, 0)", (icon_id, stamp, image, width, height))
            db.execute("INSERT INTO icon_mapping (page_url, icon_id) VALUES (?, ?)", (url, icon_id))
            added += 1
    return added


def main() -> None:
    profile, source = Path(sys.argv[1]), Path(sys.argv[2])
    tree = tree_of(json.loads(source.read_text(encoding="utf-8")))
    if not tree:
        print("bookmarks: none stored")
        return
    on_bar, other = place(profile, tree)
    try:
        with_icons = icons(profile, tree)
    except sqlite3.Error as error:
        with_icons = 0
        print(f"bookmarks: icons not added ({error})")
    print(f"bookmarks: {on_bar} on the bar, {other} under Other bookmarks, {with_icons} icons added")


if __name__ == "__main__":
    main()
