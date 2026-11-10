
from __future__ import annotations

import shutil
import sqlite3
import sys
from pathlib import Path

TABLES = {
    "Cookies": ("cookies", ("host_key", "name", "path", "top_frame_site_key"), "last_update_utc"),
    "Login Data": ("logins", ("origin_url", "username_element", "username_value", "password_element",
                              "signon_realm"), "date_password_modified"),
    "Login Data For Account": ("logins", ("origin_url", "username_element", "username_value",
                                          "password_element", "signon_realm"), "date_password_modified"),
}


def columns(db: sqlite3.Connection, schema: str, table: str) -> list[str]:
    return [row[1] for row in db.execute(f'PRAGMA {schema}.table_info("{table}")')]


def merge(target: Path, newer: Path) -> tuple[int, int]:
    table, key, stamp = TABLES[target.name]
    db = sqlite3.connect(target)
    try:
        db.execute("ATTACH DATABASE ? AS newer", (str(newer),))
        mine, theirs = columns(db, "main", table), columns(db, "newer", table)
        if not mine or not theirs:
            return 0, 0
        shared = [c for c in mine if c in theirs]
        key = tuple(c for c in key if c in shared)
        if not key or stamp not in shared:
            return 0, 0
        cols = ", ".join(f'"{c}"' for c in shared)
        match = " AND ".join(f'm."{c}" IS n."{c}"' for c in key)
        added = db.execute(
            f'INSERT INTO main."{table}" ({cols}) SELECT {cols} FROM newer."{table}" n '
            f'WHERE NOT EXISTS (SELECT 1 FROM main."{table}" m WHERE {match})').rowcount
        stale = db.execute(
            f'SELECT m.rowid FROM main."{table}" m JOIN newer."{table}" n ON {match} '
            f'WHERE n."{stamp}" > m."{stamp}"').fetchall()
        replaced = 0
        for (rowid,) in stale:
            row = db.execute(f'SELECT {", ".join(chr(34) + c + chr(34) for c in key)} FROM main."{table}" WHERE rowid = ?',
                             (rowid,)).fetchone()
            db.execute(f'DELETE FROM main."{table}" WHERE rowid = ?', (rowid,))
            where = " AND ".join(f'n."{c}" IS ?' for c in key)
            db.execute(f'INSERT INTO main."{table}" ({cols}) SELECT {cols} FROM newer."{table}" n WHERE {where}', row)
            replaced += 1
        db.commit()
        return added, replaced
    finally:
        db.close()


def main() -> int:
    target_root, newer_root = Path(sys.argv[1]), Path(sys.argv[2])
    for newer in newer_root.rglob("*"):
        if not newer.is_file() or newer.name not in TABLES:
            continue
        target = target_root / newer.relative_to(newer_root)
        try:
            if not target.exists():
                target.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(newer, target)
                print(f"Sign-ins: {newer.relative_to(newer_root)} taken from the newer save.")
                continue
            added, replaced = merge(target, newer)
            print(f"Sign-ins: {newer.relative_to(newer_root)}: {added} added, {replaced} newer kept.")
        except sqlite3.Error as error:
            print(f"Sign-ins: {newer.relative_to(newer_root)} not merged ({error}).", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
