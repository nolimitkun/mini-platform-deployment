#!/usr/bin/env bash
set -euo pipefail

NS="${NS:-mini-platform}"
ARGO_NS="${ARGO_NS:-argocd}"
ROOT_APP="${ROOT_APP:-mini-platform}"
DEPLOY_REPO_URL="${DEPLOY_REPO_URL:-}"
DEPLOY_REVISION="${DEPLOY_REVISION:-}"
CHARTS_REPO_URL="${CHARTS_REPO_URL:-}"
CHARTS_REVISION="${CHARTS_REVISION:-}"
ROOT_APP_PATH="${ROOT_APP_PATH:-minikube/gitops/mini-platform}"
SMOKE=false
SMOKE_PORT="${SMOKE_PORT:-18080}"

usage() {
  cat <<'EOF'
Usage: scripts/check-local-deployment.sh [options]

Checks the local Mini Platform deployment:
  - root Argo CD Application source wiring
  - all Argo CD Applications are Synced and Healthy
  - all non-job platform pods are Running and ready
  - all VaultStaticSecret resources are synced, healthy, and ready

Options:
  --namespace NAME             Platform namespace. Default: mini-platform
  --argocd-namespace NAME      Argo CD namespace. Default: argocd
  --root-app NAME              Root Application name. Default: mini-platform
  --charts-repo-url URL        Expected charts repo URL. Default: accept live value
  --charts-revision REV        Expected charts repo revision. Default: accept live value
  --deploy-repo-url URL        Expected deployment repo URL. Default: accept live value
  --deploy-revision REV        Expected deployment repo revision. Default: accept live value
  --smoke-open-webui           Smoke-test Open WebUI through a temporary port-forward
  --smoke-port PORT            Host port for the smoke test. Default: 18080
  -h, --help                   Show this help
EOF
}

log() {
  printf '[check] %s\n' "$*"
}

fail() {
  printf '[check] ERROR: %s\n' "$*" >&2
  exit 1
}

need() {
  command -v "$1" >/dev/null 2>&1 || fail "required command not found: $1"
}

require_value() {
  local option="${1:-}" value="${2:-}"
  if [[ -z "$value" || "$value" == -* ]]; then
    printf 'Missing value for %s\n' "$option" >&2
    usage
    exit 1
  fi
}

while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --namespace)
      require_value "$1" "${2:-}"
      NS="$2"
      shift 2
      ;;
    --namespace=*)
      NS="${1#*=}"
      require_value "--namespace" "$NS"
      shift
      ;;
    --argocd-namespace)
      require_value "$1" "${2:-}"
      ARGO_NS="$2"
      shift 2
      ;;
    --argocd-namespace=*)
      ARGO_NS="${1#*=}"
      require_value "--argocd-namespace" "$ARGO_NS"
      shift
      ;;
    --root-app)
      require_value "$1" "${2:-}"
      ROOT_APP="$2"
      shift 2
      ;;
    --root-app=*)
      ROOT_APP="${1#*=}"
      require_value "--root-app" "$ROOT_APP"
      shift
      ;;
    --charts-repo-url)
      require_value "$1" "${2:-}"
      CHARTS_REPO_URL="$2"
      shift 2
      ;;
    --charts-repo-url=*)
      CHARTS_REPO_URL="${1#*=}"
      require_value "--charts-repo-url" "$CHARTS_REPO_URL"
      shift
      ;;
    --charts-revision)
      require_value "$1" "${2:-}"
      CHARTS_REVISION="$2"
      shift 2
      ;;
    --charts-revision=*)
      CHARTS_REVISION="${1#*=}"
      require_value "--charts-revision" "$CHARTS_REVISION"
      shift
      ;;
    --deploy-repo-url)
      require_value "$1" "${2:-}"
      DEPLOY_REPO_URL="$2"
      shift 2
      ;;
    --deploy-repo-url=*)
      DEPLOY_REPO_URL="${1#*=}"
      require_value "--deploy-repo-url" "$DEPLOY_REPO_URL"
      shift
      ;;
    --deploy-revision)
      require_value "$1" "${2:-}"
      DEPLOY_REVISION="$2"
      shift 2
      ;;
    --deploy-revision=*)
      DEPLOY_REVISION="${1#*=}"
      require_value "--deploy-revision" "$DEPLOY_REVISION"
      shift
      ;;
    --smoke-open-webui)
      SMOKE=true
      shift
      ;;
    --smoke-port)
      require_value "$1" "${2:-}"
      SMOKE_PORT="$2"
      shift 2
      ;;
    --smoke-port=*)
      SMOKE_PORT="${1#*=}"
      require_value "--smoke-port" "$SMOKE_PORT"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      printf 'Unknown argument: %s\n' "$1" >&2
      usage
      exit 1
      ;;
  esac
done

need kubectl
need jq

