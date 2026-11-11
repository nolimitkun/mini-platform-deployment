#!/usr/bin/env python3
"""Replay recent gateway decisions against the policy in this checkout.

    python3 scripts/policy-replay.py                 last 24h, up to 2000 decisions
    python3 scripts/policy-replay.py --since 7d --limit 5000
    python3 scripts/policy-replay.py --loki http://localhost:3100   (no port-forward)

Reads OPA's decision log from Loki (OPA logs every decision to stdout, Alloy
ships it), evaluates each logged input with the Rego and data in
policies/gateway and policies/gateway-projects as they are now, and compares
the verdict with the one OPA gave. Run it before merging a policy or project
change: every flipped verdict is a request that would now be treated
differently. Exit code 1 if any verdict flips.

Decisions logged before log_mask.rego kept the model and MCP tool name (the
whole body was dropped then) can't be replayed and are skipped, as are
decisions for other rules than --rule.

Needs kubectl access to the cluster (it port-forwards svc/loki) unless --loki
is given, and opa on PATH.
"""

import argparse
import contextlib
import json
import shutil
import socket
import subprocess
import sys
import tempfile
import time
import urllib.parse
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
BUNDLES = [ROOT / "policies" / "gateway", ROOT / "policies" / "gateway-projects"]
NAMESPACE = "mini-platform"
QUERY = '{namespace="%s", container="opa"} |= "decision_id"' % NAMESPACE


@contextlib.contextmanager
def loki_url(given):
    if given:
        yield given.rstrip("/")
        return
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        port = s.getsockname()[1]
    pf = subprocess.Popen(
        ["kubectl", "-n", NAMESPACE, "port-forward", "svc/loki", f"{port}:3100"],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    url = f"http://127.0.0.1:{port}"
    try:
        for _ in range(50):
            try:
                urllib.request.urlopen(url + "/ready", timeout=1)
                break
            except OSError:
                time.sleep(0.2)
        else:
            sys.exit("Loki did not answer through kubectl port-forward")
        yield url
    finally:
        pf.terminate()


def fetch(url, since, limit):
    params = urllib.parse.urlencode({"query": QUERY, "since": since, "limit": limit, "direction": "backward"})
    with urllib.request.urlopen(f"{url}/loki/api/v1/query_range?{params}", timeout=60) as r:
        body = json.load(r)
    for stream in body["data"]["result"]:
        for _, line in stream["values"]:
            try:
                yield json.loads(line)
            except json.JSONDecodeError:
                continue


def evaluate(inputs, rule):
    """One opa eval for all inputs: data.replay is the list of inputs."""
    query = f"[d | some x in data.replay; d := data.{rule.replace('/', '.')} with input as x]"
    with tempfile.TemporaryDirectory() as tmp:
        replay = Path(tmp) / "replay.json"
        replay.write_text(json.dumps({"replay": inputs}))
        args = ["opa", "eval", "--format", "json", "-d", str(replay)]
        for b in BUNDLES:
            args += ["-d", str(b)]
        out = subprocess.run(args + [query], capture_output=True, text=True)
    if out.returncode != 0:
        sys.exit(f"opa eval failed:\n{out.stdout}{out.stderr}")
    return json.loads(out.stdout)["result"][0]["expressions"][0]["value"]


def describe(event):
    i = event["input"]
    meta = i.get("attributes", {}).get("metadataContext", {}).get("filterMetadata", {}).get("agentgateway", {})
    body = i.get("parsed_body") or {}
    what = body.get("model") or body.get("params", {}).get("name") or body.get("method") or ""
    path = i.get("attributes", {}).get("request", {}).get("http", {}).get("path", "")
    return f"{event.get('time', '')} project={meta.get('project', '?')} {path} {what}".rstrip()


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--since", default="24h", help="how far back to read the decision log (Loki duration)")
    parser.add_argument("--limit", type=int, default=2000, help="most recent decisions to replay")
    parser.add_argument("--rule", default="gateway/authz/decision", help="decision path to replay")
    parser.add_argument("--loki", help="Loki base URL; default: kubectl port-forward svc/loki")
    parser.add_argument("--show", type=int, default=10, help="flipped decisions to print per direction")
    args = parser.parse_args()
    if not shutil.which("opa"):
        sys.exit("opa not found on PATH")

    with loki_url(args.loki) as url:
        events = list(fetch(url, args.since, args.limit))

    replayable, skipped_rule, skipped_old = [], 0, 0
    for e in events:
        if e.get("path") != args.rule or "input" not in e or "result" not in e:
            skipped_rule += 1
        elif "/input/parsed_body" in (e.get("erased") or []):
            skipped_old += 1
        else:
            replayable.append(e)

    print(f"read {len(events)} decisions; replaying {len(replayable)} "
          f"(skipped: {skipped_rule} other rules, {skipped_old} logged before the model was kept)")
    if not replayable:
        return 0

    now = evaluate([e["input"] for e in replayable], args.rule)
    now_denied, now_allowed, changed = [], [], 0
    for e, new in zip(replayable, now):
        before, after = bool(e["result"].get("allowed")), bool(new.get("allowed"))
        if before and not after:
            now_denied.append((e, new))
        elif after and not before:
            now_allowed.append((e, new))
        elif new != e["result"]:
            changed += 1

    print(f"allowed before, denied now: {len(now_denied)}")
    for e, new in now_denied[: args.show]:
        print(f"  {describe(e)}  -> {new.get('body') or new.get('http_status', '')}")
    print(f"denied before, allowed now: {len(now_allowed)}")
    for e, _ in now_allowed[: args.show]:
        print(f"  {describe(e)}")
    print(f"same verdict, different headers or body: {changed}")
    return 1 if now_denied or now_allowed else 0


if __name__ == "__main__":
    sys.exit(main())
