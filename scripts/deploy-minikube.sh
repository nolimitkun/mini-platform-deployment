#!/usr/bin/env bash
set -euo pipefail

PROFILE="${PROFILE:-mini-platform}"
NS="${NS:-mini-platform}"
ARGO_NS="${ARGO_NS:-argocd}"
CHARTS_REPO_URL="${CHARTS_REPO_URL:-https://github.com/nolimitkun/mini-platform.git}"
CHARTS_REVISION="${CHARTS_REVISION:-main}"
DEPLOY_REPO_URL="${DEPLOY_REPO_URL:-https://github.com/nolimitkun/mini-platform-deployment.git}"
DEPLOY_REVISION="${DEPLOY_REVISION:-main}"
VAULT_INIT_FILE="${VAULT_INIT_FILE:-$HOME/.vault-mini-platform-init.json}"
HF_TOKEN_FILE="${HF_TOKEN_FILE:-$HOME/.cache/huggingface/token}"
SOURCE_MODE=remote
GPU=true
RESET=false
ROTATE_SECRETS=false
PRELOAD_IMAGES="${PRELOAD_IMAGES:-true}"
WAIT_FOR_WORKLOADS="${WAIT_FOR_WORKLOADS:-true}"
WORKLOAD_TIMEOUT="${WORKLOAD_TIMEOUT:-1800}"
PRELOAD_RECORD=""
RETRIED_PODS_FILE=""
RESTARTED_PENDING_PODS_FILE=""
OPERATOR_RESTARTED=false

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Vendored charts live in a sibling repository checkout. Argo CD pulls them from
# CHARTS_REPO_URL; this local path is only used to bootstrap Argo CD itself and,
# in --local-source mode, to serve the charts repo from inside the cluster.
CHARTS_DIR="${CHARTS_DIR:-$ROOT/../mini-platform}"

usage() {
  cat <<'EOF'
Usage: scripts/deploy-minikube.sh [options]

Options:
  --reset                 Delete and recreate the Minikube profile first.
  --local-source          Serve the committed charts and deployment checkouts
                          through an internal cluster-only Git service for Argo CD.
  --charts-repo-url URL   Git URL of the vendored charts repository.
  --charts-revision REV   Revision of the charts repository (default: main).
  --deploy-repo-url URL   Git URL of this deployment repository.
  --deploy-revision REV   Revision of the deployment repository (default: main).
  --charts-dir PATH       Local charts repo checkout (default: ../mini-platform).
  --no-gpu                Start Minikube without NVIDIA GPU passthrough.
  --rotate-secrets        Rewrite Vault application credentials on an existing
                          initialized Vault instance.
  --skip-image-preload    Do not load host-cached workload images into Minikube.
  --skip-workload-wait    Finish after Vault secret synchronization instead of
                          waiting for platform pods to become ready.
  --help                   Show this help.

The local-source mode requires a clean Git working tree in both this repo and
the charts repo, because Argo CD reads Git commits, not uncommitted files.
EOF
}

log() {
  printf '[deploy] %s\n' "$*"
}

warn() {
  printf '[deploy] WARNING: %s\n' "$*" >&2
}

fail() {
  printf '[deploy] ERROR: %s\n' "$*" >&2
  exit 1
}

need() {
  command -v "$1" >/dev/null 2>&1 || fail "required command not found: $1"
}

cleanup() {
  [[ -z "$PRELOAD_RECORD" ]] || rm -f "$PRELOAD_RECORD"
  [[ -z "$RETRIED_PODS_FILE" ]] || rm -f "$RETRIED_PODS_FILE"
  [[ -z "$RESTARTED_PENDING_PODS_FILE" ]] || rm -f "$RESTARTED_PENDING_PODS_FILE"
}

trap cleanup EXIT

