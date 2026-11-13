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
#   - catalog/models.yaml and projects/*.yaml are valid and the files generated
#     from them are current
#   - opa check and fmt on every policy bundle under policies/, opa test over
#     all of them, and a build of each loaded together (disjoint roots)
#   - promtool on Prometheus's rendered prometheus.yml and on the alert rules
#     under minikube/gitops/app-resources/alerts/
#
# The vendored charts live in a separate repository. Point CHARTS_DIR at a local
# checkout of it (default: ../mini-platform) to verify charts/* paths resolve;
# when absent those checks are skipped, not failed.
#
# Tools used if present: helm (required), python3 with PyYAML and jsonschema
# (required), kubeconform (optional), shellcheck (optional), opa (optional),
# promtool (optional).
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

echo "==> model catalog (catalog/models.yaml)"
if python3 scripts/gen-catalog.py --check; then
  ok "catalog valid, generated files current"
else
  bad "catalog (run: python3 scripts/gen-catalog.py)"
fi

echo "==> projects (projects/*.yaml)"
if python3 scripts/gen-projects.py --check; then
  ok "projects valid, generated files current"
else
  bad "projects (run: python3 scripts/gen-projects.py)"
fi

echo "==> opa (policies/)"
if have opa; then
  # Every directory under policies/ is one bundle (opa-policy values.yaml
  # bundles), and OPA loads them together: the Rego in gateway, the
  # per-project data in gateway-projects (the project registry publishes it;
  # this directory is the snapshot the import came from). The tests need both.
  dirs=()
  for dir in policies/*/; do
    dir="${dir%/}"
    dirs+=("$dir")
    if opa check --strict "$dir" >/dev/null; then ok "opa check $dir"; else bad "opa check $dir"; fi
    if [[ -z "$(opa fmt --list "$dir")" ]]; then ok "opa fmt $dir"; else bad "opa fmt $dir (run: opa fmt -w $dir)"; fi
  done
  if opa test "${dirs[@]}" >/dev/null; then ok "opa test ${dirs[*]}"; else bad "opa test ${dirs[*]}"; opa test "${dirs[@]}" || true; fi
  # Build each bundle as the builders do (tests left out, roots from its .manifest)
  # and activate them together, as OPA does: data outside a bundle's roots, or
  # two bundles claiming the same root, fails here instead of in the cluster.
  bundle_tmp="$(mktemp -d)"
  bundle_args=()
  built=true
  for dir in "${dirs[@]}"; do
    out="$bundle_tmp/$(basename "$dir").tar.gz"
    if err="$(opa build -b "$dir" --ignore '*_test.rego' -o "$out" 2>&1)"; then
      bundle_args+=(-b "$out")
    else
      built=false
      bad "opa build $dir"; echo "$err"
    fi
  done
  if [[ "$built" == true ]]; then
    if err="$(opa eval "${bundle_args[@]}" --fail 'true' 2>&1)"; then
      ok "bundles load together (roots disjoint)"
    else
      bad "bundles load together"; echo "$err"
    fi
  fi
  rm -rf "$bundle_tmp"
else
  skip "opa not installed (policy tests skipped)"
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
