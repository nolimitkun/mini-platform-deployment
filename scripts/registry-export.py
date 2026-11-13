#!/usr/bin/env python3
"""Write the project registry's records back to projects/ and agents/ in this repo.

    REGISTRY_TOKEN=... python3 scripts/registry-export.py [--url http://127.0.0.1:8080]

Since the registry imported them, projects, agents and exceptions change in the
registry (docs/project-registry.md), and OPA gets them from its publisher. These
files are its mirror in Git, still read for what the registry doesn't do yet:
the API keys bootstrap-vault-secrets.sh creates (key ids), the agentregistry
catalog, a disaster recovery copy. Run this, review the diff, open a PR.

Reads GET /export (a Keycloak token for the registry's client, as for any API
call; see "Using it" in the doc). A file is rewritten only if its record changed,
so unchanged files keep their comments; a file whose record is gone is deleted.
Then runs gen-projects.py, so policies/gateway-projects and the other generated
files match the export (CI checks them).
"""
import argparse
import json
import os
import subprocess
import sys
import urllib.request
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parent.parent
HEADER = ("# yaml-language-server: $schema=schema.json\n"
          "# Exported from the project registry (scripts/registry-export.py): change it there.\n")
ORDER = {
    "project": ["project", "owner", "description", "data_class", "placement", "models", "routing",
                "limits", "budget", "keys", "mcp_tools", "deployments"],
    "agent": ["agent", "project", "owner", "description", "runtime", "autonomy", "keys", "models",
              "mcp_tools", "secret"],
}


def ordered(kind, spec):
    keys = ORDER[kind]
    return {**{k: spec[k] for k in keys if k in spec}, **{k: v for k, v in spec.items() if k not in keys}}


def write_records(kind, folder, records):
    changed = []
    existing = {p.stem: p for p in folder.glob("*.yaml") if not p.name.startswith("_")}
    for rid, spec in sorted(records.items()):
        path = folder / f"{rid}.yaml"
        if path.exists() and yaml.safe_load(path.read_text()) == spec:
            continue
        path.write_text(HEADER + yaml.safe_dump(ordered(kind, spec), sort_keys=False, width=100))
        changed.append(str(path.relative_to(ROOT)))
    for rid, path in existing.items():
        if rid not in records:
            path.unlink()
            changed.append(f"{path.relative_to(ROOT)} (deleted)")
    return changed


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--url", default="http://127.0.0.1:8080", help="the registry API (kubectl port-forward)")
    a = p.parse_args()
    token = os.environ.get("REGISTRY_TOKEN") or sys.exit("set REGISTRY_TOKEN to a Keycloak access token")
    req = urllib.request.Request(a.url.rstrip("/") + "/export", headers={"Authorization": f"Bearer {token}"})
    with urllib.request.urlopen(req, timeout=30) as r:
        export = json.load(r)
    changed = write_records("project", ROOT / "projects", export["project"])
    changed += write_records("agent", ROOT / "agents", export["agent"])
    exc_path = ROOT / "projects" / "_exceptions.yaml"
    current = (yaml.safe_load(exc_path.read_text()) or {}).get("exceptions") if exc_path.exists() else {}
    if (current or {}) != export["exception"]:
        exc_path.write_text("# Exported from the project registry (scripts/registry-export.py): change it there.\n"
                            + yaml.safe_dump({"exceptions": export["exception"]}, sort_keys=False, width=100))
        changed.append(str(exc_path.relative_to(ROOT)))
    print(f"registry revision {export['revision']}: {len(changed)} file(s) changed")
    for c in changed:
        print("  " + c)
    subprocess.run([sys.executable, str(ROOT / "scripts" / "gen-projects.py")], check=True, cwd=ROOT)


if __name__ == "__main__":
    main()
