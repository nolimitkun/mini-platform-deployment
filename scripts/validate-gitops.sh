#!/usr/bin/env bash
# Validate this deployment repo's GitOps charts and scripts without a cluster.
#
# Runs the same checks as CI so failures can be reproduced locally:
#   - every valuesFile referenced by the app-of-apps exists locally
#   - every charts/* chartPath exists in the charts repo checkout (if available)
#   - every first-party chartPath (minikube/gitops/*) exists locally
#   - the three gitops/ charts lint and render
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

GITOPS_CHARTS=(
  minikube/gitops/mini-platform
  minikube/gitops/vault-resources
  minikube/gitops/ingress-resources
)
APP_OF_APPS=minikube/gitops/mini-platform
# The app-of-apps chart requires all four source parameters to render.
APP_PARAMS=(
  --set chartsRepo=https://example.com/mini-platform.git
  --set chartsRevision=main
  --set deployRepo=https://example.com/mini-platform-deployment.git
  --set deployRevision=main
)

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

echo "==> Referenced valuesFile exists"
while read -r path; do
  [[ -n "$path" ]] || continue
  if [[ -e "$path" ]]; then ok "$path"; else bad "missing: $path"; fi
done < <(awk '/^[[:space:]]*valuesFile:[[:space:]]/ {print $2}' "$APP_OF_APPS/values.yaml")

echo "==> helm lint"
for c in "${GITOPS_CHARTS[@]}"; do
  if helm lint "$c" "${APP_PARAMS[@]}" >/dev/null 2>&1; then ok "$c"; else
    bad "$c"; helm lint "$c" "${APP_PARAMS[@]}" || true
  fi
done

echo "==> helm template + kubeconform"
RENDER_DIR="$(mktemp -d)"
trap 'rm -rf "$RENDER_DIR"' EXIT
for c in "${GITOPS_CHARTS[@]}"; do
  out="$RENDER_DIR/$(basename "$c").yaml"
  if helm template "$(basename "$c")" "$c" "${APP_PARAMS[@]}" > "$out" 2>"$out.err"; then
    ok "render $c"
  else
    bad "render $c"; cat "$out.err"; continue
  fi
  if have kubeconform; then
    if kubeconform -strict -ignore-missing-schemas -summary "$out" >/dev/null 2>&1; then
      ok "kubeconform $c"
    else
      bad "kubeconform $c"; kubeconform -strict -ignore-missing-schemas "$out" || true
    fi
  fi
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
