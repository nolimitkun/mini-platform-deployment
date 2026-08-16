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
DEEPSEEK_KEY_FILE="${DEEPSEEK_KEY_FILE:-$HOME/.deepseek-key}"
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

Environment:
  WORKLOAD_TIMEOUT        Seconds to wait for platform pods (default: 1800).
                          Raise it for a --reset run: that empties Minikube's
                          image store, and pulling the whole platform back over
                          a home connection takes well over the default.
  HF_TOKEN                Hugging Face token for the vLLM model pull. Falls back
                          to ~/.cache/huggingface/token (HF_TOKEN_FILE).
  DEEPSEEK_API_KEY        DeepSeek key for the hosted model kagent's agents run
                          on. Falls back to ~/.deepseek-key (DEEPSEEK_KEY_FILE).
  HOLMES_GITHUB_TOKEN     Read-only GitHub PAT for Holmes' MCP server.
  HOLMES_ARGOCD_AUTH_TOKEN
                          API token for the read-only Argo CD `holmes` account.
                          All four are required only when their Vault secret is
                          actually written: a fresh install, a --rotate-secrets
                          run, or the first upgrade after the secret was added.

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

# Number of `dnat to` rules in the nftables endpoint chain that backs the
# default/kubernetes Service. Should be 1; 0 means kube-proxy created the chain
# but never populated it. Prints nothing readable as 0 so callers can compare.
kubernetes_service_dnat_rules() {
  local count
  count="$(minikube -p "$PROFILE" ssh -- \
    "sudo nft list table ip kube-proxy 2>/dev/null \
      | awk '/chain endpoint-.*default\/kubernetes\/tcp\/https/,/^\t}/' \
      | grep -c 'dnat to'" 2>/dev/null | tr -d '\r' || true)"
  [[ "$count" =~ ^[0-9]+$ ]] || count=0
  printf '%s' "$count"
}

# Restarting kube-proxy with the nftables proxier can leave the
# default/kubernetes endpoint chain created but empty -- every other Service
# keeps its `dnat to` rule, only this one comes back blank. Pods then cannot
# reach the API server through 10.96.0.1, so CoreDNS never becomes ready,
# kube-dns lands in the no-endpoints reject set, and every pod loses DNS. A
# plain kube-proxy restart does not fix it; the chain is only rebuilt correctly
# when the whole table is absent.
#
# `minikube start` restarts kube-proxy, so a rerun against an existing profile
# hits this. Fresh clusters come up correct and skip the repair entirely.
repair_kube_proxy_nftables() {
  # Give kube-proxy a chance to write its table before judging it.
  for _ in {1..24}; do
    [[ "$(kubernetes_service_dnat_rules)" == 0 ]] || return 0
    sleep 5
  done

  warn "kube-proxy left the default/kubernetes chain empty; rebuilding its nftables state"
  minikube -p "$PROFILE" ssh -- "sudo nft delete table ip kube-proxy" >/dev/null 2>&1 || true
  kubectl -n kube-system delete pod -l k8s-app=kube-proxy --wait=false >/dev/null 2>&1 || true

  for _ in {1..24}; do
    [[ "$(kubernetes_service_dnat_rules)" == 0 ]] || break
    sleep 5
  done
  [[ "$(kubernetes_service_dnat_rules)" != 0 ]] ||
    fail "kube-proxy did not program the default/kubernetes Service; cluster DNS will not work"

  # CoreDNS backs off after failing to reach the API server, so it can sit
  # not-ready for a while after the path is repaired.
  kubectl -n kube-system rollout restart deployment/coredns >/dev/null 2>&1 || true
  kubectl -n kube-system rollout status deployment/coredns --timeout=300s >/dev/null 2>&1 ||
    warn "CoreDNS did not report ready; cluster DNS may still be settling"
  log "Cluster DNS path repaired"
}

