#!/usr/bin/env bash
set -euo pipefail

: "${VAULT_ADDR:?Set VAULT_ADDR to the initialized Vault server address.}"
: "${VAULT_TOKEN:?Set VAULT_TOKEN to a token allowed to write mini-platform/ secrets.}"
HF_TOKEN="${HF_TOKEN:-}"

# When true, only secret paths that do not already exist are written. This lets
# upgrades seed newly introduced secrets without rotating credentials that
# running workloads already depend on.
SEED_MISSING_ONLY="${SEED_MISSING_ONLY:-false}"

vault_cli() {
  if [[ -n "${VAULT_POD:-}" ]]; then
    : "${VAULT_NAMESPACE:?Set VAULT_NAMESPACE when VAULT_POD is configured.}"
    kubectl -n "$VAULT_NAMESPACE" exec "$VAULT_POD" -- env \
      VAULT_ADDR="$VAULT_ADDR" \
      VAULT_TOKEN="$VAULT_TOKEN" \
      vault "$@"
  else
    command vault "$@"
  fi
}

# kv_put writes a secret, but skips it in SEED_MISSING_ONLY mode if the path
# already exists so existing credentials are left untouched.
kv_put() {
  local path="$1"; shift
  if [[ "$SEED_MISSING_ONLY" == true ]] && vault_cli kv get "$path" >/dev/null 2>&1; then
    printf 'keeping existing %s\n' "$path"
    return 0
  fi
  vault_cli kv put "$path" "$@"
}

rand_b64() {
  # URL-safe, padding-free random token. Standard base64 padding ('=') and the
  # '+'/'/' characters break consumers that parse credentials out of INI files,
  # env interpolation, or URLs (e.g. MLflow's basic_auth.ini dropped a trailing
  # '=', creating an admin password that no longer matched the stored secret).
  # Mapping to the URL-safe alphabet and stripping padding keeps full entropy.
  openssl rand -base64 32 | tr -d '\n' | tr '+/' '-_' | tr -d '='
}

rand_hex() {
  openssl rand -hex 32
}

# oauth2-proxy rejects any cookie secret whose length is not 16, 24, or 32
# bytes -- it feeds the value straight to AES. 16 hex bytes prints 32 chars.
rand_cookie() {
  openssl rand -hex 16
}

# Reads one field of an existing secret, printing nothing if the path or field
# is absent. Used to carry a credential into a second secret that has to hold
# the same value.
kv_field() {
  vault_cli kv get -field="$2" "$1" 2>/dev/null || true
}

# Same idea as kv_put's skip: in SEED_MISSING_ONLY mode a credential that other
# secrets mirror has to keep the value already in Vault, not a fresh random one.
# Without this, seeding a newly added mirror (e.g. kagent-litellm) onto a
# cluster whose source secret is untouched would hand the new consumer a
# credential the owning service never accepted.
reuse_or_generate() {
  local path="$1" field="$2" existing=""
  if [[ "$SEED_MISSING_ONLY" == true ]]; then
    existing="$(kv_field "$path" "$field")"
  fi
  printf '%s' "$existing"
}

POSTGRES_ADMIN_PASSWORD="${POSTGRES_ADMIN_PASSWORD:-$(rand_b64)}"
LITELLM_DB_PASSWORD="${LITELLM_DB_PASSWORD:-$(rand_hex)}"
REDIS_PASSWORD="${REDIS_PASSWORD:-$(rand_b64)}"
LITELLM_MASTER_KEY="${LITELLM_MASTER_KEY:-$(reuse_or_generate mini-platform/litellm-master-key PROXY_MASTER_KEY)}"
LITELLM_MASTER_KEY="${LITELLM_MASTER_KEY:-sk-$(rand_hex)}"
LANGFUSE_PUBLIC_KEY="${LANGFUSE_PUBLIC_KEY:-lf_pk_$(rand_hex)}"
LANGFUSE_SECRET_KEY="${LANGFUSE_SECRET_KEY:-lf_sk_$(rand_hex)}"
SUPERSET_DB_PASSWORD="${SUPERSET_DB_PASSWORD:-$(rand_hex)}"
SUPERSET_REDIS_PASSWORD="${SUPERSET_REDIS_PASSWORD:-$(rand_hex)}"
SUPERSET_ADMIN_PASSWORD="${SUPERSET_ADMIN_PASSWORD:-$(rand_b64)}"

