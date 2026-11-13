#!/usr/bin/env python3
"""Validate catalog/models.yaml and catalog/tools.yaml and generate the files derived from them.

    python3 scripts/gen-catalog.py           write the generated files
    python3 scripts/gen-catalog.py --check   fail if they are out of date (CI)

It also checks that the vLLM Semantic Router's decisions
(minikube/values/semantic-router-values.yaml) rewrite to exactly the catalog's
task classes, auto-<task>.

Outputs:
  minikube/gitops/agentgateway-config/files/catalog.json
      what the gateway chart needs: one entry per model with its provider
      settings, the Google API routes, and the task class names (one "auto-<task>"
      virtual model each).
  policies/gateway/catalog/data.json
      what the gateway policy needs, as data.catalog: each model's placement,
      provider and price, each Google API's placement, the task classes, and
      each MCP tool's risk (catalog/tools.yaml). No endpoints or secret names.
"""

import argparse
import json
import re
import sys
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parent.parent
SOURCE = ROOT / "catalog" / "models.yaml"
TOOLS = ROOT / "catalog" / "tools.yaml"
# The MCP targets the gateway merges; every tool name starts with one of them.
GATEWAY_VALUES = ROOT / "minikube" / "gitops" / "agentgateway-config" / "values.yaml"
RISKS = {"read", "write", "irreversible"}
GATEWAY_OUT = ROOT / "minikube" / "gitops" / "agentgateway-config" / "files" / "catalog.json"
POLICY_OUT = ROOT / "policies" / "gateway" / "catalog" / "data.json"
# The vLLM Semantic Router's config: its decisions must name the task classes.
VSR_VALUES = ROOT / "minikube" / "values" / "semantic-router-values.yaml"

PLACEMENTS = {"onprem", "gcp", "external"}

# Fields each provider needs and allows, besides placement and provider.
PROVIDERS = {
    "OpenAI": {"required": {"baseURL"}, "optional": {"secretRef"}},
    "Deepseek": {"required": {"secretRef"}, "optional": set()},
    "VertexAI": {"required": {"region"}, "optional": set()},
    # A release of the model onboarding pipeline: the KServe
    # LLMInferenceService <namespace>/<name> (its InferencePool), and the
    # model name its vLLM serves, which the gateway puts in the request in
    # place of the catalog name. Both come from the pipeline's release record.
    "KServe": {"required": {"deployment", "servedModel"}, "optional": set()},
}
GOOGLE_API_FIELDS = {"required": {"placement", "host"}, "optional": {"http1Only"}}

# Kubernetes object names are derived from these, so keep them DNS-safe once
# dots are replaced (agentgateway-config templates/models.yaml).
NAME_RE = re.compile(r"^[a-z0-9]([a-z0-9.-]*[a-z0-9])?$")
DNS_LABEL_RE = re.compile(r"^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$")


