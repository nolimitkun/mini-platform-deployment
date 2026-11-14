#!/usr/bin/env python3
"""Check this repo's wiring against the catalog its project registry starts with.

    python3 scripts/check-policy-wiring.py [RECORDS]

RECORDS: the registry's seed (default: minikube/gitops/project-registry/files/seed.yaml),
whose catalog settings (the registry holds the live ones) name things this repo deploys,
so both must agree:
  - the gateway's MCP targets (agentgateway-config values mcp.targets) are the
    catalog's targets: every tool name starts with one;
  - the vLLM Semantic Router's decisions (semantic-router-values.yaml) route to
    exactly the catalog's task classes, auto-<task>, and so does its default;
  - the gateway admits routes from the catalog's serving namespaces
    (agentgateway-config values servingNamespaces).
"""
import sys
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parent.parent
GATEWAY_VALUES = ROOT / "minikube" / "gitops" / "agentgateway-config" / "values.yaml"
VSR_VALUES = ROOT / "minikube" / "values" / "semantic-router-values.yaml"
SEED = ROOT / "minikube" / "gitops" / "project-registry" / "files" / "seed.yaml"


def main() -> int:
    records = yaml.safe_load(Path(sys.argv[1] if len(sys.argv) > 1 else SEED).read_text()) or {}
    settings = (records.get("catalog") or {}).get("settings") or {}
    catalog = {"servingNamespaces": settings.get("servingNamespaces") or [], "tasks": settings.get("tasks") or {}}
    tools = {"targets": settings.get("targets") or []}
    errors = []

    gateway = yaml.safe_load(GATEWAY_VALUES.read_text()) or {}
    if set(gateway.get("servingNamespaces") or []) != set(catalog.get("servingNamespaces") or []):
        errors.append(f"{GATEWAY_VALUES.relative_to(ROOT)}: servingNamespaces {gateway.get('servingNamespaces')} are not "
                      f"the catalog's {catalog.get('servingNamespaces')}")
    targets = set((gateway.get("mcp") or {}).get("targets") or {})
    if targets != set(tools.get("targets") or []):
        errors.append(f"{GATEWAY_VALUES.relative_to(ROOT)}: mcp.targets {sorted(targets)} are not the "
                      f"catalog's targets {sorted(tools.get('targets') or [])} (the seed's catalog settings)")

    config = (yaml.safe_load(VSR_VALUES.read_text()) or {}).get("config") or {}
    expected = {f"auto-{t}" for t in (catalog.get("tasks") or {})}
    routed = {ref.get("model") for d in (config.get("routing") or {}).get("decisions") or []
              for ref in d.get("modelRefs") or []}
    where = VSR_VALUES.relative_to(ROOT)
    if routed - expected:
        errors.append(f"{where}: decisions name {sorted(routed - expected)}, which are not catalog task classes")
    if expected - routed:
        errors.append(f"{where}: no decision routes to {sorted(expected - routed)}")
    default = ((config.get("providers") or {}).get("defaults") or {}).get("model")
    if default not in expected:
        errors.append(f"{where}: providers.defaults.model {default!r} is not a catalog task class")

    for e in errors:
        print(e, file=sys.stderr)
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
