#!/usr/bin/env python3
"""Render a set of project registry records with scripts/gen-projects.py.

    python3 scripts/render-records.py RECORDS --out DIR   the gateway-projects bundle directory
    python3 scripts/render-records.py RECORDS --keys      "<key_id> <project>" per API key
    python3 scripts/render-records.py RECORDS --mirrors   "<secret> <field> <key_id>" per agent

RECORDS is a file in the format of the registry's GET /export (YAML or JSON):
{"project": {id: spec}, "agent": {id: spec}, "exception": {project: entry}}, e.g.
the seed (minikube/gitops/project-registry/files/seed.yaml). The project registry
holds the records; this repo keeps only their schema and the renderer. The
registry does the same thing (registry/render.py): it writes the records as the
files gen-projects.py reads, in a copy of this repo, and runs it there.

Used by CI (scripts/validate-gitops.sh: the Rego is tested with the seed rendered)
and by the Vault bootstrap on a new cluster, before the registry runs.
"""
import argparse
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parent.parent
COPY = ("scripts", "projects", "agents", "catalog", "policies", "minikube/values")


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("records", type=Path)
    mode = p.add_mutually_exclusive_group(required=True)
    mode.add_argument("--out", type=Path, help="write the bundle directory here (replaced)")
    mode.add_argument("--keys", action="store_true")
    mode.add_argument("--mirrors", action="store_true")
    a = p.parse_args()
    records = yaml.safe_load(a.records.read_text()) or {}
    with tempfile.TemporaryDirectory() as tmp:
        work = Path(tmp)
        for d in COPY:
            if (ROOT / d).exists():
                shutil.copytree(ROOT / d, work / d, ignore=shutil.ignore_patterns("__pycache__", "*.yaml")
                                if d in ("projects", "agents") else shutil.ignore_patterns("__pycache__"))
        for name, spec in (records.get("project") or {}).items():
            (work / "projects" / f"{name}.yaml").write_text(yaml.safe_dump(spec, sort_keys=False))
        for name, spec in (records.get("agent") or {}).items():
            (work / "agents" / f"{name}.yaml").write_text(yaml.safe_dump(spec, sort_keys=False))
        if records.get("exception"):
            (work / "projects" / "_exceptions.yaml").write_text(
                yaml.safe_dump({"exceptions": records["exception"]}, sort_keys=False))
        flag = ["--keys"] if a.keys else ["--mirrors"] if a.mirrors else []
        run = subprocess.run([sys.executable, str(work / "scripts" / "gen-projects.py"), *flag], cwd=work,
                             capture_output=True, text=True)
        if run.returncode != 0:
            sys.stderr.write(run.stderr or run.stdout)
            return 1
        if flag:
            sys.stdout.write(run.stdout)
            return 0
        if a.out.exists():
            shutil.rmtree(a.out)
        shutil.copytree(work / "policies" / "gateway-projects", a.out)
    return 0


if __name__ == "__main__":
    sys.exit(main())
