#!/usr/bin/env bash
# Validate this deployment repo's GitOps charts and scripts without a cluster.
#
# Runs the same checks as CI so failures can be reproduced locally:
#   - every valuesFile and resourcesFile referenced by the app-of-apps exists
#   - every charts/* chartPath exists in the charts repo checkout (if available)
#   - every first-party chartPath (minikube/gitops/*) exists locally
#   - every minikube/values/*-resources.yaml is referenced by an application
#   - the app-of-apps chart lints and renders, and the shared app-resources
#     chart lints and renders against each per-application resources file
#   - rendered manifests pass kubeconform (CRDs are allowed to be unknown)
#   - shellcheck on scripts/
#   - against the gateway policy at policyRevision (its own CI tests the Rego):
#     agentgateway-config renders with its catalog, the MCP targets and semantic
#     router decisions match it, and the registry's seed renders with the kagent
#     agents wired to their keys
#   - promtool on Prometheus's rendered prometheus.yml and on the alert rules
#     under minikube/gitops/app-resources/alerts/
#
# The vendored charts live in a separate repository. Point CHARTS_DIR at a local
# checkout of it (default: ../mini-platform) to verify charts/* paths resolve;
# when absent those checks are skipped, not failed.
#
# Tools used if present: helm (required), python3 with PyYAML and jsonschema
# (required), git (required, to fetch the gateway policy; GATEWAY_POLICY_DIR uses a
# local checkout instead), kubeconform (optional), shellcheck (optional), promtool
# (optional).
# Missing optional tools are reported and skipped, not failed.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

CHARTS_DIR="${CHARTS_DIR:-$ROOT/../mini-platform}"

FAIL=0
have() { command -v "$1" >/dev/null 2>&1; }
ok()   { printf '  \033[32mok\033[0m   %s\n' "$*"; }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$*"; FAIL=1; }
skip() { printf '  \033[33mskip\033[0m %s\n' "$*"; }

have helm || { echo "ERROR: helm is required." >&2; exit 1; }
python3 -c 'import yaml, jsonschema' 2>/dev/null \
  || { echo "ERROR: python3 with PyYAML and jsonschema is required." >&2; exit 1; }

APP_OF_APPS=minikube/gitops/mini-platform
# The app-of-apps chart requires all four source parameters to render.
APP_PARAMS=(
  --set chartsRepo=https://example.com/mini-platform.git
  --set chartsRevision=main
  --set deployRepo=https://example.com/mini-platform-deployment.git
  --set deployRevision=main
)

# The shared chart rendered as a second source on every application that owns
# ingress routes or Vault secrets. Read from the app-of-apps values so the two
# cannot drift.
RESOURCES_CHART="$(awk '$1 == "resourcesChartPath:" { print $2 }' "$APP_OF_APPS/values.yaml")"

mapfile -t RESOURCES_FILES < <(awk '$1 == "resourcesFile:" { print $2 }' "$APP_OF_APPS/values.yaml")

charts_dir_present=false
[[ -d "$CHARTS_DIR/charts" ]] && charts_dir_present=true