def validate(catalog):
    errors = []
    top = {"models", "googleApis", "tasks", "servingNamespaces"}
    if set(catalog) - top:
        errors.append(f"unknown top-level keys: {sorted(set(catalog) - top)}")

    serving = catalog.get("servingNamespaces") or []
    if not isinstance(serving, list) or any(not isinstance(n, str) or not DNS_LABEL_RE.match(n) for n in serving):
        errors.append("servingNamespaces: must be a list of namespace names")
        serving = []

    models = catalog.get("models") or {}
    if not models:
        errors.append("models: at least one model is required")
    seen_objects = {}
    for name, m in models.items():
        where = f"models.{name}"
        if not NAME_RE.match(name):
            errors.append(f"{where}: name must be lowercase letters, digits, '.' and '-'")
        if name == "auto" or name.startswith("auto-"):
            errors.append(f"{where}: auto and auto-* are the gateway's virtual models")
        obj = name.replace(".", "-")
        if obj in seen_objects:
            errors.append(f"{where}: object name {obj} clashes with {seen_objects[obj]}")
        seen_objects[obj] = name
        if not isinstance(m, dict):
            errors.append(f"{where}: must be a mapping")
            continue
        if m.get("placement") not in PLACEMENTS:
            errors.append(f"{where}.placement: must be one of {sorted(PLACEMENTS)}")
        provider = m.get("provider")
        if provider not in PROVIDERS:
            errors.append(f"{where}.provider: must be one of {sorted(PROVIDERS)}")
            continue
        price = m.get("price")
        if not (
            isinstance(price, dict)
            and set(price) == {"input", "output"}
            and all(isinstance(v, (int, float)) and not isinstance(v, bool) and v >= 0 for v in price.values())
        ):
            errors.append(f"{where}.price: needs input and output, USD per million tokens, each >= 0")
        spec = PROVIDERS[provider]
        fields = set(m) - {"placement", "provider", "price"}
        for f in sorted(spec["required"] - fields):
            errors.append(f"{where}: {provider} needs {f}")
        for f in sorted(fields - spec["required"] - spec["optional"]):
            errors.append(f"{where}: {f} is not a {provider} setting")
        if provider == "KServe":
            ns, _, svc = str(m.get("deployment", "")).partition("/")
            if not (DNS_LABEL_RE.match(ns) and DNS_LABEL_RE.match(svc)):
                errors.append(f"{where}.deployment: must be <namespace>/<LLMInferenceService name>")
            elif ns not in serving:
                errors.append(f"{where}.deployment: namespace {ns} is not in servingNamespaces")
            if not isinstance(m.get("servedModel"), str) or not m.get("servedModel"):
                errors.append(f"{where}.servedModel: must be the model name the deployment's vLLM serves")
            if m.get("placement") != "onprem":
                errors.append(f"{where}.placement: a KServe release runs on this cluster, so onprem")

    for task, prefs in (catalog.get("tasks") or {}).items():
        where = f"tasks.{task}"
        if not NAME_RE.match(task) or "." in task:
            errors.append(f"{where}: name must be lowercase letters, digits and '-'")
        if not isinstance(prefs, list) or not prefs or len(set(prefs)) != len(prefs):
            errors.append(f"{where}: must be a non-empty list of distinct model names")
            continue
        for m in prefs:
            if m not in models:
                errors.append(f"{where}: {m!r} is not a catalog model")
        if f"auto-{task}" in models:
            errors.append(f"{where}: its virtual model auto-{task} clashes with a catalog model")

    for name, api in (catalog.get("googleApis") or {}).items():
        where = f"googleApis.{name}"
        if not NAME_RE.match(name) or "." in name:
            errors.append(f"{where}: name must be lowercase letters, digits and '-'")
        if not isinstance(api, dict):
            errors.append(f"{where}: must be a mapping")
            continue
        for f in sorted(GOOGLE_API_FIELDS["required"] - set(api)):
            errors.append(f"{where}: needs {f}")
        for f in sorted(set(api) - GOOGLE_API_FIELDS["required"] - GOOGLE_API_FIELDS["optional"]):
            errors.append(f"{where}: unknown field {f}")
        if "placement" in api and api["placement"] not in PLACEMENTS:
            errors.append(f"{where}.placement: must be one of {sorted(PLACEMENTS)}")
        if "http1Only" in api and not isinstance(api["http1Only"], bool):
            errors.append(f"{where}.http1Only: must be true or false")
    return errors


def check_semantic_router(catalog):
    """VSR's decisions must rewrite to exactly the auto-<task> models."""
    if not VSR_VALUES.exists():
        return []
    where = VSR_VALUES.relative_to(ROOT)
    config = (yaml.safe_load(VSR_VALUES.read_text()) or {}).get("config") or {}
    expected = {f"auto-{t}" for t in (catalog.get("tasks") or {})}
    targets = {
        ref.get("model")
        for d in (config.get("routing") or {}).get("decisions") or []
        for ref in d.get("modelRefs") or []
    }
    errors = []
    if targets - expected:
        errors.append(f"{where}: decisions name {sorted(targets - expected)}, which are not catalog task classes")
    if expected - targets:
        errors.append(f"{where}: no decision routes to {sorted(expected - targets)}")
    default = ((config.get("providers") or {}).get("defaults") or {}).get("model")
    if default not in expected:
        errors.append(f"{where}: providers.defaults.model {default!r} is not a catalog task class")
    return errors


