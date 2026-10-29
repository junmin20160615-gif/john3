# SPDX-License-Identifier: Apache-2.0
"""SQLite claim before POST, atomic audio receipt after POST. No expiring paid-request lease."""
from __future__ import annotations

from contextlib import closing
import hashlib
import json
from pathlib import Path
import sqlite3


def digest(document):
    return hashlib.sha256(json.dumps(document, sort_keys=True, separators=(',', ':'), allow_nan=False).encode()).hexdigest()


def obtain(path, document, make, *, prepare=None):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    key = digest(document)
    with closing(sqlite3.connect(path, timeout=30)) as db:
        db.execute('CREATE TABLE IF NOT EXISTS audio (id TEXT PRIMARY KEY, audio BLOB, metadata TEXT)')
        # The committed NULL receipt is a durable in-flight/unknown outcome. Another process,
        # a crash or a timeout cannot turn it into an automatic second purchase.
        with db:
            db.execute('BEGIN IMMEDIATE')
            row = db.execute('SELECT audio, metadata FROM audio WHERE id=?', (key,)).fetchone()
            if row is not None:
                if row[0] is None:
                    raise ValueError(f'sound request {key} is unresolved (in progress or failed); inspect the provider request before any new purchase')
                return bytes(row[0]), json.loads(row[1]), True
            if prepare is not None:
                prepare()
            db.execute('INSERT INTO audio(id) VALUES (?)', (key,))
        audio, metadata = make()
        with db:
            db.execute('UPDATE audio SET audio=?, metadata=? WHERE id=?',
                       (audio, json.dumps(metadata, allow_nan=False), key))
        return audio, metadata, False
