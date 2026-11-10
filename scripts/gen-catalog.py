#!/usr/bin/env python3
"""Validate catalog/models.yaml and generate the files derived from it.

    python3 scripts/gen-catalog.py           write the generated files
    python3 scripts/gen-catalog.py --check   fail if they are out of date (CI)

Outputs:
  minikube/gitops/agentgateway-config/files/catalog.json
      what the gateway chart needs: one entry per model with its provider
      settings, and the Google API routes.
  policies/gateway/catalog/data.json
      what the gateway policy needs, as data.catalog: each model's and each
      Google API's placement and provider. No endpoints or secret names.
"""

import argparse
import json
import re
import sys
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parent.parent
SOURCE = ROOT / "catalog" / "models.yaml"
GATEWAY_OUT = ROOT / "minikube" / "gitops" / "agentgateway-config" / "files" / "catalog.json"
POLICY_OUT = ROOT / "policies" / "gateway" / "catalog" / "data.json"

PLACEMENTS = {"onprem", "gcp", "external"}

# Fields each provider needs and allows, besides placement and provider.
PROVIDERS = {
    "OpenAI": {"required": {"baseURL"}, "optional": {"secretRef"}},
    "Deepseek": {"required": {"secretRef"}, "optional": set()},
    "VertexAI": {"required": {"region"}, "optional": set()},
}
GOOGLE_API_FIELDS = {"required": {"placement", "host"}, "optional": {"http1Only"}}

# Kubernetes object names are derived from these, so keep them DNS-safe once
# dots are replaced (agentgateway-config templates/models.yaml).
NAME_RE = re.compile(r"^[a-z0-9]([a-z0-9.-]*[a-z0-9])?$")


def validate(catalog):
    errors = []
    if set(catalog) - {"models", "googleApis"}:
        errors.append(f"unknown top-level keys: {sorted(set(catalog) - {'models', 'googleApis'})}")

    models = catalog.get("models") or {}
    if not models:
        errors.append("models: at least one model is required")
    seen_objects = {}
    for name, m in models.items():
        where = f"models.{name}"
        if not NAME_RE.match(name):
            errors.append(f"{where}: name must be lowercase letters, digits, '.' and '-'")
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
        spec = PROVIDERS[provider]
        fields = set(m) - {"placement", "provider"}
        for f in sorted(spec["required"] - fields):
            errors.append(f"{where}: {provider} needs {f}")
        for f in sorted(fields - spec["required"] - spec["optional"]):
            errors.append(f"{where}: {f} is not a {provider} setting")

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


def render(catalog):
    models = catalog["models"]
    apis = catalog.get("googleApis") or {}
    gateway = {
        "models": [
            {"name": name, **{k: v for k, v in m.items() if k != "placement"}}
            for name, m in models.items()
        ],
        "googleApis": {
            name: {"host": a["host"], "http1Only": a.get("http1Only", False)}
            for name, a in apis.items()
        },
    }
    policy = {
        "models": {name: {"placement": m["placement"], "provider": m["provider"]} for name, m in models.items()},
        "google_apis": {name: {"placement": a["placement"]} for name, a in apis.items()},
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
    errors = validate(catalog)
    if errors:
        for e in errors:
            print(f"{SOURCE.relative_to(ROOT)}: {e}", file=sys.stderr)
        return 1

    stale = []
    for path, content in render(catalog).items():
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