kv_put mini-platform/postgresql-credentials \
  postgres-password="$POSTGRES_ADMIN_PASSWORD" \
  password="$LITELLM_DB_PASSWORD" \
  metrics-password="$(rand_b64)"
kv_put mini-platform/litellm-dbcredentials \
  username=litellm \
  password="$LITELLM_DB_PASSWORD"
kv_put mini-platform/redis-credentials redis-password="$REDIS_PASSWORD"
kv_put mini-platform/litellm-redis \
  REDIS_HOST=redis-master.mini-platform.svc.cluster.local \
  REDIS_PORT=6379 \
  REDIS_PASSWORD="$REDIS_PASSWORD"
kv_put mini-platform/litellm-master-key PROXY_MASTER_KEY="$LITELLM_MASTER_KEY"

# Hugging Face token for pulling the vLLM model weights and tokenizer. Require it
# only when this secret is actually written (fresh install or rotation), not on a
# seed-missing pass where it already exists.
if [[ "$SEED_MISSING_ONLY" != true ]] || ! vault_cli kv get mini-platform/vllm-hf-token >/dev/null 2>&1; then
  : "${HF_TOKEN:?Set HF_TOKEN to a Hugging Face token for pulling the vLLM model weights and tokenizer.}"
fi
kv_put mini-platform/vllm-hf-token HF_TOKEN="$HF_TOKEN"

kv_put mini-platform/langfuse-app-secrets \
  salt="$(rand_b64)" \
  encryption-key="$(rand_hex)" \
  nextauth-secret="$(rand_b64)"
kv_put mini-platform/langfuse-postgresql password="$(rand_hex)"
kv_put mini-platform/langfuse-redis password="$(rand_hex)"
kv_put mini-platform/langfuse-clickhouse password="$(rand_hex)"
kv_put mini-platform/langfuse-s3 \
  root-user=langfuse \
  root-password="$(rand_b64)"
kv_put mini-platform/litellm-langfuse \
  LANGFUSE_PUBLIC_KEY="$LANGFUSE_PUBLIC_KEY" \
  LANGFUSE_SECRET_KEY="$LANGFUSE_SECRET_KEY" \
  LANGFUSE_HOST=http://langfuse-web.mini-platform.svc.cluster.local:3000
# Langfuse headless init user: makes the auto-provisioned org/project visible in
# the UI (org/project alone are API-only; a fresh signup joins no org).
#
# The address is the realm's platform-admin, deliberately, and it is the only
# thing making SSO useful here. Langfuse links an OIDC identity to an existing
# account by matching email; seeded under any other address, nothing matches, a
# Keycloak login lands on a brand-new account belonging to no organization, and
# the seeded org and its LiteLLM project stay invisible to the person who just
# logged in. Matching it makes the SSO login *be* the owner account. Keep it in
# step with the seed user in minikube/values/keycloak-values.yaml.
kv_put mini-platform/langfuse-init-user \
  LANGFUSE_INIT_USER_EMAIL=platform-admin@mini-platform.test \
  LANGFUSE_INIT_USER_NAME="Platform Admin" \
  LANGFUSE_INIT_USER_PASSWORD="$(rand_b64)"

kv_put mini-platform/mlflow-auth \
  admin-user=admin \
  admin-password="$(rand_b64)" \
  flask-server-secret-key="$(rand_hex)"
kv_put mini-platform/mlflow-postgresql \
  postgres-password="$(rand_b64)" \
  password="$(rand_b64)"
kv_put mini-platform/mlflow-minio \
  root-user=mlflow \
  root-password="$(rand_b64)"
GRAFANA_ADMIN_USER="admin"
GRAFANA_ADMIN_PASSWORD="${GRAFANA_ADMIN_PASSWORD:-$(reuse_or_generate mini-platform/grafana-admin admin-password)}"
GRAFANA_ADMIN_PASSWORD="${GRAFANA_ADMIN_PASSWORD:-$(rand_b64)}"
kv_put mini-platform/grafana-admin \
  admin-user="$GRAFANA_ADMIN_USER" \
  admin-password="$GRAFANA_ADMIN_PASSWORD"

kv_put mini-platform/superset-postgresql \
  postgres-password="$(rand_b64)" \
  password="$SUPERSET_DB_PASSWORD"
