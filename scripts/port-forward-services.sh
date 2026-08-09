#!/usr/bin/env bash
set -euo pipefail

NS="mini-platform"
ARGO_NS="argocd"
PID_DIR="/tmp/mini-platform-port-forwards"
VAULT_INIT_FILE="${VAULT_INIT_FILE:-$HOME/.vault-mini-platform-init.json}"
mode="local"
bind_address=""
ACTION="start"
SHOW_CREDENTIALS="true"

services=()
credentials=()

usage() {
  cat >&2 <<EOF
Usage: $0 [start|stop|restart] [options]

Options:
  --mode local|lan              Exposure mode. Default: local
  --address <ip>                Address printed for service URLs in LAN mode.
                                Default: auto-detected host LAN IP
  --namespace <name>            Platform namespace. Default: mini-platform
  --argocd-namespace <name>     Argo CD namespace. Default: argocd
  --pid-dir <path>              PID and log directory. Default: /tmp/mini-platform-port-forwards
  --no-credentials              Skip the credentials table. Use when the output
                                goes into a screenshare, a log, or an issue.
  -h, --help                    Show this help
EOF
}

reject_removed_env_vars() {
  local removed_vars=()
  printenv PORT_FORWARD_MODE >/dev/null 2>&1 && removed_vars+=("PORT_FORWARD_MODE")
  printenv LOCAL_FORWARD_ADDRESS >/dev/null 2>&1 && removed_vars+=("LOCAL_FORWARD_ADDRESS")
  printenv LAN_FORWARD_ADDRESS >/dev/null 2>&1 && removed_vars+=("LAN_FORWARD_ADDRESS")
  printenv FORWARD_ADDRESS >/dev/null 2>&1 && removed_vars+=("FORWARD_ADDRESS")
  printenv REMOTE_HOST >/dev/null 2>&1 && removed_vars+=("REMOTE_HOST")
  printenv REMOTE_MODE >/dev/null 2>&1 && removed_vars+=("REMOTE_MODE")
  printenv REMOTE_FORWARD_ADDRESS >/dev/null 2>&1 && removed_vars+=("REMOTE_FORWARD_ADDRESS")
  printenv REMOTE_PID_DIR >/dev/null 2>&1 && removed_vars+=("REMOTE_PID_DIR")
  printenv SSH_OPTS >/dev/null 2>&1 && removed_vars+=("SSH_OPTS")

  if [[ "${#removed_vars[@]}" -gt 0 ]]; then
    printf 'Environment-based exposure configuration was removed. Use script parameters instead.\n' >&2
    printf 'Run this script on the host that runs the services.\n' >&2
    printf 'Unsupported variable(s): %s\n' "${removed_vars[*]}" >&2
    exit 1
  fi
}

require_value() {
  local option="${1:-}" value="${2:-}"
  if [[ -z "$value" || "$value" == -* ]]; then
    printf 'Missing value for %s\n' "$option" >&2
    usage
    exit 1
  fi
}

parse_args() {
  local action_seen="false"
  while [[ "$#" -gt 0 ]]; do
    case "$1" in
      start|stop|restart)
        if [[ "$action_seen" == "true" ]]; then
          printf 'Only one action can be specified.\n' >&2
          usage
          exit 1
        fi
        ACTION="$1"
        action_seen="true"
        shift
        ;;
      --no-credentials)
        SHOW_CREDENTIALS="false"
        shift
        ;;
      --mode)
        require_value "$1" "${2:-}"
        mode="$2"
        shift 2
        ;;
      --mode=*)
        mode="${1#*=}"
        require_value "--mode" "$mode"
        shift
        ;;
      --address)
        require_value "$1" "${2:-}"
        bind_address="$2"
        shift 2
        ;;
      --address=*)
        bind_address="${1#*=}"
        require_value "--address" "$bind_address"
        shift
        ;;
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
      --pid-dir)
        require_value "$1" "${2:-}"
        PID_DIR="$2"
        shift 2
        ;;
      --pid-dir=*)
        PID_DIR="${1#*=}"
        require_value "--pid-dir" "$PID_DIR"
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
}

validate_args() {
  case "$mode" in
    local|lan)
      ;;
    *)
      printf 'Usage: --mode must be local or lan.\n' >&2
      exit 1
      ;;
  esac
}

init_services() {
  services=(
    "Argo CD|$ARGO_NS|svc/argocd-server|8080|80"
    "Open WebUI|$NS|svc/open-webui|3000|80"
    "Langfuse|$NS|svc/langfuse-web|3001|3000"
    "Grafana|$NS|svc/grafana|3002|80"
    "LiteLLM|$NS|svc/litellm|4000|4000"
    "MLflow|$NS|svc/mlflow-tracking|5000|80"
    "JupyterHub|$NS|svc/proxy-public|8000|80"
    "Superset|$NS|svc/superset|8088|8088"
    "Keycloak|$NS|svc/keycloak|8090|80"
    "MinIO Console|$NS|svc/minio-console|9001|9001"
    # 8081 locally because Argo CD already holds 8080; the UI itself listens on
    # 8080 in-cluster.
    "kagent|$NS|svc/kagent-ui|8081|8080"
  )
}