def validate_tools(tools_doc):
    errors = []
    tools = (tools_doc or {}).get("tools")
    if not isinstance(tools, dict) or not tools:
        return [f"{TOOLS.relative_to(ROOT)}: needs a tools mapping"], {}
    targets = ((yaml.safe_load(GATEWAY_VALUES.read_text()) or {}).get("mcp") or {}).get("targets") or {}
    for name, t in tools.items():
        where = f"{TOOLS.relative_to(ROOT)}: {name}"
        if not any(name.startswith(f"{target}_") for target in targets):
            errors.append(f"{where}: name must start with an MCP target's prefix ({', '.join(sorted(targets))})")
        if not isinstance(t, dict) or set(t) - {"risk", "fingerprint"}:
            errors.append(f"{where}: needs risk and an optional fingerprint, nothing else")
            continue
        if t.get("risk") not in RISKS:
            errors.append(f"{where}: risk must be one of {sorted(RISKS)}")
        fp = t.get("fingerprint")
        # A string: unquoted, YAML reads an all-digit or "1e5..."-like value as
        # a number and the drift check would compare the wrong thing.
        if fp is not None and not (isinstance(fp, str) and re.fullmatch(r"[0-9a-f]{16}", fp)):
            errors.append(f"{where}: fingerprint must be 16 hex digits in quotes")
    return errors, {name: t.get("risk") for name, t in tools.items()}


def render(catalog, tool_risks):
    models = catalog["models"]
    apis = catalog.get("googleApis") or {}
    gateway = {
        "models": [
            {"name": name, **{k: v for k, v in m.items() if k not in ("placement", "price")}}
            for name, m in models.items()
        ],
        "googleApis": {
            name: {"host": a["host"], "http1Only": a.get("http1Only", False)}
            for name, a in apis.items()
        },
        "tasks": sorted(catalog.get("tasks") or {}),
        "servingNamespaces": catalog.get("servingNamespaces") or [],
    }
    policy = {
        "models": {
            name: {"placement": m["placement"], "provider": m["provider"], "price": m["price"]}
            for name, m in models.items()
        },
        "google_apis": {name: {"placement": a["placement"]} for name, a in apis.items()},
        "tasks": catalog.get("tasks") or {},
        "tools": tool_risks,
        "serving_namespaces": catalog.get("servingNamespaces") or [],
    }
    return {
        GATEWAY_OUT: json.dumps(gateway, indent=2) + "\n",
        POLICY_OUT: json.dumps(policy, indent=2, sort_keys=True) + "\n",
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--check", action="store_true", help="fail if a generated file is out of date")
    args = parser.parse_args()

    catalog = yaml.safe_load(SOURCE.read_text())
    errors = [f"{SOURCE.relative_to(ROOT)}: {e}" for e in validate(catalog)] + check_semantic_router(catalog)
    tool_errors, tool_risks = validate_tools(yaml.safe_load(TOOLS.read_text()))
    errors += tool_errors
    if errors:
        for e in errors:
            print(e, file=sys.stderr)
        return 1

    stale = []
    for path, content in render(catalog, tool_risks).items():
        rel = path.relative_to(ROOT)
        if args.check:
            if not path.exists() or path.read_text() != content:
                stale.append(str(rel))
        else:
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(content)
            print(f"wrote {rel}")
    if stale:
        print("out of date (run: python3 scripts/gen-catalog.py): " + ", ".join(stale), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