preload_cached_pod_images() {
  [[ "$PRELOAD_IMAGES" == true ]] || return 0

  local image image_file count
  count=0
  image_file="$(mktemp)"
  if ! kubectl -n "$NS" get pods -o json 2>/dev/null |
    jq -r '.items[].spec.initContainers[]?.image, .items[].spec.containers[].image' |
    sort -u > "$image_file"; then
    rm -f "$image_file"
    return 0
  fi

  if [[ -z "$PRELOAD_RECORD" ]]; then
    PRELOAD_RECORD="$(mktemp)"
  fi
  while IFS= read -r image; do
    [[ -n "$image" ]] || continue
    grep -Fxq "$image" "$PRELOAD_RECORD" && continue
    if docker image inspect "$image" >/dev/null 2>&1; then
      log "Loading host-cached image into Minikube: $image"
      minikube image load -p "$PROFILE" "$image" >/dev/null
      printf '%s\n' "$image" >> "$PRELOAD_RECORD"
      count=$((count + 1))
    fi
  done < "$image_file"
  rm -f "$image_file"

  if [[ "$count" -gt 0 ]]; then
    log "Loaded $count host-cached workload images into Minikube"
  fi
}

restart_pending_operator_after_preload() {
  [[ "$PRELOAD_IMAGES" == true && "$OPERATOR_RESTARTED" == false &&
     -n "$PRELOAD_RECORD" && -s "$PRELOAD_RECORD" ]] || return 0

  local pod image pods should_restart
  pods="$(kubectl -n "$NS" get pods -o json 2>/dev/null |
    jq -r '.items[] |
      select(.metadata.name | startswith("vault-secrets-operator-controller-manager-")) |
      select(.status.phase == "Pending") |
      .metadata.name')"
  while IFS= read -r pod; do
    [[ -n "$pod" ]] || continue
    should_restart=false
    while IFS= read -r image; do
      if grep -Fxq "$image" "$PRELOAD_RECORD"; then
        should_restart=true
        break
      fi
    done < <(kubectl -n "$NS" get pod "$pod" -o json |
      jq -r '.spec.initContainers[]?.image, .spec.containers[].image')
    [[ "$should_restart" == true ]] || continue

    log "Restarting pending Vault Secrets Operator pod after image preload"
    kubectl -n "$NS" delete pod "$pod" --wait=false >/dev/null
    OPERATOR_RESTARTED=true
    break
  done <<< "$pods"
}

restart_pending_workload_pods() {
  [[ "$PRELOAD_IMAGES" == true && -n "$PRELOAD_RECORD" && -s "$PRELOAD_RECORD" ]] || return 0

  local pod image pods should_restart
  pods="$(kubectl -n "$NS" get pods -o json |
    jq -r '.items[] | select(.status.phase == "Pending") | .metadata.name')"
  [[ -n "$pods" ]] || return 0

  RESTARTED_PENDING_PODS_FILE="$(mktemp)"
  while IFS= read -r pod; do
    [[ -n "$pod" ]] || continue
    should_restart=false
    while IFS= read -r image; do
      if grep -Fxq "$image" "$PRELOAD_RECORD"; then
        should_restart=true
        break
      fi
    done < <(kubectl -n "$NS" get pod "$pod" -o json |
      jq -r '.spec.initContainers[]?.image, .spec.containers[].image')
    [[ "$should_restart" == true ]] && printf '%s\n' "$pod" >> "$RESTARTED_PENDING_PODS_FILE"
  done <<< "$pods"
  [[ -s "$RESTARTED_PENDING_PODS_FILE" ]] || return 0

  log "Restarting pending workload pods after image preload"
  while IFS= read -r pod; do
    kubectl -n "$NS" delete pod "$pod" --wait=false >/dev/null
  done < "$RESTARTED_PENDING_PODS_FILE"
  sleep 30

  while IFS= read -r pod; do
    [[ -n "$pod" ]] || continue
    if [[ -n "$(kubectl -n "$NS" get pod "$pod" -o jsonpath='{.metadata.deletionTimestamp}' 2>/dev/null || true)" ]]; then
      warn "Force-removing pod stuck terminating after restart: $pod"
      kubectl -n "$NS" delete pod "$pod" --force --grace-period=0 --wait=false >/dev/null
    fi
  done < "$RESTARTED_PENDING_PODS_FILE"
}

