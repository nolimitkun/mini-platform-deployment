#!/usr/bin/env bash
# Point the Google API hostnames LiteLLM's Google speech models (chirp-3,
# tts-chirp-3-hd, the Gemini TTS and Live models) use at Private Service Connect
# endpoints reached over the mini-cloud VPN, so speech traffic and the keyless
# token exchange stay off the internet.
#
#   scripts/gcp-psc-dns.sh 10.48.64.2               # add or update
#   scripts/gcp-psc-dns.sh 10.48.64.2 10.48.65.2    # also the regional endpoint
#   scripts/gcp-psc-dns.sh --remove                 # back to public DNS
#
# The first IP is the all-apis endpoint (mini-cloud output psc_googleapis_ip).
# The optional second is the regional endpoint for Vertex AI's eu multi-region
# (psc_rep_ips): its two-level *.eu.rep.googleapis.com name is outside the
# all-apis endpoint's certificate, so it has an endpoint of its own.
#
# Adds a separate `googleapis.com:53` server block to CoreDNS that answers only
# the names below and forwards every other googleapis.com name as before. Like
# the keycloak.test rewrite, CoreDNS is outside Argo CD's reconciliation, so
# this is an imperative step; deploy-minikube.sh runs it when GCP_PSC_IP is set
# (and passes GCP_PSC_EU_REP_IP as the second IP).
# Idempotent.
set -euo pipefail

HOSTS=(eu-speech.googleapis.com eu-texttospeech.googleapis.com europe-west1-aiplatform.googleapis.com
  sts.googleapis.com iamcredentials.googleapis.com)
REP_HOSTS=(aiplatform.eu.rep.googleapis.com)
MARKER="# gcp-psc-dns"

usage() { echo "usage: $0 <psc-ip> [<eu-rep-ip>] | --remove" >&2; exit 2; }
ipv4='^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'
IP=""
REP_IP=""
if [[ "${1:-}" == --remove ]]; then
  [[ $# -eq 1 ]] || usage
else
  [[ $# -eq 1 || $# -eq 2 ]] || usage
  IP="$1"
  REP_IP="${2:-}"
  [[ "$IP" =~ $ipv4 ]] || usage
  [[ -z "$REP_IP" || "$REP_IP" =~ $ipv4 ]] || usage
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
  if [[ -n "$REP_IP" ]]; then
    for h in "${REP_HOSTS[@]}"; do
      block+="
       $REP_IP $h"
    done
  fi
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
  [[ -z "$REP_IP" ]] || echo "CoreDNS: ${REP_HOSTS[*]} -> $REP_IP"
else
  echo "CoreDNS: Google API hostnames back on public DNS."
fi