# Single sign-on needs one Keycloak URL that means the same thing to a browser
# and to a pod. Browsers get there through the ingress at keycloak.test, so this
# teaches cluster DNS the same name: CoreDNS rewrites it to the Keycloak
# Service, and the Host header still reads keycloak.test, which is what
# Keycloak stamps into the `iss` claim.
#
# Without this, an in-cluster client would have to redeem authorization codes
# against keycloak.mini-platform.svc and would be handed an issuer that does not
# match the one in the browser's ID token, which Argo CD, oauth2-proxy and
# Langfuse all reject. Rewriting to the Service rather than to the ingress
# controller keeps the hop inside the cluster; the Host header is what matters,
# not the path taken.
#
# CoreDNS lives in kube-system and is outside Argo CD's reconciliation, so this
# belongs with the other imperative bring-up steps. It is idempotent.
install_keycloak_dns_rewrite() {
  local rewrite="rewrite name keycloak.test keycloak.${NS}.svc.cluster.local"
  local corefile

  corefile="$(kubectl -n kube-system get configmap coredns -o jsonpath='{.data.Corefile}' 2>/dev/null || true)"
  if [[ -z "$corefile" ]]; then
    warn "CoreDNS Corefile not found; skipping the keycloak.test rewrite (SSO logins will fail)"
    return 0
  fi
  if [[ "$corefile" == *"$rewrite"* ]]; then
    return 0
  fi

  log "Teaching CoreDNS to resolve keycloak.test in-cluster"
  local patched
  patched="$(printf '%s\n' "$corefile" | awk -v rule="    $rewrite" '
    { print }
    !done && /^\.:53 \{/ { print rule; done = 1 }
  ')"
  if [[ "$patched" == "$corefile" ]]; then
    warn "CoreDNS Corefile has no .:53 server block; skipping the keycloak.test rewrite"
    return 0
  fi

  # Patch rather than apply: the ConfigMap is minikube's, and a client-side
  # apply from a hand-built manifest would take ownership of its labels too.
  kubectl -n kube-system patch configmap coredns --type merge \
    -p "$(jq -n --arg corefile "$patched" '{data: {Corefile: $corefile}}')" >/dev/null
  kubectl -n kube-system rollout restart deployment/coredns >/dev/null
  kubectl -n kube-system rollout status deployment/coredns --timeout=180s >/dev/null ||
    warn "CoreDNS did not report ready after the keycloak.test rewrite"
}

# Requesting an explicit Argo CD sync reruns hooks even when the rendered
# manifests are unchanged. Track a new operation completion rather than the
# Application's aggregate health, which can already be healthy before the hook
# starts.
sync_argocd_application() {
  local app="$1"
  local previous_finished phase finished

  if ! kubectl -n "$ARGO_NS" get application "$app" >/dev/null 2>&1; then
    warn "Argo CD Application $app not found; cannot rerun its provisioning hooks"
    return 1
  fi

  previous_finished="$(kubectl -n "$ARGO_NS" get application "$app" \
    -o jsonpath='{.status.operationState.finishedAt}' 2>/dev/null || true)"

  # An explicit sync runs Sync hooks even when the Application is already
  # Synced. Secret data is external to the rendered manifests, so changing a
  # VaultStaticSecret alone would otherwise never rerun a provisioning Job.
  kubectl -n "$ARGO_NS" patch application "$app" --type=merge \
    -p '{"operation":{"sync":{"prune":true}}}' >/dev/null

  for _ in {1..120}; do
    phase="$(kubectl -n "$ARGO_NS" get application "$app" \
      -o jsonpath='{.status.operationState.phase}' 2>/dev/null || true)"
    finished="$(kubectl -n "$ARGO_NS" get application "$app" \
      -o jsonpath='{.status.operationState.finishedAt}' 2>/dev/null || true)"
    if [[ -n "$finished" && "$finished" != "$previous_finished" ]]; then
      if [[ "$phase" == Succeeded ]]; then
        return 0
      fi
      warn "Argo CD sync for $app finished with phase ${phase:-unknown}"
      return 1
    fi
    sleep 5
  done

  warn "timed out waiting for Argo CD sync of $app"
  return 1
}

# Rotating the OIDC client secrets is a two-sided change, and neither side
# notices on its own: Keycloak keeps whatever the last realm import wrote, while
# the components read their secret from an environment variable fixed at pod
# creation. VSO updating the Kubernetes Secret moves neither. Left alone, the
# next unrelated pod restart picks up a new secret that Keycloak no longer
# accepts, and SSO breaks at a moment with no obvious connection to the
# rotation.
#
# So re-import the realm and roll the consumers, in that order, as part of the
# same run. The import Job is normally an Argo CD PostSync hook, which only
# fires on a sync; cloning it here re-runs it immediately against the refreshed
# Secret without waiting for one.
reconcile_after_secret_rotation() {
  local job=keycloak-keycloak-config-cli
  local clone
  clone="keycloak-config-cli-rotate-$(date +%s)"

  log "Re-importing the Keycloak realm with the rotated client secrets"
  if kubectl -n "$NS" get job "$job" >/dev/null 2>&1; then
    # `kubectl create job --from` only accepts a CronJob, so copy the spec by
    # hand. Everything the API server or the Job controller owns has to go:
    # the generated selector and the controller-uid/job-name labels are
    # immutable and would bind the copy to the original. The Argo CD instance
    # label goes too -- left on, Argo CD would consider this stray Job part of
    # the keycloak Application and prune it mid-run.
    if kubectl -n "$NS" get job "$job" -o json |
      jq --arg name "$clone" '
        .metadata = {name: $name, labels: (.metadata.labels // {} | del(
          ."app.kubernetes.io/instance",
          ."batch.kubernetes.io/controller-uid", ."controller-uid",
          ."batch.kubernetes.io/job-name", ."job-name"))}
        | del(.spec.selector, .status)
        | .spec.template.metadata.labels |= (. // {} | del(
          ."batch.kubernetes.io/controller-uid", ."controller-uid",
          ."batch.kubernetes.io/job-name", ."job-name"))' |
      kubectl -n "$NS" create -f - >/dev/null 2>&1; then
      kubectl -n "$NS" wait --for=condition=complete "job/$clone" --timeout=600s >/dev/null 2>&1 ||
        warn "realm re-import did not complete; check 'kubectl -n $NS logs job/$clone'"
      kubectl -n "$NS" delete job "$clone" --ignore-not-found >/dev/null 2>&1 || true
    else
      warn "could not clone $job; re-import the realm by syncing the keycloak Application"
    fi
  else
    warn "$job not found; skipping realm re-import (Keycloak may not be deployed yet)"
  fi

  # Dedicated Langfuse project credentials are stored in Vault, while the API
  # keys accepted by Langfuse are written by Argo CD Sync-hook Jobs. Rotating
  # only the Secrets leaves Langfuse knowing the old keys. Explicitly rerun the
  # project provisioners after VSO has synchronized the new values and before
  # any producer restarts with them.
  local project_app
  for project_app in \
    mini-platform-langfuse-holmes-project \
    mini-platform-langfuse-open-webui-project; do
    log "Reprovisioning Langfuse credentials through $project_app"
    sync_argocd_application "$project_app" ||
      fail "could not reprovision Langfuse credentials through $project_app"
  done

  # Every workload that reads a rotated Secret from its pod spec -- a key of
  # keycloak-sso, or one of the mirrors. Argo CD will not restart these itself:
  # the Deployment specs are unchanged, only the Secret they reference, and a
  # secretKeyRef or envFrom is resolved once at pod creation.
  #
  # Holmes matters most here, because HOLMES_API_KEY *is* its authentication:
  # left running it keeps honouring the old key while `port-forward-services.sh`
  # and the README's kubectl lookup both hand out the new one, so every caller
  # gets a 401 with nothing to point at. kagent-grafana-mcp has the same shape
  # (envFrom on the rotated Grafana mirror). kagent-litellm needs no entry --
  # nothing mounts it, the kagent controller resolves it through the ModelConfig
  # on each reconcile.
  log "Restarting the workloads that hold rotated secrets in their pod spec"
  local workloads=(
    deployment/grafana
    statefulset/open-webui
    deployment/superset
    deployment/superset-worker
    deployment/hub
    deployment/oauth2-proxy
    deployment/langfuse-web
    deployment/minio
    deployment/holmes-holmes
    deployment/kagent-grafana-mcp
  )
  local w
  for w in "${workloads[@]}"; do
    kubectl -n "$NS" rollout restart "$w" >/dev/null 2>&1 || true
  done
  # Argo CD reads its client secret from a Secret in its own namespace.
  kubectl -n "$ARGO_NS" rollout restart deployment/argocd-server >/dev/null 2>&1 || true
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
    # Present is not the same as current. An image bump moves the schema on
    # without anything re-running the migration, and the drift surfaces far
    # from its cause: the admin UI's own /login mints a key, that insert hits a
    # column the database does not have, and the browser gets a 500 from a
    # proxy whose pods are all Ready and whose /v1 traffic is fine. So the
    # migration runs either way -- `prisma migrate deploy` is idempotent and a
    # no-op against an up-to-date database.
    log "LiteLLM schema present; reconciling any pending migrations"
  else
    warn "LiteLLM schema missing; applying Prisma migration (PreSync hook did not)"
  fi
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
    if [[ "$exists" == t ]]; then
      # Only a drift reconcile. The running pod already expects the columns the
      # migration just added -- that mismatch is what made it fail -- so there
      # is nothing to restart it for.
      log "LiteLLM migrations reconciled"
    else
      log "LiteLLM schema migration applied; restarting deployment"
      kubectl -n "$NS" rollout restart deployment/litellm >/dev/null
      kubectl -n "$NS" rollout status deployment/litellm --timeout=180s || true
    fi
  else
    warn "LiteLLM Prisma migration failed; inspect 'kubectl -n $NS logs deploy/litellm'"
  fi
}