retry_failed_pods_once() {
  local pod retry_key pods
  if [[ -z "$RETRIED_PODS_FILE" ]]; then
    RETRIED_PODS_FILE="$(mktemp)"
  fi
  pods="$(kubectl -n "$NS" get pods -o json |
    jq -r '.items[] |
      select(.status.phase == "Failed") |
      [.metadata.name, (.metadata.ownerReferences[0].uid // .metadata.name)] |
      @tsv')"
  while IFS=$'\t' read -r pod retry_key; do
    [[ -n "$pod" ]] || continue
    grep -Fxq "$retry_key" "$RETRIED_PODS_FILE" && continue
    warn "Restarting failed startup pod once: $pod"
    printf '%s\n' "$retry_key" >> "$RETRIED_PODS_FILE"
    kubectl -n "$NS" delete pod "$pod" --wait=false >/dev/null
  done <<< "$pods"
}

workloads_ready() {
  kubectl -n "$NS" get pods -o json |
    jq -e '[.items[] |
      select(.status.phase != "Succeeded") |
      select(.status.phase != "Running" or
        any(.status.containerStatuses[]?; .ready != true))] |
      length == 0' >/dev/null
}

wait_for_workloads() {
  local deadline
  deadline=$((SECONDS + WORKLOAD_TIMEOUT))

  log "Waiting up to ${WORKLOAD_TIMEOUT}s for platform workloads to become ready"
  while [[ "$SECONDS" -lt "$deadline" ]]; do
    preload_cached_pod_images
    retry_failed_pods_once
    if workloads_ready; then
      log "All platform pods are ready or completed"
      return 0
    fi
    sleep 15
  done

  kubectl -n "$NS" get pods >&2 || true
  kubectl -n "$NS" get events --field-selector type=Warning --sort-by=.lastTimestamp 2>/dev/null |
    tail -n 25 >&2 || true
  fail "platform workloads did not become ready within ${WORKLOAD_TIMEOUT}s"
}

ensure_litellm_schema() {
  kubectl -n "$NS" get deployment litellm >/dev/null 2>&1 || return 0

  log "Verifying LiteLLM database schema"
  local pw exists pod deadline

  pw="$(kubectl -n "$NS" get secret litellm-dbcredentials \
    -o jsonpath='{.data.password}' 2>/dev/null | base64 -d || true)"
  if [[ -z "$pw" ]]; then
    warn "litellm-dbcredentials unavailable; skipping LiteLLM schema check"
    return 0
  fi

  exists="$(kubectl -n "$NS" exec postgresql-0 -c postgresql -- \
    env PGPASSWORD="$pw" psql -U litellm -d litellm -tAc \
    'select to_regclass('"'"'public."LiteLLM_UserTable"'"'"') is not null' \
    2>/dev/null | tr -d '[:space:]' || true)"
  if [[ "$exists" == t ]]; then
    log "LiteLLM schema already present"
    return 0
  fi

  warn "LiteLLM schema missing; applying Prisma migration (PreSync hook did not)"
  deadline=$((SECONDS + 300))
  pod=""
  while [[ "$SECONDS" -lt "$deadline" ]]; do
    pod="$(kubectl -n "$NS" get pods -l app.kubernetes.io/name=litellm \
      --field-selector=status.phase=Running \
      -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
    if [[ -n "$pod" ]] && kubectl -n "$NS" exec "$pod" -- true >/dev/null 2>&1; then
      break
    fi
    pod=""
    preload_cached_pod_images
    sleep 10
  done
  if [[ -z "$pod" ]]; then
    warn "no running LiteLLM pod to migrate; rerun deploy once its image is pulled"
    return 0
  fi

  if kubectl -n "$NS" exec "$pod" -- sh -c \
      'DISABLE_SCHEMA_UPDATE=false python litellm/proxy/prisma_migration.py'; then
    log "LiteLLM schema migration applied; restarting deployment"
    kubectl -n "$NS" rollout restart deployment/litellm >/dev/null
    kubectl -n "$NS" rollout status deployment/litellm --timeout=180s || true
  else
    warn "LiteLLM Prisma migration failed; inspect 'kubectl -n $NS logs deploy/litellm'"
  fi
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --reset)
      RESET=true
      ;;
    --local-source)
      SOURCE_MODE=local
      ;;
    --charts-repo-url)
      [[ $# -ge 2 ]] || fail "--charts-repo-url requires a value"
      CHARTS_REPO_URL="$2"
      shift
      ;;
    --charts-revision)
      [[ $# -ge 2 ]] || fail "--charts-revision requires a value"
      CHARTS_REVISION="$2"
      shift
      ;;
    --deploy-repo-url)
      [[ $# -ge 2 ]] || fail "--deploy-repo-url requires a value"
      DEPLOY_REPO_URL="$2"
      shift
      ;;
    --deploy-revision)
      [[ $# -ge 2 ]] || fail "--deploy-revision requires a value"
      DEPLOY_REVISION="$2"
      shift
      ;;
    --charts-dir)
      [[ $# -ge 2 ]] || fail "--charts-dir requires a value"
      CHARTS_DIR="$2"
      shift
      ;;
    --no-gpu)
      GPU=false
      ;;
    --rotate-secrets)
      ROTATE_SECRETS=true
      ;;
    --skip-image-preload)
      PRELOAD_IMAGES=false
      ;;
    --skip-workload-wait)
      WAIT_FOR_WORKLOADS=false
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      fail "unknown option: $1"
      ;;
  esac
  shift
done

for cmd in docker git helm jq kubectl minikube openssl; do
  need "$cmd"
done
[[ "$WORKLOAD_TIMEOUT" =~ ^[1-9][0-9]*$ ]] ||
  fail "WORKLOAD_TIMEOUT must be a positive integer"

cd "$ROOT"

# Auto-load a Hugging Face token from the user's cache when one is not already
# provided. The Vault seed (bootstrap-vault-secrets.sh) requires HF_TOKEN to
# store the vLLM model-pull credential; without it a fresh deploy aborts partway
# through seeding, which leaves Argo CD half-synced (e.g. the LiteLLM PreSync
# migration hook never runs to success). Set HF_TOKEN explicitly to override.
if [[ -z "${HF_TOKEN:-}" && -s "$HF_TOKEN_FILE" ]]; then
  HF_TOKEN="$(tr -d '\r\n' < "$HF_TOKEN_FILE")"
  export HF_TOKEN
  log "Loaded HF_TOKEN from $HF_TOKEN_FILE"
fi

if command -v loginctl >/dev/null 2>&1 &&
   docker info --format '{{ join .SecurityOptions "," }}' 2>/dev/null | grep -q rootless &&
   loginctl show-user "$USER" -p Linger 2>/dev/null | grep -q '^Linger=no$'; then
  warn "rootless Docker user lingering is disabled; Minikube may stop after the login session exits"
fi

require_clean_checkout() {
  # Echoes the HEAD commit of a clean git checkout, or fails.
  local dir="$1" label="$2"
  git -C "$dir" rev-parse --is-inside-work-tree >/dev/null 2>&1 ||
    fail "--local-source needs $label to be a git checkout: $dir"
  git -C "$dir" diff --quiet --ignore-submodules -- ||
    fail "--local-source requires committed changes; $label working tree has modifications"
  git -C "$dir" diff --cached --quiet --ignore-submodules -- ||
    fail "--local-source requires committed changes; $label index has staged modifications"
  [[ -z "$(git -C "$dir" ls-files --others --exclude-standard)" ]] ||
    fail "--local-source requires committed changes; $label working tree has untracked files"
  git -C "$dir" rev-parse HEAD
}

if [[ "$SOURCE_MODE" == local ]]; then
  [[ -d "$CHARTS_DIR/charts" ]] ||
    fail "--local-source needs a charts repo checkout; set --charts-dir (looked in $CHARTS_DIR)"
  DEPLOY_REVISION="$(require_clean_checkout "$ROOT" "deployment repo")"
  CHARTS_REVISION="$(require_clean_checkout "$CHARTS_DIR" "charts repo")"
  DEPLOY_REPO_URL="git://git-source.gitops-source.svc.cluster.local:9418/mini-platform-deployment"
  CHARTS_REPO_URL="git://git-source.gitops-source.svc.cluster.local:9418/mini-platform"
fi

if [[ "$RESET" == true ]]; then
  log "Deleting Minikube profile $PROFILE"
  minikube delete -p "$PROFILE" || true
  if [[ -f "$VAULT_INIT_FILE" ]]; then
    backup="${VAULT_INIT_FILE}.backup.$(date +%Y%m%d%H%M%S)"
    mv "$VAULT_INIT_FILE" "$backup"
    log "Saved previous Vault initialization material at $backup"
  fi
fi

start_args=(
  -p "$PROFILE"
  --driver=docker
  --container-runtime=docker
  --kubernetes-version=v1.28.0
  --cpus=8
  --memory=16384
  --disk-size=100g
)
if [[ "$GPU" == true ]]; then
  start_args+=(--gpus=nvidia)
fi

log "Starting Minikube profile $PROFILE"
minikube start "${start_args[@]}"
kubectl config use-context "$PROFILE" >/dev/null

log "Enabling storage and ingress addons"
minikube addons enable storage-provisioner -p "$PROFILE" >/dev/null
minikube addons enable default-storageclass -p "$PROFILE" >/dev/null
minikube addons enable ingress -p "$PROFILE" >/dev/null
kubectl -n ingress-nginx rollout status deployment/ingress-nginx-controller --timeout=180s
kubectl -n ingress-nginx patch service ingress-nginx-controller \
  --type merge -p '{"spec":{"type":"LoadBalancer"}}' >/dev/null

kubectl create namespace "$NS" --dry-run=client -o yaml | kubectl apply -f -
kubectl create namespace "$ARGO_NS" --dry-run=client -o yaml | kubectl apply -f -

if [[ "$SOURCE_MODE" == local ]]; then
  log "Installing private in-cluster Git source (charts $CHARTS_REVISION, deploy $DEPLOY_REVISION)"
  kubectl create namespace gitops-source --dry-run=client -o yaml | kubectl apply -f -
  kubectl -n gitops-source apply -f - <<'EOF'
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: git-source-data
spec:
  accessModes:
    - ReadWriteOnce
  storageClassName: standard
  resources:
    requests:
      storage: 128Mi
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: git-source
spec:
  replicas: 1
  selector:
    matchLabels:
      app: git-source
  template:
    metadata:
      labels:
        app: git-source
    spec:
      containers:
        - name: git-source
          image: alpine:3.20
          command:
            - sh
            - -ec
            - |
              apk add --no-cache git-daemon
              while [ ! -d /repos/mini-platform/.git ] || [ ! -d /repos/mini-platform-deployment/.git ]; do sleep 2; done
              exec git daemon --reuseaddr --export-all --base-path=/repos --listen=0.0.0.0 --port=9418 /repos/mini-platform /repos/mini-platform-deployment
          ports:
            - name: git
              containerPort: 9418
          volumeMounts:
            - name: repository
              mountPath: /repos
      volumes:
        - name: repository
          persistentVolumeClaim:
            claimName: git-source-data
---
apiVersion: v1
kind: Service
metadata:
  name: git-source
spec:
  selector:
    app: git-source
  ports:
    - name: git
      port: 9418
      targetPort: git
EOF
  kubectl -n gitops-source wait --for=condition=Ready pod -l app=git-source --timeout=300s
  git_pod="$(kubectl -n gitops-source get pod -l app=git-source -o jsonpath='{.items[0].metadata.name}')"
  kubectl -n gitops-source cp "$CHARTS_DIR/." "$git_pod:/repos/mini-platform"
  kubectl -n gitops-source cp "$ROOT/." "$git_pod:/repos/mini-platform-deployment"
  kubectl -n gitops-source rollout status deployment/git-source --timeout=300s
  source_ready=false
  for _ in {1..30}; do
    if kubectl -n gitops-source exec "$git_pod" -- \
        git ls-remote git://127.0.0.1:9418/mini-platform HEAD 2>/dev/null | grep -q "$CHARTS_REVISION" &&
       kubectl -n gitops-source exec "$git_pod" -- \
        git ls-remote git://127.0.0.1:9418/mini-platform-deployment HEAD 2>/dev/null | grep -q "$DEPLOY_REVISION"; then
      source_ready=true
      break
    fi
    sleep 2
  done
  [[ "$source_ready" == true ]] ||
    fail "internal Git source did not serve the expected commits"
fi

log "Installing Argo CD and applying the root Application"
if helm -n "$ARGO_NS" status argocd >/dev/null 2>&1; then
  log "Retaining existing Argo CD release; it is reconciled by the root Application"
else
  [[ -d "$CHARTS_DIR/charts/argo-cd" ]] ||
    fail "charts repo not found; set --charts-dir (looked in $CHARTS_DIR)"
  helm upgrade --install argocd "$CHARTS_DIR/charts/argo-cd" \
    -n "$ARGO_NS" -f minikube/values/argo-cd-values.yaml --wait --timeout 15m
fi
kubectl apply -f minikube/gitops/root-application.yaml
# The root Application's source points at the deployment repo; its four helm
# parameters carry both source URLs/revisions down to the generated Applications.
source_patch="$(jq -cn \
  --arg charts_repo "$CHARTS_REPO_URL" --arg charts_rev "$CHARTS_REVISION" \
  --arg deploy_repo "$DEPLOY_REPO_URL" --arg deploy_rev "$DEPLOY_REVISION" '[
  {"op":"replace","path":"/spec/source/repoURL","value":$deploy_repo},
  {"op":"replace","path":"/spec/source/targetRevision","value":$deploy_rev},
  {"op":"replace","path":"/spec/source/helm/parameters/0/value","value":$charts_repo},
  {"op":"replace","path":"/spec/source/helm/parameters/1/value","value":$charts_rev},
  {"op":"replace","path":"/spec/source/helm/parameters/2/value","value":$deploy_repo},
  {"op":"replace","path":"/spec/source/helm/parameters/3/value","value":$deploy_rev}
]')"
kubectl -n "$ARGO_NS" patch application mini-platform --type=json -p "$source_patch" >/dev/null
kubectl -n "$ARGO_NS" annotate application mini-platform \
  argocd.argoproj.io/refresh=hard --overwrite >/dev/null

log "Waiting for Vault server reconciliation"
for _ in {1..90}; do
  if kubectl -n "$NS" get pod vault-0 >/dev/null 2>&1; then
    break
  fi
  sleep 10
done
kubectl -n "$NS" get pod vault-0 >/dev/null 2>&1 ||
  fail "Vault pod was not created within 15 minutes"
for _ in {1..60}; do
  if [[ "$(kubectl -n "$NS" get pod vault-0 -o jsonpath='{.status.phase}')" == Running ]]; then
    break
  fi
  sleep 5
done
[[ "$(kubectl -n "$NS" get pod vault-0 -o jsonpath='{.status.phase}')" == Running ]] ||
  fail "Vault pod was created but did not enter Running state"

vault_status="$(kubectl -n "$NS" exec vault-0 -- env VAULT_ADDR=http://127.0.0.1:8200 vault status -format=json 2>/dev/null || true)"
initialized="$(jq -r '.initialized // false' <<<"$vault_status")"
initialized_now=false

if [[ "$initialized" != true ]]; then
  log "Initializing Vault; protect $VAULT_INIT_FILE as a recovery credential"
  umask 077
  kubectl -n "$NS" exec vault-0 -- env VAULT_ADDR=http://127.0.0.1:8200 \
    vault operator init -key-shares=1 -key-threshold=1 -format=json > "$VAULT_INIT_FILE"
  chmod 600 "$VAULT_INIT_FILE"
  initialized_now=true
elif [[ ! -f "$VAULT_INIT_FILE" ]]; then
  fail "Vault is initialized but $VAULT_INIT_FILE is unavailable; provide its unseal material"
fi

VAULT_UNSEAL_KEY="$(jq -r '.unseal_keys_b64[0]' "$VAULT_INIT_FILE")"
VAULT_TOKEN="$(jq -r '.root_token' "$VAULT_INIT_FILE")"
[[ -n "$VAULT_UNSEAL_KEY" && "$VAULT_UNSEAL_KEY" != null ]] ||
  fail "Vault unseal key was not found in $VAULT_INIT_FILE"
[[ -n "$VAULT_TOKEN" && "$VAULT_TOKEN" != null ]] ||
  fail "Vault root token was not found in $VAULT_INIT_FILE"

sealed="$(jq -r '.sealed // true' <<<"$vault_status")"
if [[ "$initialized_now" == true || "$sealed" == true ]]; then
  log "Unsealing Vault"
  kubectl -n "$NS" exec vault-0 -- env VAULT_ADDR=http://127.0.0.1:8200 \
    vault operator unseal "$VAULT_UNSEAL_KEY" >/dev/null
fi

vault_exec() {
  kubectl -n "$NS" exec vault-0 -- env \
    VAULT_ADDR=http://127.0.0.1:8200 \
    VAULT_TOKEN="$VAULT_TOKEN" \
    vault "$@"
}

log "Configuring Vault Kubernetes authentication and read policy"
if ! vault_exec secrets list -format=json | jq -e 'has("mini-platform/")' >/dev/null; then
  vault_exec secrets enable -path=mini-platform kv-v2 >/dev/null
fi
if ! vault_exec auth list -format=json | jq -e 'has("kubernetes/")' >/dev/null; then
  vault_exec auth enable kubernetes >/dev/null
fi
vault_exec write auth/kubernetes/config \
  kubernetes_host=https://kubernetes.default.svc.cluster.local:443 >/dev/null
kubectl -n "$NS" exec -i vault-0 -- env \
  VAULT_ADDR=http://127.0.0.1:8200 \
  VAULT_TOKEN="$VAULT_TOKEN" \
  vault policy write mini-platform-read - >/dev/null <<'EOF'
path "mini-platform/data/*" {
  capabilities = ["read"]
}
path "mini-platform/metadata/*" {
  capabilities = ["read", "list"]
}
EOF
vault_exec write auth/kubernetes/role/mini-platform \
  bound_service_account_names=vault-auth \
  bound_service_account_namespaces="$NS" \
  audience=vault \
  policies=mini-platform-read \
  ttl=1h >/dev/null
if ! vault_exec audit list -format=json | jq -e 'has("file/")' >/dev/null; then
  vault_exec audit enable file file_path=/vault/audit/audit.log >/dev/null
fi

if [[ "$initialized_now" == true || "$ROTATE_SECRETS" == true ]]; then
  log "Writing platform application credentials to Vault"
  VAULT_ADDR=http://127.0.0.1:8200 \
  VAULT_TOKEN="$VAULT_TOKEN" \
  VAULT_POD=vault-0 \
  VAULT_NAMESPACE="$NS" \
    "$ROOT/scripts/bootstrap-vault-secrets.sh"
else
  log "Keeping existing application credentials; seeding only newly added secrets (use --rotate-secrets to replace them)"
  VAULT_ADDR=http://127.0.0.1:8200 \
  VAULT_TOKEN="$VAULT_TOKEN" \
  VAULT_POD=vault-0 \
  VAULT_NAMESPACE="$NS" \
  SEED_MISSING_ONLY=true \
    "$ROOT/scripts/bootstrap-vault-secrets.sh"
fi

preload_cached_pod_images
restart_pending_operator_after_preload

log "Waiting for Vault static secret synchronization"
for _ in {1..60}; do
  preload_cached_pod_images
  restart_pending_operator_after_preload
  secret_count="$({ kubectl -n "$NS" get vaultstaticsecrets -o name 2>/dev/null || true; } | wc -l | tr -d ' ')"
  if [[ "$secret_count" -gt 0 ]] &&
     kubectl -n "$NS" wait --for=condition=Ready vaultstaticsecret --all --timeout=30s >/dev/null 2>&1; then
    break
  fi
  sleep 10
done
secret_count="$({ kubectl -n "$NS" get vaultstaticsecrets -o name 2>/dev/null || true; } | wc -l | tr -d ' ')"
[[ "$secret_count" -gt 0 ]] ||
  fail "VaultStaticSecret resources were not created"
kubectl -n "$NS" wait --for=condition=Ready vaultstaticsecret --all --timeout=30s >/dev/null ||
  fail "not all VaultStaticSecret resources reached Ready state"
kubectl -n "$NS" get vaultstaticsecrets

preload_cached_pod_images
restart_pending_workload_pods
if [[ "$WAIT_FOR_WORKLOADS" == true ]]; then
  wait_for_workloads
fi

ensure_litellm_schema

log "Deployment bootstrap finished"
kubectl -n "$ARGO_NS" get applications
printf '\nVault initialization material: %s\n' "$VAULT_INIT_FILE"
printf 'Start ingress access with: minikube tunnel -p %s\n' "$PROFILE"
printf 'Or start host-local forwards with: scripts/port-forward-services.sh\n'