# label|source|location|user|password-field
#
# Vault stays the system of record -- nothing is cached or copied here, each
# value is read back out at print time. A `@field` username means the username
# itself lives in the secret rather than being fixed by the chart.
#
# Argo CD is the one entry not backed by Vault: its initial admin password is
# generated by the Argo CD chart into a Kubernetes Secret, so it is read from
# there instead.
init_credentials() {
  credentials=(
    "Argo CD|k8s|$ARGO_NS/argocd-initial-admin-secret|admin|password"
    "Langfuse|vault|mini-platform/langfuse-init-user|@LANGFUSE_INIT_USER_EMAIL|LANGFUSE_INIT_USER_PASSWORD"
    "Grafana|vault|mini-platform/grafana-admin|@admin-user|admin-password"
    "LiteLLM|vault|mini-platform/litellm-master-key|(bearer token)|PROXY_MASTER_KEY"
    "MLflow|vault|mini-platform/mlflow-auth|@admin-user|admin-password"
    "Superset|vault|mini-platform/superset-env|admin|SUPERSET_ADMIN_PASSWORD"
    "Keycloak|vault|mini-platform/keycloak-admin|admin|admin-password"
    "MinIO Console|vault|mini-platform/minio-root-credentials|@rootUser|rootPassword"
  )
}

# Root token from the environment first, else the init file deploy-minikube.sh
# wrote. Missing is not fatal -- the port forwards are the point, credentials
# are a convenience on top.
resolve_vault_token() {
  if [[ -n "${VAULT_TOKEN:-}" ]]; then
    printf '%s' "$VAULT_TOKEN"
    return 0
  fi
  if [[ -f "$VAULT_INIT_FILE" ]] && command -v jq >/dev/null 2>&1; then
    jq -r '.root_token // empty' "$VAULT_INIT_FILE" 2>/dev/null
  fi
}

vault_field() {
  local path="$1" field="$2"
  kubectl -n "$NS" exec vault-0 -- env \
    VAULT_ADDR=http://127.0.0.1:8200 \
    VAULT_TOKEN="$vault_token" \
    vault kv get -field="$field" "$path" 2>/dev/null || true
}

k8s_field() {
  local location="$1" field="$2" ns="${1%%/*}" name="${1##*/}"
  : "$location"
  kubectl -n "$ns" get secret "$name" -o "jsonpath={.data.$field}" 2>/dev/null |
    base64 -d 2>/dev/null || true
}

print_credentials() {
  local spec label source location user field value vault_token vault_sealed

  printf '\nCredentials\n'

  vault_token="$(resolve_vault_token)"
  # Not `.sealed // true`: jq's `//` fires on false as well as null, so that
  # form reports a healthy unsealed Vault as sealed. Treat only a missing field
  # (Vault unreachable) as sealed.
  vault_sealed="$(kubectl -n "$NS" exec vault-0 -- env VAULT_ADDR=http://127.0.0.1:8200 \
    vault status -format=json 2>/dev/null |
    jq -r 'if .sealed == null then "true" else (.sealed | tostring) end' 2>/dev/null ||
    printf 'true')"
  [[ -n "$vault_sealed" ]] || vault_sealed="true"

  if [[ "$vault_sealed" == "true" ]]; then
    printf '  Vault is sealed; unseal it to read logins.\n'
    return 0
  fi
  if [[ -z "$vault_token" ]]; then
    printf '  No Vault token. Set VAULT_TOKEN or restore %s.\n' "$VAULT_INIT_FILE"
    return 0
  fi

  for spec in "${credentials[@]}"; do
    IFS='|' read -r label source location user field <<<"$spec"

    if [[ "$source" == vault ]]; then
      value="$(vault_field "$location" "$field")"
      [[ "$user" == @* ]] && user="$(vault_field "$location" "${user#@}")"
    else
      value="$(k8s_field "$location" "$field")"
      [[ "$user" == @* ]] && user="$(k8s_field "$location" "${user#@}")"
    fi

    if [[ -z "$value" ]]; then
      printf '  %-14s %-26s <unavailable>\n' "$label" "$user"
    else
      printf '  %-14s %-26s %s\n' "$label" "$user" "$value"
    fi
  done

  # Services with no stored credential to look up.
  printf '  %-14s %s\n' "JupyterHub" "any username, no password (dummy authenticator)"
  printf '  %-14s %s\n' "Open WebUI" "first account to sign up becomes admin"
  printf '  %-14s %s\n' "kagent" "no authentication configured"
}

detect_lan_ip() {
  local ip
  if command -v ip >/dev/null 2>&1; then
    ip="$(ip route get 1.1.1.1 2>/dev/null | awk '/src/ { for (i = 1; i <= NF; i++) if ($i == "src") { print $(i + 1); exit } }')"
    if [[ -n "$ip" ]]; then
      printf '%s\n' "$ip"
      return 0
    fi

    ip="$(hostname -I 2>/dev/null | awk '{ print $1 }')"
    if [[ -n "$ip" ]]; then
      printf '%s\n' "$ip"
      return 0
    fi
  fi

  if command -v route >/dev/null 2>&1; then
    ip="$(route -n get default 2>/dev/null | awk '/interface:/ { print $2; exit }' | xargs -I{} ipconfig getifaddr {} 2>/dev/null || true)"
    if [[ -n "$ip" ]]; then
      printf '%s\n' "$ip"
      return 0
    fi
  fi

  return 1
}

resolve_access_address() {
  if [[ -n "$bind_address" ]]; then
    printf '%s\n' "$bind_address"
    return 0
  fi

  case "$mode" in
    local)
      printf '127.0.0.1\n'
      ;;
    lan)
      bind_address="$(detect_lan_ip || true)"
      if [[ -z "$bind_address" ]]; then
        printf 'Unable to detect LAN IP. Use --address <host-lan-ip>.\n' >&2
        exit 1
      fi
      printf '%s\n' "$bind_address"
      ;;
  esac
}

