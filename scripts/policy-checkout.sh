#!/usr/bin/env bash
# Prints the path of a checkout of the gateway policy (nolimitkun/gateway-policy) at
# the head of its main branch, for CI's wiring checks and the Vault bootstrap's
# renderer. (Nothing here pins the policy: the project registry publishes what is
# approved, the gateway's routes included.) GATEWAY_POLICY_DIR, if set, is used as
# it is instead (a local checkout), and GATEWAY_POLICY_REF picks another branch.
# The checkout is cached under ${XDG_CACHE_HOME:-~/.cache}/gateway-policy/<commit>.
set -euo pipefail
if [[ -n "${GATEWAY_POLICY_DIR:-}" ]]; then
  echo "$GATEWAY_POLICY_DIR"
  exit 0
fi
repo="${GATEWAY_POLICY_REPO:-https://github.com/nolimitkun/gateway-policy.git}"
ref="${GATEWAY_POLICY_REF:-main}"
rev="$(git ls-remote "$repo" "refs/heads/$ref" | cut -f1)"
[[ -n "$rev" ]] || { echo "no branch $ref in $repo" >&2; exit 1; }
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
