#!/usr/bin/env python3
"""Validate projects/*.yaml and generate the gateway policy's project data.

    python3 scripts/gen-projects.py           write the generated files
    python3 scripts/gen-projects.py --check   fail if they are out of date (CI)
    python3 scripts/gen-projects.py --keys    print "<key_id> <project>" per key
                                              (scripts/bootstrap-vault-secrets.sh)
    python3 scripts/gen-projects.py --mirrors print "<secret> <field> <key_id>" per
                                              agent whose runtime reads its key

Each project file is checked against projects/schema.json, then against rules
that span files:
  - the file name is the project id
  - placement only narrows what the data class allows
  - every models.allow pattern matches a catalog model (catalog/models.yaml)
  - a fixed:<model> routing names a model the project may use
  - key ids are the project id or start with it plus "-", and are unique
  - exceptions (projects/_exceptions.yaml) name existing projects and models

Agents (agents/*.yaml, checked against agents/schema.json) belong to a project
and narrow it: their keys are added to the project, which maps each to its
agent (agent_keys), and OPA gives a call with such a key the agent's models and
tools. A kagent agent must also be wired to its own key (kagent-values.yaml
modelConfigRef, a ModelConfig in kagent-resources.yaml extraObjects, the secret
in its vaultSecrets).

Outputs, read by OPA from the gateway-projects bundle (policies/gateway-projects,
separate from the policy bundle so a project change never rebuilds the Rego):
  policies/gateway-projects/projects/<id>/data.json    data.projects.<id>
  policies/gateway-projects/exceptions/<id>/data.json  data.exceptions.<id>
  policies/gateway-projects/agents/<id>/data.json      data.agents.<id>
and, applied to agentregistry (agentregistry-catalog chart):
  minikube/gitops/agentregistry-catalog/files/agents.yaml  one Agent per agent
One file per project, so changes to different projects never touch the same
file. Files of removed projects are deleted.
and, read by the rate-limit service (envoyproxy/ratelimit):
  minikube/gitops/rate-limit/files/config.yaml  the domain and a default entry (the
                                                limits come from OPA per request)
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
AGENTS = ROOT / "agents"
AGENT_SCHEMA = AGENTS / "schema.json"
AGENTS_OUT = PROJECTS_BUNDLE / "agents"
REGISTRY_OUT = ROOT / "minikube" / "gitops" / "agentregistry-catalog" / "files" / "agents.yaml"
KAGENT_VALUES = ROOT / "minikube" / "values" / "kagent-values.yaml"
KAGENT_RESOURCES = ROOT / "minikube" / "values" / "kagent-resources.yaml"

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

        # Optional: a project whose keys all belong to its agents may omit it.
        own_keys = doc.get("keys", [])
        for key_id in own_keys:
            if key_id != pid and not key_id.startswith(pid + "-"):
                errors.append(f"{rel(path)}: key id {key_id!r} must be {pid!r} or start with {pid + '-'!r}")
            if key_id in key_owner:
                errors.append(f"{rel(path)}: key id {key_id!r} is already used by {key_owner[key_id]}")
            key_owner[key_id] = pid

        routing = doc.get("routing", "cheapest")

        deployments = doc.get("deployments", False)
        if deployments and "onprem" not in placement:
            errors.append(f"{rel(path)}: deployments: true needs onprem among its placements")

        projects[pid] = {
            "owner": doc["owner"],
            "data_class": doc["data_class"],
            # Order kept as the class lists it, so the output is stable.
            "placement": [p for p in class_placements if p in placement],
            "models_allow": allow,
            "keys": own_keys,
            "mcp_tools": doc.get("mcp_tools", []),
            "routing": routing,
            "limits": doc.get("limits", {}),
            "budget": doc.get("budget", {}),
            "deployments": deployments,
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

    agents = load_agents(projects, exceptions, catalog_models, key_owner, errors)
    for pid, p in projects.items():
        if not p["keys"]:
            errors.append(f"projects/{pid}.yaml: no key, neither its own nor one of its agents'")
    return projects, exceptions, agents, errors


def project_models(p, pid, exceptions, catalog_models):
    """The models a project may use: the same rule as allowed() in lib.rego."""
    by_rule = {
        m for m, model in catalog_models.items()
        if model["placement"] in p["placement"] and any(fnmatch.fnmatchcase(m, pat) for pat in p["models_allow"])
    }
    return by_rule | set((exceptions.get(pid) or {}).get("models") or [])


def load_agents(projects, exceptions, catalog_models, key_owner, errors):
    """Validate agents/*.yaml; add each agent's keys to its project.

    Returns agent id -> entry for data.agents. Each project gains agent_keys
    (key id -> agent id), which is how OPA tells an agent's call from the
    project's own: a key listed there gets the agent's scope."""
    validator = jsonschema.Draft202012Validator(json.loads(AGENT_SCHEMA.read_text()))
    kagent_values = yaml.safe_load(KAGENT_VALUES.read_text()) or {}
    kagent_resources = yaml.safe_load(KAGENT_RESOURCES.read_text()) or {}
    kagent_secrets = set(kagent_resources.get("vaultSecrets") or [])
    model_configs = {
        o["metadata"]["name"]: o.get("spec", {})
        for o in kagent_resources.get("extraObjects") or []
        if o.get("kind") == "ModelConfig"
    }
    for p in projects.values():
        p["agent_keys"] = {}
    agents = {}
    for path in sorted(AGENTS.glob("*.yaml")):
        doc = yaml.safe_load(path.read_text())
        schema_errors = sorted(validator.iter_errors(doc), key=lambda e: list(e.path))
        for e in schema_errors:
            where = ".".join(str(x) for x in e.path) or "(file)"
            errors.append(f"{rel(path)}: {where}: {e.message}")
        if schema_errors:
            continue
        aid, pid = doc["agent"], doc["project"]
        if path.stem != aid:
            errors.append(f"{rel(path)}: agent is {aid!r}, but the file must then be named {aid}.yaml")
        if pid not in projects:
            errors.append(f"{rel(path)}: no project {pid!r}")
            continue
        p = projects[pid]

        usable = project_models(p, pid, exceptions, catalog_models)
        allow = doc.get("models", {}).get("allow", ["*"])
        for pattern in allow:
            if not fnmatch.filter(usable, pattern):
                errors.append(f"{rel(path)}: models.allow pattern {pattern!r} matches no model project {pid} may use")
        tools = doc.get("mcp_tools", [])
        if tools and not p["mcp_tools"]:
            errors.append(f"{rel(path)}: mcp_tools set, but project {pid} may use no MCP tool")

        for key_id in doc["keys"]:
            if key_id != pid and not key_id.startswith(pid + "-"):
                errors.append(f"{rel(path)}: key id {key_id!r} must be {pid!r} or start with {pid + '-'!r}")
            if key_id in key_owner:
                errors.append(f"{rel(path)}: key id {key_id!r} is already used by {key_owner[key_id]}")
            key_owner[key_id] = f"agent {aid}"
            p["keys"] = p["keys"] + [key_id]
            p["agent_keys"][key_id] = aid

        runtime = doc["runtime"]
        secret = doc.get("secret")
        if runtime["kind"] == "kagent":
            # The kagent agent must read this key: its own ModelConfig, naming
            # the agent's secret, which VSO mirrors into the namespace.
            ref = ((kagent_values.get(runtime["name"]) or {}).get("modelConfigRef")) or ""
            if not secret:
                errors.append(f"{rel(path)}: a kagent agent needs secret")
            elif secret["name"] not in kagent_secrets:
                errors.append(f"{rel(path)}: secret {secret['name']} is not in {rel(KAGENT_RESOURCES)} vaultSecrets")
            if ref not in model_configs:
                errors.append(f"{rel(path)}: {rel(KAGENT_VALUES)} {runtime['name']}.modelConfigRef must name a ModelConfig in {rel(KAGENT_RESOURCES)} extraObjects")
            elif secret and model_configs[ref].get("apiKeySecret") != secret["name"]:
                errors.append(f"{rel(path)}: ModelConfig {ref} must read secret {secret['name']}")

        agents[aid] = {
            "project": pid,
            "owner": doc["owner"],
            "description": doc["description"],
            "runtime": runtime,
            "autonomy": doc["autonomy"],
            "models_allow": allow,
            "mcp_tools": tools,
            "keys": doc["keys"],
            "secret": secret,
        }
    return agents


def registry_catalog(agents):
    """agentregistry entries for the agents (files/agents.yaml of the catalog chart)."""
    docs = []
    for aid, a in sorted(agents.items()):
        spec = {
            "title": aid,
            "description": (
                f"{a['description']} Owner: {a['owner']}. Project: {a['project']}. "
                f"Autonomy: {a['autonomy']}. Runs on {a['runtime']['kind']} as {a['runtime']['name']}. "
                f"Models: {', '.join(a['models_allow'])}. "
                f"MCP tools: {', '.join(a['mcp_tools']) or 'none through the gateway'}."
            ),
            "modelProvider": "openai",
        }
        if len(a["models_allow"]) == 1 and "*" not in a["models_allow"][0]:
            spec["modelName"] = a["models_allow"][0]
        if a["mcp_tools"]:
            spec["mcpServers"] = [{"kind": "MCPServer", "name": "platform-tools"}]
        docs.append({
            "apiVersion": "ar.dev/v1alpha1",
            "kind": "Agent",
            "metadata": {
                "name": aid,
                "labels": {"project": a["project"], "autonomy": a["autonomy"], "runtime": a["runtime"]["kind"]},
            },
            "spec": spec,
        })
    header = (
        "# Generated by scripts/gen-projects.py from agents/*.yaml; do not edit.\n"
        "# Applied to agentregistry together with catalog.yaml.\n"
    )
    return header + "".join("---\n" + yaml.safe_dump(d, sort_keys=False, width=200) for d in docs)


def ratelimit_config(projects):
    """envoyproxy/ratelimit config: the domain and a default entry, no project.

    Each project's limits travel with OPA's allow decision and reach the service
    as every descriptor's limitOverride (policies/gateway/authz.rego `limits`,
    agentgateway-config ratelimit.yaml), which the service honours for any
    descriptor in a known domain. So this file no longer changes with projects,
    and a limit change goes live with the project data bundle, not with an Argo
    CD sync of this config.

    The default entry, without a value, matches any project: a request limit of
    0 for a descriptor sent without an override. agentgateway always sends one
    (0 when OPA gave no limit), so it is a backstop only."""
    del projects
    descriptors = [{
        "key": "project",
        "descriptors": [{"key": "kind", "value": "requests", "rate_limit": {"unit": "minute", "requests_per_unit": 0}}],
    }]
    header = (
        "# Generated by scripts/gen-projects.py; do not edit.\n"
        "# envoyproxy/ratelimit config for the gateway's per-project limits. The limits\n"
        "# themselves come from OPA with each request (limitOverride); the entry below\n"
        "# refuses a descriptor sent without one.\n"
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
    mode.add_argument("--mirrors", action="store_true",
                      help="print one '<secret> <field> <key_id>' line per agent with a secret")
    args = parser.parse_args()

    projects, exceptions, agents, errors = load()
    if errors:
        for e in errors:
            print(e, file=sys.stderr)
        return 1

    if args.keys:
        for pid, p in sorted(projects.items()):
            for key_id in p["keys"]:
                print(key_id, pid)
        return 0

    if args.mirrors:
        for aid, a in sorted(agents.items()):
            if a["secret"]:
                print(a["secret"]["name"], a["secret"]["field"], a["keys"][0])
        return 0

    outputs = {
        RATELIMIT_OUT: ratelimit_config(projects),
        ALERTS_OUT: alert_rules(projects),
        REGISTRY_OUT: registry_catalog(agents),
    }
    policy_agents = {aid: {k: v for k, v in a.items() if k != "secret"} for aid, a in agents.items()}
    for out, entries in ((PROJECTS_OUT, projects), (EXCEPTIONS_OUT, exceptions), (AGENTS_OUT, policy_agents)):
        for pid, entry in entries.items():
            outputs[out / pid / "data.json"] = json.dumps(entry, indent=2, sort_keys=True) + "\n"
    # Per-project files no project produces any more (a removed project).
    leftover = sorted(
        path
        for out in (PROJECTS_OUT, EXCEPTIONS_OUT, AGENTS_OUT)
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
