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
  - a fixed:<model> routing names a model the project may use
  - key ids are the project id or start with it plus "-", and are unique
  - exceptions (projects/_exceptions.yaml) name existing projects and models

Outputs, read by OPA from the gateway-projects bundle (policies/gateway-projects,
separate from the policy bundle so a project change never rebuilds the Rego):
  policies/gateway-projects/projects/<id>/data.json    data.projects.<id>
  policies/gateway-projects/exceptions/<id>/data.json  data.exceptions.<id>
One file per project, so changes to different projects never touch the same
file. Files of removed projects are deleted.
and, read by the rate-limit service (envoyproxy/ratelimit):
  minikube/gitops/rate-limit/files/config.yaml  each project's limits and budget
and, read by Prometheus (prometheus-resources.yaml):
  minikube/gitops/app-resources/alerts/agentgateway-projects.yml  alert rules
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
PROJECTS_BUNDLE = ROOT / "policies" / "gateway-projects"
PROJECTS_OUT = PROJECTS_BUNDLE / "projects"
EXCEPTIONS_OUT = PROJECTS_BUNDLE / "exceptions"
RATELIMIT_OUT = ROOT / "minikube" / "gitops" / "rate-limit" / "files" / "config.yaml"
ALERTS_OUT = ROOT / "minikube" / "gitops" / "app-resources" / "alerts" / "agentgateway-projects.yml"

# Warn when a day's spend, kept up for 30 days, would pass this share of the
# project's budget. A forecast from the last 24 hours, because Prometheus keeps
# only 15 days: the rate-limit service's 30-day count isn't in it.
BUDGET_WARN_SHARE = 0.8

GATEWAY_SELECTOR = 'gateway="mini-platform/agentgateway-proxy"'

# The domain the gateway's rateLimit policy sends (agentgateway-config
# values.yaml rateLimit.domain); the descriptor kinds match its descriptors.
RATELIMIT_DOMAIN = "agentgateway"


def rel(path):
    return path.relative_to(ROOT)


def load():
    """Return (projects, exceptions, errors). projects: id -> effective entry."""
    errors = []
    schema = json.loads(SCHEMA.read_text())
    validator = jsonschema.Draft202012Validator(schema)
    catalog_models = (yaml.safe_load(CATALOG.read_text()) or {}).get("models") or {}
    models = set(catalog_models)
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

        routing = doc.get("routing", "cheapest")

        projects[pid] = {
            "owner": doc["owner"],
            "data_class": doc["data_class"],
            # Order kept as the class lists it, so the output is stable.
            "placement": [p for p in class_placements if p in placement],
            "models_allow": allow,
            "keys": doc["keys"],
            "mcp_tools": doc.get("mcp_tools", []),
            "routing": routing,
            "limits": doc.get("limits", {}),
            "budget": doc.get("budget", {}),
        }

    if not projects:
        errors.append("projects/: no project files")

    exceptions = (yaml.safe_load(EXCEPTIONS.read_text()) or {}).get("exceptions") or {}

    # The same rule as allowed() in policies/gateway/lib.rego.
    for pid, p in projects.items():
        if not p["routing"].startswith("fixed:"):
            continue
        model = p["routing"].removeprefix("fixed:")
        by_rule = (
            model in catalog_models
            and catalog_models[model]["placement"] in p["placement"]
            and any(fnmatch.fnmatchcase(model, pat) for pat in p["models_allow"])
        )
        by_exception = model in ((exceptions.get(pid) or {}).get("models") or [])
        if not (by_rule or by_exception):
            errors.append(f"projects/{pid}.yaml: routing {p['routing']!r} names a model the project may not use")

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


def ratelimit_config(projects):
    """envoyproxy/ratelimit config: one descriptor per project, plus a default.

    Every project gets an entry. A kind the project doesn't limit is written
    as unlimited, so "absent: no limit" still holds. The last entry has no
    value: the service matches it for any project not listed, and its request
    limit of 0 refuses every call. A project OPA already allows but whose
    limits haven't reached this service yet (OCP loads policy data within a
    minute; this config needs an Argo CD sync) is therefore refused, not left
    without its limits and budget.

    The budget is counted in micro-USD (the gateway charges
    int(llm.cost.total * 1e6) per call), per the service's "month": a fixed
    30-day window."""
    kinds = (("requests", "minute"), ("tokens", "minute"), ("budget_micro_usd", "month"))
    descriptors = []
    for pid, p in sorted(projects.items()):
        limits = p["limits"]
        values = {
            "requests": limits.get("requests_per_minute"),
            "tokens": limits.get("tokens_per_minute"),
            "budget_micro_usd": (
                round(p["budget"]["usd_per_30_days"] * 1_000_000) if "usd_per_30_days" in p["budget"] else None
            ),
        }
        entries = []
        for kind, unit in kinds:
            if values[kind] is None:
                entries.append({"key": "kind", "value": kind, "rate_limit": {"unlimited": True}})
            else:
                entries.append({"key": "kind", "value": kind, "rate_limit": {"unit": unit, "requests_per_unit": values[kind]}})
        descriptors.append({"key": "project", "value": pid, "descriptors": entries})
    descriptors.append({
        "key": "project",
        "descriptors": [{"key": "kind", "value": "requests", "rate_limit": {"unit": "minute", "requests_per_unit": 0}}],
    })
    header = (
        "# Generated by scripts/gen-projects.py from projects/*.yaml; do not edit.\n"
        "# envoyproxy/ratelimit config for the gateway's per-project limits.\n"
        "# The last entry, without a value, refuses projects not listed here.\n"
    )
    return header + yaml.safe_dump({"domain": RATELIMIT_DOMAIN, "descriptors": descriptors}, sort_keys=False)


