#!/usr/bin/env bash
# Prints the path of a checkout of the gateway policy (nolimitkun/gateway-policy) at
# the commit this repo pins (policyRevision in minikube/gitops/mini-platform/values.yaml).
# GATEWAY_POLICY_DIR, if set, is used as it is instead (a local checkout).
# The checkout is cached under ${XDG_CACHE_HOME:-~/.cache}/gateway-policy/<commit>.
set -euo pipefail
if [[ -n "${GATEWAY_POLICY_DIR:-}" ]]; then
  echo "$GATEWAY_POLICY_DIR"
  exit 0
fi
root="$(cd "$(dirname "$0")/.." && pwd)"
values="$root/minikube/gitops/mini-platform/values.yaml"
repo="$(awk '$1 == "policyRepo:" { print $2 }' "$values")"
rev="$(awk '$1 == "policyRevision:" { print $2 }' "$values")"
[[ -n "$repo" && -n "$rev" ]] || { echo "policyRepo or policyRevision not found in $values" >&2; exit 1; }
dir="${XDG_CACHE_HOME:-$HOME/.cache}/gateway-policy/$rev"
if [[ ! -d "$dir/.git" ]]; then
  tmp="$(mktemp -d)"
  git -C "$tmp" init -q
  git -C "$tmp" fetch -q --depth 1 "$repo" "$rev"
  git -C "$tmp" checkout -q FETCH_HEAD
  mkdir -p "$(dirname "$dir")"
  mv "$tmp" "$dir"
fi
echo "$dir"
