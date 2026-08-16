import json
import os
import secrets
import sqlite3
import time
import urllib.error
import urllib.request


FUNCTION_ID = "holmesgpt"
DATABASE = os.environ["OPEN_WEBUI_DATABASE"]
BASE_URL = os.environ["OPEN_WEBUI_URL"].rstrip("/")
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


def api(method, path, token, body=None):
    data = json.dumps(body).encode() if body is not None else None
    request = urllib.request.Request(
        BASE_URL + path,
        data=data,
        method=method,
        headers={
            "Authorization": f"Bearer {token}",
            "Content-Type": "application/json",
        },
    )
    with urllib.request.urlopen(request, timeout=60) as response:
        return json.load(response)


def wait_for_api():
    deadline = time.time() + 600
    while time.time() < deadline:
        try:
            with urllib.request.urlopen(BASE_URL + "/health", timeout=10) as response:
                if response.status == 200:
                    return
        except (urllib.error.URLError, TimeoutError):
            pass
        time.sleep(5)
    raise RuntimeError("Open WebUI API did not become ready")


connection = wait_for_database()
wait_for_api()
admin = connection.execute(
    "SELECT id FROM user WHERE role = 'admin' ORDER BY created_at LIMIT 1"
).fetchone()
if admin is None:
    raise RuntimeError("Open WebUI has no admin user to own the HolmesGPT Pipe")

key_id = "holmes_pipe_" + secrets.token_hex(12)
token = "sk-" + secrets.token_hex(24)
now = int(time.time())
connection.execute(
    "INSERT INTO api_key (id, user_id, key, created_at, updated_at) VALUES (?, ?, ?, ?, ?)",
    (key_id, admin[0], token, now, now),
)
connection.commit()

form = {"id": FUNCTION_ID, "name": "HolmesGPT", "content": SOURCE, "meta": META}
try:
    try:
        current = api("GET", f"/api/v1/functions/id/{FUNCTION_ID}", token)
        result = api(
            "POST", f"/api/v1/functions/id/{FUNCTION_ID}/update", token, form
        )
    except urllib.error.HTTPError as error:
        if error.code not in (401, 404):
            raise
        current = None
        result = api("POST", "/api/v1/functions/create", token, form)

    if not result.get("is_active"):
        result = api(
            "POST", f"/api/v1/functions/id/{FUNCTION_ID}/toggle", token, {}
        )
    print(f"Provisioned {result['name']} Pipe (active={result['is_active']})")
finally:
    connection.execute("DELETE FROM api_key WHERE id = ?", (key_id,))
    connection.commit()
    connection.close()