kv_put mini-platform/superset-redis redis-password="$SUPERSET_REDIS_PASSWORD"
kv_put mini-platform/superset-env \
  DB_HOST=superset-postgresql \
  DB_PORT=5432 \
  DB_USER=superset \
  DB_PASS="$SUPERSET_DB_PASSWORD" \
  DB_NAME=superset \
  REDIS_HOST=superset-redis-headless \
  REDIS_PORT=6379 \
  REDIS_PROTO=redis \
  REDIS_PASSWORD="$SUPERSET_REDIS_PASSWORD" \
  REDIS_DB=1 \
  REDIS_CELERY_DB=0 \
  SUPERSET_SECRET_KEY="$(openssl rand -base64 42 | tr -d '\n')" \
  SUPERSET_ADMIN_PASSWORD="$SUPERSET_ADMIN_PASSWORD"

kv_put mini-platform/keycloak-admin admin-password="$(rand_b64)"
kv_put mini-platform/keycloak-postgresql \
  postgres-password="$(rand_b64)" \
  password="$(rand_b64)"

# ---------------------------------------------------------------------------
# Keycloak SSO
#
# One secret holds every OIDC client secret plus the two seed user passwords.
# keycloak-config-cli consumes the whole thing with envFrom and interpolates
# `$(env:NAME)` into the realm file in minikube/values/keycloak-values.yaml;
# each client component mounts only the single key it needs. Field names are
# therefore env-var shaped, and any change here has to be matched in that realm
# file -- an unresolved variable is imported into Keycloak literally, producing
# a client secret nothing can authenticate with.
#
# Every value is read back before being regenerated. A rotated client secret is
# a two-sided change (Keycloak and the consumer), so on a seed-missing pass the
# existing values have to survive even though the secrets that mirror them
# below are written unconditionally.
# ---------------------------------------------------------------------------
sso_secret() {
  local existing
  existing="$(reuse_or_generate mini-platform/keycloak-sso "$1")"
  printf '%s' "${existing:-$(rand_hex)}"
}

GRAFANA_CLIENT_SECRET="$(sso_secret GRAFANA_CLIENT_SECRET)"
OPEN_WEBUI_CLIENT_SECRET="$(sso_secret OPEN_WEBUI_CLIENT_SECRET)"
SUPERSET_CLIENT_SECRET="$(sso_secret SUPERSET_CLIENT_SECRET)"
JUPYTERHUB_CLIENT_SECRET="$(sso_secret JUPYTERHUB_CLIENT_SECRET)"
ARGOCD_CLIENT_SECRET="$(sso_secret ARGOCD_CLIENT_SECRET)"
MINIO_CLIENT_SECRET="$(sso_secret MINIO_CLIENT_SECRET)"
LANGFUSE_CLIENT_SECRET="$(sso_secret LANGFUSE_CLIENT_SECRET)"
OAUTH2_PROXY_CLIENT_SECRET="$(sso_secret OAUTH2_PROXY_CLIENT_SECRET)"
SSO_ADMIN_PASSWORD="${SSO_ADMIN_PASSWORD:-$(reuse_or_generate mini-platform/keycloak-sso SSO_ADMIN_PASSWORD)}"
SSO_ADMIN_PASSWORD="${SSO_ADMIN_PASSWORD:-$(rand_b64)}"
SSO_USER_PASSWORD="${SSO_USER_PASSWORD:-$(reuse_or_generate mini-platform/keycloak-sso SSO_USER_PASSWORD)}"
SSO_USER_PASSWORD="${SSO_USER_PASSWORD:-$(rand_b64)}"

kv_put mini-platform/keycloak-sso \
  GRAFANA_CLIENT_SECRET="$GRAFANA_CLIENT_SECRET" \
  OPEN_WEBUI_CLIENT_SECRET="$OPEN_WEBUI_CLIENT_SECRET" \
  SUPERSET_CLIENT_SECRET="$SUPERSET_CLIENT_SECRET" \
  JUPYTERHUB_CLIENT_SECRET="$JUPYTERHUB_CLIENT_SECRET" \
  ARGOCD_CLIENT_SECRET="$ARGOCD_CLIENT_SECRET" \
  MINIO_CLIENT_SECRET="$MINIO_CLIENT_SECRET" \
  LANGFUSE_CLIENT_SECRET="$LANGFUSE_CLIENT_SECRET" \
  OAUTH2_PROXY_CLIENT_SECRET="$OAUTH2_PROXY_CLIENT_SECRET" \
  SSO_ADMIN_PASSWORD="$SSO_ADMIN_PASSWORD" \
  SSO_USER_PASSWORD="$SSO_USER_PASSWORD"

