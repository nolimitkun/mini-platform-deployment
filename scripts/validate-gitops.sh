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
#
# The vendored charts live in a separate repository. Point CHARTS_DIR at a local
# checkout of it (default: ../mini-platform) to verify charts/* paths resolve;
# when absent those checks are skipped, not failed.
#
# Tools used if present: helm (required), kubeconform (optional), shellcheck
# (optional). Missing optional tools are reported and skipped, not failed.
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

echo
if [[ "$FAIL" -eq 0 ]]; then echo "All checks passed."; else echo "Some checks FAILED." >&2; fi
exit "$FAIL"
