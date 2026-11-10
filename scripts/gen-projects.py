#!/usr/bin/env python3
"""Validate projects/*.yaml and generate the gateway policy's project data.

    python3 scripts/gen-projects.py           write the generated files
    python3 scripts/gen-projects.py --check   fail if they are out of date (CI)
    python3 scripts/gen-projects.py --keys    print "<key_id> <project>" per key
                                              (scripts/bootstrap-vault-secrets.sh)

Each project file is checked against projects/schema.json, then against rules
that span files:
  - the file name is the project id
  - placement only narrows what the data class allows
  - every models.allow pattern matches a catalog model (catalog/models.yaml)
  - key ids are the project id or start with it plus "-", and are unique
  - exceptions (projects/_exceptions.yaml) name existing projects and models

Outputs, read by OPA:
  policies/gateway/projects/data.json    data.projects.<id>
  policies/gateway/exceptions/data.json  data.exceptions.<id>
"""

import argparse
import fnmatch
import json
import sys
from pathlib import Path

import jsonschema
import yaml

ROOT = Path(__file__).resolve().parent.parent
PROJECTS = ROOT / "projects"
SCHEMA = PROJECTS / "schema.json"
EXCEPTIONS = PROJECTS / "_exceptions.yaml"
CATALOG = ROOT / "catalog" / "models.yaml"
CLASSES = ROOT / "policies" / "gateway" / "data.json"
PROJECTS_OUT = ROOT / "policies" / "gateway" / "projects" / "data.json"
EXCEPTIONS_OUT = ROOT / "policies" / "gateway" / "exceptions" / "data.json"


def rel(path):
    return path.relative_to(ROOT)


def load():
    """Return (projects, exceptions, errors). projects: id -> effective entry."""
    errors = []
    schema = json.loads(SCHEMA.read_text())
    validator = jsonschema.Draft202012Validator(schema)
    models = set((yaml.safe_load(CATALOG.read_text()) or {}).get("models") or {})
    classes = json.loads(CLASSES.read_text())["gateway"]["classes"]

    projects, key_owner = {}, {}
    for path in sorted(PROJECTS.glob("*.yaml")):
        if path.name.startswith("_"):
            continue
        doc = yaml.safe_load(path.read_text())
        schema_errors = sorted(validator.iter_errors(doc), key=lambda e: list(e.path))
        for e in schema_errors:
            where = ".".join(str(p) for p in e.path) or "(file)"
            errors.append(f"{rel(path)}: {where}: {e.message}")
        if schema_errors:
            continue

        pid = doc["project"]
        if path.stem != pid:
            errors.append(f"{rel(path)}: project is {pid!r}, but the file must then be named {pid}.yaml")

        class_placements = classes[doc["data_class"]]
        placement = doc.get("placement", class_placements)
        beyond = sorted(set(placement) - set(class_placements))
        if beyond:
            errors.append(
                f"{rel(path)}: placement {beyond} is beyond what {doc['data_class']} data allows "
                f"({class_placements}); ask for an exception instead"
            )

        allow = doc.get("models", {}).get("allow", ["*"])
        for pattern in allow:
            if not fnmatch.filter(models, pattern):
                errors.append(f"{rel(path)}: models.allow pattern {pattern!r} matches no catalog model")

        for key_id in doc["keys"]:
            if key_id != pid and not key_id.startswith(pid + "-"):
                errors.append(f"{rel(path)}: key id {key_id!r} must be {pid!r} or start with {pid + '-'!r}")
            if key_id in key_owner:
                errors.append(f"{rel(path)}: key id {key_id!r} is already used by {key_owner[key_id]}")
            key_owner[key_id] = pid

        projects[pid] = {
            "owner": doc["owner"],
            "data_class": doc["data_class"],
            # Order kept as the class lists it, so the output is stable.
            "placement": [p for p in class_placements if p in placement],
            "models_allow": allow,
            "keys": doc["keys"],
            "mcp_tools": doc.get("mcp_tools", []),
        }

    if not projects:
        errors.append("projects/: no project files")

    exceptions = (yaml.safe_load(EXCEPTIONS.read_text()) or {}).get("exceptions") or {}
    for pid, exc in exceptions.items():
        where = f"{rel(EXCEPTIONS)}: {pid}"
        if pid not in projects:
            errors.append(f"{where}: no project {pid!r}")
        if not isinstance(exc, dict):
            errors.append(f"{where}: must be a mapping")
            continue
        missing = {"owner", "why", "models"} - set(exc)
        unknown = set(exc) - {"owner", "why", "models"}
        if missing:
            errors.append(f"{where}: needs {sorted(missing)}")
        if unknown:
            errors.append(f"{where}: unknown fields {sorted(unknown)}")
        for m in exc.get("models") or []:
            if m not in models:
                errors.append(f"{where}: model {m!r} is not in the catalog")
    return projects, exceptions, errors


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--check", action="store_true", help="fail if a generated file is out of date")
    mode.add_argument("--keys", action="store_true", help="print one '<key_id> <project>' line per key")
    args = parser.parse_args()

    projects, exceptions, errors = load()
    if errors:
        for e in errors:
            print(e, file=sys.stderr)
        return 1

    if args.keys:
        for pid, p in sorted(projects.items()):
            for key_id in p["keys"]:
                print(key_id, pid)
        return 0

    outputs = {
        PROJECTS_OUT: json.dumps(projects, indent=2, sort_keys=True) + "\n",
        EXCEPTIONS_OUT: json.dumps(exceptions, indent=2, sort_keys=True) + "\n",
    }
    stale = []
    for path, content in outputs.items():
        if args.check:
            if not path.exists() or path.read_text() != content:
                stale.append(str(rel(path)))
        else:
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(content)
            print(f"wrote {rel(path)}")
    if stale:
        print("out of date (run: python3 scripts/gen-projects.py): " + ", ".join(stale), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