echo "==> Referenced chartPath exists"
while read -r path; do
  [[ -n "$path" ]] || continue
  if [[ "$path" == charts/* ]]; then
    if [[ "$charts_dir_present" == true ]]; then
      if [[ -e "$CHARTS_DIR/$path" ]]; then ok "$path (in charts repo)"; else bad "missing in charts repo: $path"; fi
    else
      skip "$path (charts repo not at CHARTS_DIR=$CHARTS_DIR)"
    fi
  else
    if [[ -e "$path" ]]; then ok "$path"; else bad "missing: $path"; fi
  fi
done < <(awk '/^[[:space:]]*chartPath:[[:space:]]/ {print $2}' "$APP_OF_APPS/values.yaml")
if [[ -n "$RESOURCES_CHART" && -e "$RESOURCES_CHART" ]]; then
  ok "$RESOURCES_CHART (resourcesChartPath)"
else
  bad "missing resourcesChartPath: ${RESOURCES_CHART:-<unset>}"
fi

echo "==> Referenced valuesFile exists"
while read -r path; do
  [[ -n "$path" ]] || continue
  if [[ -e "$path" ]]; then ok "$path"; else bad "missing: $path"; fi
done < <(awk '/^[[:space:]]*valuesFile:[[:space:]]/ {print $2}' "$APP_OF_APPS/values.yaml")

echo "==> Referenced resourcesFile exists"
for path in "${RESOURCES_FILES[@]}"; do
  if [[ -e "$path" ]]; then ok "$path"; else bad "missing: $path"; fi
done
# An unreferenced *-resources.yaml renders nothing at all: its ingress route and
# Vault secrets would silently never be created.
for path in minikube/values/*-resources.yaml; do
  found=false
  for referenced in "${RESOURCES_FILES[@]}"; do
    [[ "$referenced" == "$path" ]] && { found=true; break; }
  done
  [[ "$found" == true ]] || bad "not referenced by any application: $path"
done

echo "==> No duplicate keys in values files"
# YAML takes the last of two equal keys without a word: a block pasted into the
# middle of another silently moves its keys (it did, to project-registry's policy).
if python3 - minikube/values/*.yaml minikube/gitops/*/values.yaml minikube/gitops/*/files/*.yaml <<'PY'
import sys, yaml
class Strict(yaml.SafeLoader):
    pass
def mapping(loader, node, deep=False):
    seen = set()
    for k, _ in node.value:
        key = loader.construct_object(k, deep=True)
        if key in seen:
            raise yaml.constructor.ConstructorError(None, None, f"duplicate key {key!r}", k.start_mark)
        seen.add(key)
    return yaml.SafeLoader.construct_mapping(loader, node, deep)
Strict.add_constructor(yaml.resolver.BaseResolver.DEFAULT_MAPPING_TAG, mapping)
bad = 0
for f in sys.argv[1:]:
    try:
        list(yaml.load_all(open(f), Strict))
    except yaml.YAMLError as e:
        print(f"{f}: {e}"); bad = 1
sys.exit(bad)
PY
then ok "values files"; else bad "duplicate keys (see above)"; fi

echo "==> helm lint"
if helm lint "$APP_OF_APPS" "${APP_PARAMS[@]}" >/dev/null 2>&1; then ok "$APP_OF_APPS"; else
  bad "$APP_OF_APPS"; helm lint "$APP_OF_APPS" "${APP_PARAMS[@]}" || true
fi
for path in "${RESOURCES_FILES[@]}"; do
  [[ -e "$path" ]] || continue
  if helm lint "$RESOURCES_CHART" -f "$path" >/dev/null 2>&1; then ok "$RESOURCES_CHART -f $path"; else
    bad "$RESOURCES_CHART -f $path"; helm lint "$RESOURCES_CHART" -f "$path" || true
  fi
done

echo "==> helm template + kubeconform"
RENDER_DIR="$(mktemp -d)"
trap 'rm -rf "$RENDER_DIR"' EXIT

# render <label> <output-basename> <helm template args...>
render() {
  local label="$1" base="$2"; shift 2
  local out="$RENDER_DIR/$base.yaml"
  if helm template "$@" > "$out" 2>"$out.err"; then
    ok "render $label"
  else
    bad "render $label"; cat "$out.err"; return 0
  fi
  if have kubeconform; then
    if kubeconform -strict -ignore-missing-schemas -summary "$out" >/dev/null 2>&1; then
      ok "kubeconform $label"
    else
      bad "kubeconform $label"; kubeconform -strict -ignore-missing-schemas "$out" || true
    fi
  fi
}

render "$APP_OF_APPS" app-of-apps mini-platform "$APP_OF_APPS" "${APP_PARAMS[@]}"
for path in "${RESOURCES_FILES[@]}"; do
  [[ -e "$path" ]] || continue
  name="$(basename "$path" -resources.yaml)"
  render "$RESOURCES_CHART -f $path" "resources-$name" \
    "$name-resources" "$RESOURCES_CHART" --namespace mini-platform -f "$path"
done
have kubeconform || skip "kubeconform not installed (manifest schema check skipped)"

echo "==> shellcheck"
if have shellcheck; then
  if shellcheck scripts/*.sh; then ok "scripts/*.sh"; else bad "scripts/*.sh"; fi
else
  skip "shellcheck not installed"
fi

echo "==> gateway policy (nolimitkun/gateway-policy at policyRevision)"
# The Rego, the catalog and the record schemas are in their own repo, with their
# own CI. Here: this repo's wiring against them, at the commit it pins.
if policy_dir="$(scripts/policy-checkout.sh)"; then
  ok "checkout $policy_dir"
  catalog_values="$policy_dir/generated/agentgateway-catalog.yaml"
  render "agentgateway-config (with the policy's catalog)" agentgateway-config \
    agentgateway-config minikube/gitops/agentgateway-config --namespace mini-platform \
    -f minikube/gitops/agentgateway-config/values.yaml -f "$catalog_values"
  if python3 scripts/check-policy-wiring.py "$policy_dir"; then
    ok "MCP targets and semantic router decisions match the catalog"
  else
    bad "wiring (scripts/check-policy-wiring.py)"
  fi
  # The registry's seed (the platform's own projects, which a new cluster starts
  # with) must render with the policy's renderer, and each kagent agent in it be
  # wired to its own key in this repo's kagent values.
  if KAGENT_VALUES="$PWD/minikube/values/kagent-values.yaml" \
     KAGENT_RESOURCES="$PWD/minikube/values/kagent-resources.yaml" \
     python3 "$policy_dir/scripts/render-records.py" minikube/gitops/project-registry/files/seed.yaml \
       --out "$(mktemp -d)/gateway-projects"; then
    ok "seed renders; kagent agents wired to their keys"
  else
    bad "seed (render-records.py, with KAGENT_VALUES and KAGENT_RESOURCES)"
  fi
else
  bad "checkout of the gateway policy (scripts/policy-checkout.sh)"
fi

echo "==> promtool (Prometheus config and alert rules)"
if have promtool; then
  for f in minikube/gitops/app-resources/alerts/*.yml; do
    if out="$(promtool check rules "$f" 2>&1)"; then ok "rules $f"; else bad "rules $f"; echo "$out"; fi
  done
  # The config as the chart renders it from prometheus-values.yaml. Syntax
  # only: the rule and secret files it names exist only inside the pod. This
  # still catches what Prometheus refuses at startup, such as a rule_files glob
  # outside the last path segment.
  if $charts_dir_present; then
    prom_tmp="$(mktemp -d)"
    if helm template prometheus "$CHARTS_DIR/charts/prometheus" -n mini-platform \
        -f minikube/values/prometheus-values.yaml --show-only templates/cm.yaml \
        | python3 -c 'import sys, yaml; sys.stdout.write(yaml.safe_load(sys.stdin)["data"]["prometheus.yml"])' \
        >"$prom_tmp/prometheus.yml" \
      && out="$(promtool check config --syntax-only "$prom_tmp/prometheus.yml" 2>&1)"; then
      ok "prometheus.yml (prometheus-values.yaml)"
    else
      bad "prometheus.yml (prometheus-values.yaml)"; echo "${out:-}"
    fi
    rm -rf "$prom_tmp"
  else
    skip "prometheus.yml (charts repo not found at $CHARTS_DIR)"
  fi
else
  skip "promtool not installed (Prometheus checks skipped)"
fi

echo
if [[ "$FAIL" -eq 0 ]]; then echo "All checks passed."; else echo "Some checks FAILED." >&2; fi
exit "$FAIL"
