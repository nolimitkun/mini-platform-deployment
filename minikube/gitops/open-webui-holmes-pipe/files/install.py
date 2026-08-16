import json
import os
import sqlite3
import time


FUNCTION_ID = "holmesgpt"
DATABASE = os.environ["OPEN_WEBUI_DATABASE"]
SOURCE = open("/provision/holmesgpt.py", encoding="utf-8").read()
META = {
    "description": "Kubernetes investigation agent backed directly by HolmesGPT",
    "manifest": {
        "title": "HolmesGPT",
        "description": "Kubernetes investigation agent backed directly by HolmesGPT",
        "author": "mini-platform",
        "version": "0.1.0",
    },
}


def wait_for_database():
    deadline = time.time() + 600
    while time.time() < deadline:
        try:
            connection = sqlite3.connect(DATABASE, timeout=30)
            tables = {
                row[0]
                for row in connection.execute(
                    "SELECT name FROM sqlite_master WHERE type = 'table'"
                )
            }
            if {"function", "user", "api_key"}.issubset(tables):
                return connection
            connection.close()
        except sqlite3.Error:
            pass
        time.sleep(5)
    raise RuntimeError("Open WebUI database migrations did not become ready")


connection = wait_for_database()
admin = connection.execute(
    "SELECT id FROM user WHERE role = 'admin' ORDER BY created_at LIMIT 1"
).fetchone()
if admin is None:
    raise RuntimeError("Open WebUI has no admin user to own the HolmesGPT Pipe")

now = int(time.time())
connection.execute(
    """
    INSERT INTO function (
        id, user_id, name, type, content, meta, created_at, updated_at,
        valves, is_active, is_global
    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, NULL, 1, 0)
    ON CONFLICT(id) DO UPDATE SET
        name = excluded.name,
        type = excluded.type,
        content = excluded.content,
        meta = excluded.meta,
        updated_at = excluded.updated_at,
        is_active = 1
    """,
    (
        FUNCTION_ID,
        admin[0],
        "HolmesGPT",
        "pipe",
        SOURCE,
        json.dumps(META),
        now,
        now,
    ),
)
connection.commit()
connection.close()
print("Provisioned HolmesGPT Pipe (active=1)")