# MinIO resolves its OIDC discovery URL once, during IAM init at startup. If
# that lookup fails it logs "Unable to initialize OpenID" and serves on without
# a provider: the console offers username/password and no Keycloak button, and
# it never retries. Any transient is enough -- Keycloak not up yet, the CoreDNS
# rollout this script performs a few steps earlier, a pod sandbox being
# recreated -- and the result outlives the transient, because only a restart
# re-runs the lookup. Sync waves order the initial rollout but cannot help a
# container that restarts later, so the bring-up ends by checking the console's
# own view of itself and restarting MinIO if it came up blind.
# The console's own view of how it authenticates. Answers "" if it never
# replies, and never fails: the API refuses connections for a few seconds after
# a restart, and under `set -o pipefail` returning that failure would take the
# whole deploy down at the very last step, after every bit of real work.
minio_login_strategy() {
  local deadline out
  deadline=$((SECONDS + 60))
  while :; do
    out="$(kubectl -n "$NS" exec deployment/minio -- \
      curl -sf --max-time 10 http://localhost:9001/api/v1/login 2>/dev/null || true)"
    out="$(printf '%s' "$out" | sed -n 's/.*"loginStrategy":"\([^"]*\)".*/\1/p')"
    if [[ -n "$out" || "$SECONDS" -ge "$deadline" ]]; then
      printf '%s' "$out"
      return 0
    fi
    sleep 5
  done
}

ensure_minio_sso() {
  kubectl -n "$NS" get deployment minio >/dev/null 2>&1 || return 0
  # Only meaningful when the overlay asked for SSO in the first place.
  kubectl -n "$NS" get deployment minio \
    -o jsonpath='{.spec.template.spec.containers[0].env[*].name}' 2>/dev/null |
    grep -q MINIO_IDENTITY_OPENID_CONFIG_URL || return 0

  log "Verifying MinIO console SSO"
  local strategy

  strategy="$(minio_login_strategy)"
  if [[ "$strategy" == redirect ]]; then
    log "MinIO console offers Keycloak SSO"
    return 0
  fi
  if [[ -z "$strategy" ]]; then
    warn "MinIO console did not answer; skipping SSO check"
    return 0
  fi

  warn "MinIO console has no SSO button (loginStrategy=$strategy); restarting to retry OIDC discovery"
  kubectl -n "$NS" rollout restart deployment/minio >/dev/null
  kubectl -n "$NS" rollout status deployment/minio --timeout=300s >/dev/null ||
    { warn "MinIO did not roll out; inspect 'kubectl -n $NS logs deploy/minio'"; return 0; }

  strategy="$(minio_login_strategy)"
  if [[ "$strategy" == redirect ]]; then
    log "MinIO console offers Keycloak SSO"
  else
    warn "MinIO console still has no SSO button; inspect 'kubectl -n $NS logs deploy/minio' for 'Unable to initialize OpenID'"
  fi
}

# Langfuse re-runs its headless init at startup, and the init user's email is
# what links the Keycloak identity to the account owning the seeded org. A
# seed-missing run can change that address in Vault, but langfuse-web resolved
# it into its environment when the pod was created, so until it restarts the
# SSO login keeps landing in an empty workspace -- the same secretKeyRef blind
# spot reconcile_after_secret_rotation handles for the rotation path.
#
# Compares the running pod against the synced Secret rather than a hardcoded
# address, so it stays right whichever side moves, and it is a no-op on the
# runs where they already agree.
ensure_langfuse_init_user() {
  kubectl -n "$NS" get deployment langfuse-web >/dev/null 2>&1 || return 0

  local desired running
  desired="$(kubectl -n "$NS" get secret langfuse-init-user \
    -o jsonpath='{.data.LANGFUSE_INIT_USER_EMAIL}' 2>/dev/null | base64 -d 2>/dev/null || true)"
  running="$(kubectl -n "$NS" exec deployment/langfuse-web -- \
    printenv LANGFUSE_INIT_USER_EMAIL 2>/dev/null || true)"
  # Either side unreadable means there is nothing to compare, not a mismatch.
  [[ -n "$desired" && -n "$running" ]] || return 0
  [[ "$desired" != "$running" ]] || return 0

  log "Langfuse init user is now $desired; restarting langfuse-web to re-run the headless init"
  kubectl -n "$NS" rollout restart deployment/langfuse-web >/dev/null
  kubectl -n "$NS" rollout status deployment/langfuse-web --timeout=300s >/dev/null ||
    warn "langfuse-web did not roll out; inspect 'kubectl -n $NS logs deploy/langfuse-web'"
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

# Same treatment for the DeepSeek key backing the model kagent's agents run on.
# The Vault seed requires it on a fresh install and on the first upgrade after
# kagent was added, and it is demanded well after the cluster and Vault are up
# -- so without this a deploy aborts midway, leaving Argo CD half-synced.
if [[ -z "${DEEPSEEK_API_KEY:-}" && -s "$DEEPSEEK_KEY_FILE" ]]; then
  DEEPSEEK_API_KEY="$(tr -d '\r\n' < "$DEEPSEEK_KEY_FILE")"
  export DEEPSEEK_API_KEY
  log "Loaded DEEPSEEK_API_KEY from $DEEPSEEK_KEY_FILE"
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
  --kubernetes-version=v1.34.4
  # kube-proxy's default iptables mode cannot program this platform. It pushes
  # the whole ruleset through one `iptables-restore`, and every kube-proxy image
  # up to v1.34 bundles iptables 1.8.9, which sends that as a single netlink
  # message and hits the 64 KiB limit -- the platform's ~70 Services render to
  # roughly 85 KiB, so every sync fails with EMSGSIZE and no Service VIP, cluster
  # DNS included, is ever programmed. The nftables proxier talks to nf_tables
  # directly and has no such batch. It is GA since v1.33 but still not the
  # default, so it has to be asked for.
  --extra-config=kube-proxy.mode=nftables
  --cpus=8
  # Must stay ahead of the platform's total pod memory *requests*, which is not
  # the usual "give the VM enough RAM" sizing argument. On the docker driver
  # this becomes a cgroup cap on the node container, but /proc/meminfo inside
  # that container is not namespaced, so kubelet reads the host's total and
  # advertises it as node capacity. Scheduling is therefore done against host
  # memory while the actual ceiling is this number -- kubelet will happily admit
  # far more than fits and nothing reports pressure until the kernel OOM-kills
  # inside the cgroup, which takes etcd and kube-apiserver with it.
  #
  # 16384 was under the ~57 GiB of requests the platform already carried; it
  # survived only because most workloads idle well below their requests, and
  # adding kagent pushed real usage past the cap and downed the control plane.
  # Check `kubectl describe node` "Allocated resources" against this value
  # before adding components.
  --memory=65536
  --disk-size=100g
)
if [[ "$GPU" == true ]]; then
  start_args+=(--gpus=nvidia)
fi

log "Starting Minikube profile $PROFILE"
minikube start "${start_args[@]}"
kubectl config use-context "$PROFILE" >/dev/null
repair_kube_proxy_nftables

log "Enabling storage and ingress addons"
minikube addons enable storage-provisioner -p "$PROFILE" >/dev/null
minikube addons enable default-storageclass -p "$PROFILE" >/dev/null
minikube addons enable ingress -p "$PROFILE" >/dev/null
kubectl -n ingress-nginx rollout status deployment/ingress-nginx-controller --timeout=180s
kubectl -n ingress-nginx patch service ingress-nginx-controller \
  --type merge -p '{"spec":{"type":"LoadBalancer"}}' >/dev/null

install_keycloak_dns_rewrite

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
          # Argo CD's own image, picked because git-daemon is already inside it
          # (/usr/lib/git-core/git-daemon) and because Argo CD runs the same
          # image, so it is in the node's image store before this pod is ever
          # created. That matters on restart. This was alpine:3.20 running
          # `apk add --no-cache git-daemon` at startup, which made every
          # container start depend on reaching the Alpine CDN -- so when
          # Service routing was down the install failed, the pod crashlooped,
          # and the deploy aborted at "internal Git source did not serve the
          # expected commits", three layers away from the actual fault.
          # Nothing here needs Argo CD specifically; the tag only has to exist,
          # and matching charts/argo-cd's appVersion is what keeps it cached.
          image: quay.io/argoproj/argocd:v3.4.2
          # That image's default user is uid 999, but the repo trees on the PVC
          # are root-owned -- `kubectl cp` below runs tar as whoever this
          # container is, and the volume predates the image swap. As uid 999 git
          # refuses to serve them ("detected dubious ownership") and could not
          # overwrite them on the next copy either. Root is also what the
          # previous alpine image ran as, so this keeps ownership on the volume
          # consistent across the change.
          securityContext:
            runAsUser: 0
          command:
            - sh
            - -ec
            - |
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
  # `kubectl wait` fails outright when nothing matches the selector yet, so wait
  # on the Deployment first — that gives the ReplicaSet time to create the pod.
  kubectl -n gitops-source rollout status deployment/git-source --timeout=300s
  # Everything below is scoped to the newest pod by name rather than by label.
  # When this Deployment's template changes, the previous revision's pod keeps
  # the app=git-source label while it terminates, so a label-wide `kubectl wait`
  # blocks on a pod that will never be Ready again, and `.items[0]` can resolve
  # to that same doomed pod.
  git_pod="$(kubectl -n gitops-source get pod -l app=git-source \
    --sort-by=.metadata.creationTimestamp -o jsonpath='{.items[-1:].metadata.name}')"
  kubectl -n gitops-source wait --for=condition=Ready "pod/$git_pod" --timeout=300s
  kubectl -n gitops-source cp "$CHARTS_DIR/." "$git_pod:/repos/mini-platform"
  kubectl -n gitops-source cp "$ROOT/." "$git_pod:/repos/mini-platform-deployment"
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
# The root Application's source points at the deployment repo; replace the full
# source shape so upgrades from older single-repo app-of-apps specs cannot keep
# stale paths or missing multi-repo parameters.
source_patch="$(jq -cn \
  --arg charts_repo "$CHARTS_REPO_URL" --arg charts_rev "$CHARTS_REVISION" \
  --arg deploy_repo "$DEPLOY_REPO_URL" --arg deploy_rev "$DEPLOY_REVISION" '[
  {
    "op":"replace",
    "path":"/spec/source",
    "value":{
      "repoURL":$deploy_repo,
      "targetRevision":$deploy_rev,
      "path":"minikube/gitops/mini-platform",
      "helm":{
        "parameters":[
          {"name":"chartsRepo","value":$charts_repo},
          {"name":"chartsRevision","value":$charts_rev},
          {"name":"deployRepo","value":$deploy_repo},
          {"name":"deployRevision","value":$deploy_rev}
        ]
      }
    }
  }
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

# Not `.sealed // true`: jq's `//` fires on false as well as null, so that form
# reports an unsealed Vault as sealed and this always ran the unseal below. That
# was harmless (unsealing an unsealed Vault is a no-op) but it made the status
# check meaningless. Only a missing field, i.e. Vault unreachable, means sealed.
sealed="$(jq -r 'if .sealed == null then "true" else (.sealed | tostring) end' <<<"$vault_status")"
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
# The Argo CD namespace is bound too: Argo CD only reads an OIDC client secret
# from a Secret in its own namespace, so keycloak-resources.yaml renders a
# VaultAuth and a vault-auth ServiceAccount there as well.
vault_exec write auth/kubernetes/role/mini-platform \
  bound_service_account_names=vault-auth \
  bound_service_account_namespaces="$NS,$ARGO_NS" \
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

if [[ "$ROTATE_SECRETS" == true ]]; then
  reconcile_after_secret_rotation
fi

preload_cached_pod_images
restart_pending_workload_pods
if [[ "$WAIT_FOR_WORKLOADS" == true ]]; then
  wait_for_workloads
fi

ensure_litellm_schema
ensure_langfuse_init_user
ensure_minio_sso

log "Deployment bootstrap finished"
kubectl -n "$ARGO_NS" get applications
printf '\nVault initialization material: %s\n' "$VAULT_INIT_FILE"
printf 'Start ingress access with: minikube tunnel -p %s\n' "$PROFILE"
printf 'Or start host-local forwards with: scripts/port-forward-services.sh\n'