resolve_listen_address() {
  case "$mode" in
    local)
      printf '127.0.0.1\n'
      ;;
    lan)
      printf '0.0.0.0\n'
      ;;
  esac
}

stop_forwards() {
  local pid_file pid
  shopt -s nullglob
  for pid_file in "$PID_DIR"/*.pid; do
    pid="$(cat "$pid_file")"
    if kill -0 "$pid" 2>/dev/null; then
      kill "$pid"
    fi
    rm -f "$pid_file"
  done
  shopt -u nullglob
}

wait_for_forward() {
  local pid="$1" log_file="$2" waited=0
  while [[ "$waited" -lt 20 ]]; do
    if ! kill -0 "$pid" 2>/dev/null; then
      printf 'kubectl port-forward failed. Log: %s\n' "$log_file" >&2
      sed -n '1,80p' "$log_file" >&2 || true
      return 1
    fi
    if grep -q 'Forwarding from' "$log_file" 2>/dev/null; then
      return 0
    fi
    sleep 0.1
    waited=$((waited + 1))
  done

  if kill -0 "$pid" 2>/dev/null; then
    return 0
  fi

  printf 'kubectl port-forward failed. Log: %s\n' "$log_file" >&2
  sed -n '1,80p' "$log_file" >&2 || true
  return 1
}

start_kubectl_forwards() {
  local access_address listen_address spec name namespace resource local_port remote_port key pid_file log_file pid
  access_address="$(resolve_access_address)"
  listen_address="$(resolve_listen_address)"

  command -v kubectl >/dev/null 2>&1 || {
    printf 'required command not found: kubectl\n' >&2
    exit 1
  }

  mkdir -p "$PID_DIR"
  for spec in "${services[@]}"; do
    IFS='|' read -r name namespace resource local_port remote_port <<<"$spec"
    key="${name// /-}"
    pid_file="$PID_DIR/$key.pid"
    log_file="$PID_DIR/$key.log"
    if [[ -f "$pid_file" ]] && kill -0 "$(cat "$pid_file")" 2>/dev/null; then
      continue
    fi
    nohup kubectl -n "$namespace" port-forward --address "$listen_address" "$resource" "$local_port:$remote_port" \
      >"$log_file" 2>&1 < /dev/null &
    pid="$!"
    if wait_for_forward "$pid" "$log_file"; then
      printf '%s\n' "$pid" > "$pid_file"
      printf '%-14s http://%s:%s\n' "$name" "$access_address" "$local_port"
    else
      rm -f "$pid_file"
      exit 1
    fi
  done
}

reject_removed_env_vars
parse_args "$@"
validate_args
init_services
init_credentials
mkdir -p "$PID_DIR"

case "$ACTION" in
  stop)
    stop_forwards
    printf 'Stopped Mini Platform port forwards.\n'
    exit 0
    ;;
  restart)
    stop_forwards
    ;;
  start)
    ;;
  *)
    printf 'Unknown action: %s\n' "$ACTION" >&2
    usage
    exit 1
    ;;
esac

start_kubectl_forwards

if [[ "$SHOW_CREDENTIALS" == "true" ]]; then
  print_credentials
fi

printf '\nLogs and PIDs: %s\n' "$PID_DIR"