def alert_rules(projects):
    """Prometheus alert rules for the gateway's projects.

    One spend forecast per project with a budget, plus two for every project:
    the gateway refused calls because of the project's own limit or budget
    (reason RateLimit), and a provider throttled a model (reason Upstream, the
    Vertex quota case)."""
    cost = f"agentgateway_gen_ai_client_cost_usd_total{{{GATEWAY_SELECTOR}"
    rules = []
    for pid, p in sorted(projects.items()):
        budget = p["budget"].get("usd_per_30_days")
        if budget is None:
            continue
        rules.append({
            "alert": "GatewayProjectBudgetForecast",
            "expr": f'30 * sum(increase({cost},project="{pid}"}}[24h])) > {BUDGET_WARN_SHARE} * {budget}',
            "for": "30m",
            "labels": {"severity": "warning", "project": pid},
            "annotations": {
                "summary": f"{pid} is on course to use over {round(BUDGET_WARN_SHARE * 100)}% of its {budget} USD budget",
                "description": (
                    "The last 24 hours cost {{ $value | printf \"%.2f\" }} USD over 30 days. "
                    f"At {budget} USD per 30 days the gateway answers 429. "
                    f"Raise budget.usd_per_30_days in projects/{pid}.yaml or find the caller "
                    "(dashboard Agentgateway projects)."
                ),
            },
        })
    rules.append({
        "alert": "GatewayProjectRateLimited",
        "expr": f'sum by (project) (increase(agentgateway_requests_total{{{GATEWAY_SELECTOR},reason="RateLimit"}}[10m])) > 0',
        "labels": {"severity": "warning"},
        "annotations": {
            "summary": "The gateway refused calls from {{ $labels.project }}: request limit or budget reached",
            "description": (
                "{{ $value | printf \"%.0f\" }} calls got 429 in 10 minutes. "
                "limits and budget are in projects/{{ $labels.project }}.yaml."
            ),
        },
    })
    rules.append({
        "alert": "GatewayUpstreamThrottled",
        "expr": f'sum by (backend) (increase(agentgateway_requests_total{{{GATEWAY_SELECTOR},reason="Upstream",status="429"}}[15m])) >= 5',
        "labels": {"severity": "warning"},
        "annotations": {
            "summary": "{{ $labels.backend }} is throttling the gateway (429 from the provider)",
            "description": (
                "{{ $value | printf \"%.0f\" }} calls got 429 from the provider in 15 minutes. "
                "For Vertex models, check the project's quota in the GCP console."
            ),
        },
    })
    header = (
        "# Generated by scripts/gen-projects.py from projects/*.yaml; do not edit.\n"
        "# Prometheus alert rules for the gateway's projects (prometheus-resources.yaml).\n"
    )
    return header + yaml.safe_dump({"groups": [{"name": "agentgateway-projects", "rules": rules}]}, sort_keys=False, width=200)


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
        RATELIMIT_OUT: ratelimit_config(projects),
        ALERTS_OUT: alert_rules(projects),
    }
    for out, entries in ((PROJECTS_OUT, projects), (EXCEPTIONS_OUT, exceptions)):
        for pid, entry in entries.items():
            outputs[out / pid / "data.json"] = json.dumps(entry, indent=2, sort_keys=True) + "\n"
    # Per-project files no project produces any more (a removed project).
    leftover = sorted(
        path
        for out in (PROJECTS_OUT, EXCEPTIONS_OUT)
        for path in out.glob("**/*")
        if path.is_file() and path not in outputs
    )
    stale = []
    for path, content in outputs.items():
        if args.check:
            if not path.exists() or path.read_text() != content:
                stale.append(str(rel(path)))
        elif not path.exists() or path.read_text() != content:
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(content)
            print(f"wrote {rel(path)}")
    for path in leftover:
        if args.check:
            stale.append(f"{rel(path)} (no such project)")
        else:
            path.unlink()
            if not any(path.parent.iterdir()):
                path.parent.rmdir()
            print(f"removed {rel(path)}")
    if stale:
        print("out of date (run: python3 scripts/gen-projects.py): " + ", ".join(stale), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