log "Checking root Argo CD Application wiring"
root_json="$(kubectl -n "$ARGO_NS" get application "$ROOT_APP" -o json)"
root_errors="$(jq -r \
  --arg deploy_repo "$DEPLOY_REPO_URL" --arg deploy_rev "$DEPLOY_REVISION" \
  --arg charts_repo "$CHARTS_REPO_URL" --arg charts_rev "$CHARTS_REVISION" \
  --arg root_path "$ROOT_APP_PATH" '
  def param($name): (.spec.source.helm.parameters // [] | map(select(.name == $name)) | first | .value // "");
  def enforce($actual; $expected; $label):
    if $expected != "" and $actual != $expected then "\($label) is \($actual // "<missing>")" else empty end;
  [
    if .spec.source.path != $root_path then "root source path is \(.spec.source.path // "<missing>")" else empty end,
    if (.spec.source.repoURL // "") == "" then "root source repoURL is <missing>" else empty end,
    if (.spec.source.targetRevision // "") == "" then "root source targetRevision is <missing>" else empty end,
    if param("chartsRepo") == "" then "chartsRepo parameter is <missing>" else empty end,
    if param("chartsRevision") == "" then "chartsRevision parameter is <missing>" else empty end,
    if param("deployRepo") == "" then "deployRepo parameter is <missing>" else empty end,
    if param("deployRevision") == "" then "deployRevision parameter is <missing>" else empty end,
    if param("deployRepo") != "" and .spec.source.repoURL != param("deployRepo") then "deployRepo parameter is \(param("deployRepo")) but root source repoURL is \(.spec.source.repoURL // "<missing>")" else empty end,
    if param("deployRevision") != "" and .spec.source.targetRevision != param("deployRevision") then "deployRevision parameter is \(param("deployRevision")) but root source targetRevision is \(.spec.source.targetRevision // "<missing>")" else empty end,
    enforce(.spec.source.repoURL; $deploy_repo; "root source repoURL"),
    enforce(.spec.source.targetRevision; $deploy_rev; "root source targetRevision"),
    enforce(param("chartsRepo"); $charts_repo; "chartsRepo parameter"),
    enforce(param("chartsRevision"); $charts_rev; "chartsRevision parameter"),
    enforce(param("deployRepo"); $deploy_repo; "deployRepo parameter"),
    enforce(param("deployRevision"); $deploy_rev; "deployRevision parameter")
  ] | .[]' <<< "$root_json")"
if [[ -n "$root_errors" ]]; then
  printf '%s\n' "$root_errors" >&2
  fail "root Application source wiring drifted"
fi

log "Checking Argo CD Applications"
app_errors="$(kubectl -n "$ARGO_NS" get applications -o json |
  jq -r '.items[] |
    select((.status.sync.status // "") != "Synced" or (.status.health.status // "") != "Healthy") |
    "\(.metadata.name): sync=\(.status.sync.status // "<missing>") health=\(.status.health.status // "<missing>")"')"
if [[ -n "$app_errors" ]]; then
  printf '%s\n' "$app_errors" >&2
  fail "one or more Argo CD Applications are not Synced and Healthy"
fi

log "Checking platform pods"
pod_errors="$(kubectl -n "$NS" get pods -o json |
  jq -r '.items[] |
    select(.status.phase != "Succeeded") |
    select(.status.phase != "Running" or any(.status.containerStatuses[]?; .ready != true)) |
    "\(.metadata.name): phase=\(.status.phase) ready=\((.status.containerStatuses // []) | map(.ready) | tostring)"')"
if [[ -n "$pod_errors" ]]; then
  printf '%s\n' "$pod_errors" >&2
  fail "one or more non-job platform pods are not ready"
fi

log "Checking VaultStaticSecrets"
vss_errors="$(kubectl -n "$NS" get vaultstaticsecrets -o json |
  jq -r '.items[] |
    . as $item |
    [
      .status.conditions[]? |
      select((.type == "Ready" or .type == "Healthy" or .type == "Synced") and .status != "True") |
      "\($item.metadata.name): \(.type)=\(.status) \(.reason // "")"
    ] | .[]')"
if [[ -n "$vss_errors" ]]; then
  printf '%s\n' "$vss_errors" >&2
  fail "one or more VaultStaticSecrets are not synced, healthy, and ready"
fi

if [[ "$SMOKE" == true ]]; then
  need curl
  log "Smoke-testing Open WebUI through port-forward on 127.0.0.1:$SMOKE_PORT"
  kubectl -n "$NS" port-forward svc/open-webui "$SMOKE_PORT:80" >/tmp/mini-platform-open-webui-smoke.log 2>&1 &
  pf_pid="$!"
  cleanup_smoke() {
    kill "$pf_pid" >/dev/null 2>&1 || true
  }
  trap cleanup_smoke EXIT
  sleep 2
  curl -fsS -I --max-time 8 "http://127.0.0.1:$SMOKE_PORT" >/dev/null ||
    fail "Open WebUI smoke test failed"
  cleanup_smoke
  trap - EXIT
fi

log "Deployment checks passed."