# Two mirrors of keycloak-sso, needed because their consumers dictate the key
# names: the oauth2-proxy chart looks up client-id/client-secret/cookie-secret,
# and Argo CD resolves `$argocd-oidc:clientSecret` against a Secret in its own
# namespace. Both carry whatever value the authoritative secret above settled
# on, so a seed-missing pass that adds one of these mirrors to an existing
# cluster hands the consumer the client secret Keycloak already accepts.
OAUTH2_PROXY_COOKIE_SECRET="${OAUTH2_PROXY_COOKIE_SECRET:-$(reuse_or_generate mini-platform/oauth2-proxy-oidc cookie-secret)}"
OAUTH2_PROXY_COOKIE_SECRET="${OAUTH2_PROXY_COOKIE_SECRET:-$(rand_cookie)}"
kv_put mini-platform/oauth2-proxy-oidc \
  client-id=oauth2-proxy \
  client-secret="$OAUTH2_PROXY_CLIENT_SECRET" \
  cookie-secret="$OAUTH2_PROXY_COOKIE_SECRET"
kv_put mini-platform/argocd-oidc clientSecret="$ARGOCD_CLIENT_SECRET"
kv_put mini-platform/minio-root-credentials \
  rootUser=mini-platform \
  rootPassword="$(rand_b64)"

# DeepSeek is the model behind kagent's agents, reached through LiteLLM so the
# key stays in one place. Required only when this secret is actually written,
# matching how HF_TOKEN is handled above.
if [[ "$SEED_MISSING_ONLY" != true ]] || ! vault_cli kv get mini-platform/litellm-deepseek >/dev/null 2>&1; then
  : "${DEEPSEEK_API_KEY:?Set DEEPSEEK_API_KEY to a DeepSeek API key for the LiteLLM model kagent uses.}"
fi
kv_put mini-platform/litellm-deepseek DEEPSEEK_API_KEY="${DEEPSEEK_API_KEY:-}"

# kagent authenticates to LiteLLM with the master key, the same way Prometheus
# does for the proxy's /metrics. The key name is OPENAI_API_KEY because kagent
# reaches the gateway over the OpenAI protocol.
kv_put mini-platform/kagent-litellm OPENAI_API_KEY="$LITELLM_MASTER_KEY"

# grafana-mcp loads this Secret with envFrom, so the field names are the env
# vars mcp-grafana reads. Same credentials Grafana enforces, carried over from
# grafana-admin above.
kv_put mini-platform/kagent-grafana \
  GRAFANA_USERNAME="$GRAFANA_ADMIN_USER" \
  GRAFANA_PASSWORD="$GRAFANA_ADMIN_PASSWORD"

# HolmesGPT mounts all three of these with envFrom, so the field names are the
# env vars it reads. The first two are mirrors, for the same reasons the kagent
# pair above are: the gateway and Grafana each already own their credential.
#
# Deliberately not named OPENAI_API_KEY, the way kagent's copy is. Holmes keeps
# a backward-compatibility path that, on finding OPENAI_API_KEY in its
# environment, registers a second model against api.openai.com and makes *that*
# one the default -- which would send every request that omits a model name to
# OpenAI carrying the gateway's key.
kv_put mini-platform/holmes-litellm LITELLM_API_KEY="$LITELLM_MASTER_KEY"
kv_put mini-platform/holmes-grafana \
  GRAFANA_USERNAME="$GRAFANA_ADMIN_USER" \
  GRAFANA_PASSWORD="$GRAFANA_ADMIN_PASSWORD"

# Holmes has no login of its own, so HOLMES_API_KEY is the whole of its
# authentication: with it set, every route except /healthz and /readyz demands
# the key in an X-API-Key or Authorization: Bearer header. Rotating it locks out
# existing callers, which is the point of kv_put's skip on an upgrade pass.
#
# HOLMES_APPROVAL_SIGNING_KEY signs the short-lived tokens Holmes mints for tool
# calls that need a human to approve them. Left unset it generates one per
# process, and every restart invalidates the approvals already in flight.
kv_put mini-platform/holmes-api \
  HOLMES_API_KEY="$(rand_b64)" \
  HOLMES_APPROVAL_SIGNING_KEY="$(rand_b64)"

printf '%s\n' \
  "Base Mini Platform secrets, including Langfuse project bootstrap keys, have been written to Vault."
