#!/usr/bin/env bash
# Point the Google API hostnames LiteLLM's chirp-3 model uses at a Private
# Service Connect endpoint reached over the mini-cloud VPN, so Speech-to-Text
# traffic and the keyless token exchange stay off the internet.
#
#   scripts/gcp-psc-dns.sh 10.48.64.2      # add or update
#   scripts/gcp-psc-dns.sh --remove        # back to public DNS
#
# Adds a separate `googleapis.com:53` server block to CoreDNS that answers only
# the names below and forwards every other googleapis.com name as before. Like
# the keycloak.test rewrite, CoreDNS is outside Argo CD's reconciliation, so
# this is an imperative step; deploy-minikube.sh runs it when GCP_PSC_IP is set.
# Idempotent.
set -euo pipefail

HOSTS=(eu-speech.googleapis.com sts.googleapis.com iamcredentials.googleapis.com)
MARKER="# gcp-psc-dns"

usage() { echo "usage: $0 <psc-ip> | --remove" >&2; exit 2; }
[[ $# -eq 1 ]] || usage
IP=""
if [[ "$1" != --remove ]]; then
  IP="$1"
  [[ "$IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || usage
fi

corefile="$(kubectl -n kube-system get configmap coredns -o jsonpath='{.data.Corefile}')"

# Drop any block this script added before, then append the current one.
stripped="$(printf '%s\n' "$corefile" | awk -v m="$MARKER" '
  $0 == m { skip = 1; next }
  skip && /^}/ { skip = 0; next }
  !skip { print }
')"
patched="$stripped"
if [[ -n "$IP" ]]; then
  block="$MARKER
googleapis.com:53 {
    hosts {"
  for h in "${HOSTS[@]}"; do
    block+="
       $IP $h"
  done
  block+="
       fallthrough
    }
    forward . /etc/resolv.conf
    cache 30
}"
  patched="$stripped
$block"
fi

if [[ "$patched" == "$corefile" ]]; then
  echo "CoreDNS already up to date."
  exit 0
fi

# Patch rather than apply: the ConfigMap is minikube's.
kubectl -n kube-system patch configmap coredns --type merge \
  -p "$(jq -n --arg corefile "$patched" '{data: {Corefile: $corefile}}')" >/dev/null
kubectl -n kube-system rollout restart deployment/coredns >/dev/null
kubectl -n kube-system rollout status deployment/coredns --timeout=180s >/dev/null
if [[ -n "$IP" ]]; then
  echo "CoreDNS: ${HOSTS[*]} -> $IP"
else
  echo "CoreDNS: Google API hostnames back on public DNS."
fi
