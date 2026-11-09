#!/usr/bin/env bash
set -euo pipefail

: "${VAULT_ADDR:?Set VAULT_ADDR to the initialized Vault server address.}"
: "${VAULT_TOKEN:?Set VAULT_TOKEN to a token allowed to write mini-platform/ secrets.}"
HF_TOKEN="${HF_TOKEN:-}"
HOLMES_GITHUB_TOKEN="${HOLMES_GITHUB_TOKEN:-}"
HOLMES_ARGOCD_AUTH_TOKEN="${HOLMES_ARGOCD_AUTH_TOKEN:-}"

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
# Without this, seeding a newly added mirror (e.g. kagent-agentgateway) onto a
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
REDIS_PASSWORD="${REDIS_PASSWORD:-$(rand_b64)}"
HOLMES_LANGFUSE_PUBLIC_KEY="${HOLMES_LANGFUSE_PUBLIC_KEY:-$(reuse_or_generate mini-platform/holmes-langfuse-project LANGFUSE_PUBLIC_KEY)}"
HOLMES_LANGFUSE_PUBLIC_KEY="${HOLMES_LANGFUSE_PUBLIC_KEY:-lf_pk_$(rand_hex)}"
HOLMES_LANGFUSE_SECRET_KEY="${HOLMES_LANGFUSE_SECRET_KEY:-$(reuse_or_generate mini-platform/holmes-langfuse-project LANGFUSE_SECRET_KEY)}"
HOLMES_LANGFUSE_SECRET_KEY="${HOLMES_LANGFUSE_SECRET_KEY:-lf_sk_$(rand_hex)}"
OPEN_WEBUI_LANGFUSE_PUBLIC_KEY="${OPEN_WEBUI_LANGFUSE_PUBLIC_KEY:-$(reuse_or_generate mini-platform/open-webui-langfuse-project LANGFUSE_PUBLIC_KEY)}"
OPEN_WEBUI_LANGFUSE_PUBLIC_KEY="${OPEN_WEBUI_LANGFUSE_PUBLIC_KEY:-lf_pk_$(rand_hex)}"
OPEN_WEBUI_LANGFUSE_SECRET_KEY="${OPEN_WEBUI_LANGFUSE_SECRET_KEY:-$(reuse_or_generate mini-platform/open-webui-langfuse-project LANGFUSE_SECRET_KEY)}"
OPEN_WEBUI_LANGFUSE_SECRET_KEY="${OPEN_WEBUI_LANGFUSE_SECRET_KEY:-lf_sk_$(rand_hex)}"
KAGENT_LANGFUSE_PUBLIC_KEY="${KAGENT_LANGFUSE_PUBLIC_KEY:-$(reuse_or_generate mini-platform/kagent-langfuse-project LANGFUSE_PUBLIC_KEY)}"
KAGENT_LANGFUSE_PUBLIC_KEY="${KAGENT_LANGFUSE_PUBLIC_KEY:-lf_pk_$(rand_hex)}"
KAGENT_LANGFUSE_SECRET_KEY="${KAGENT_LANGFUSE_SECRET_KEY:-$(reuse_or_generate mini-platform/kagent-langfuse-project LANGFUSE_SECRET_KEY)}"
KAGENT_LANGFUSE_SECRET_KEY="${KAGENT_LANGFUSE_SECRET_KEY:-lf_sk_$(rand_hex)}"
SUPERSET_DB_PASSWORD="${SUPERSET_DB_PASSWORD:-$(rand_hex)}"
SUPERSET_REDIS_PASSWORD="${SUPERSET_REDIS_PASSWORD:-$(rand_hex)}"
SUPERSET_ADMIN_PASSWORD="${SUPERSET_ADMIN_PASSWORD:-$(rand_b64)}"

# The shared PostgreSQL and Redis. No consumer has its own role or database on
# them today (LiteLLM had, until agentgateway replaced it); `password` is the
# chart's optional application-user slot, unused.
kv_put mini-platform/postgresql-credentials \
  postgres-password="$POSTGRES_ADMIN_PASSWORD" \
  password="$(rand_hex)" \
  metrics-password="$(rand_b64)"
kv_put mini-platform/redis-credentials redis-password="$REDIS_PASSWORD"

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
# Kept separate from the derived exporter header below: only the provisioning
# job and Langfuse receive these raw project keys; the Holmes pod does not.
kv_put mini-platform/holmes-langfuse-project \
  LANGFUSE_PUBLIC_KEY="$HOLMES_LANGFUSE_PUBLIC_KEY" \
  LANGFUSE_SECRET_KEY="$HOLMES_LANGFUSE_SECRET_KEY"

# Holmes exports its native investigation spans straight to Langfuse. The OTel
# exporter expects an already-encoded Basic-auth header, so expose only that
# derived value to Holmes rather than mounting the Langfuse project keys there.
LANGFUSE_BASIC_AUTH="$(printf '%s' "${HOLMES_LANGFUSE_PUBLIC_KEY}:${HOLMES_LANGFUSE_SECRET_KEY}" | base64 | tr -d '\n')"
# This is a derived mirror, so rewrite it even during seed-missing upgrades:
# it must always match the project keys above without rotating them.
vault_cli kv put mini-platform/holmes-langfuse \
  OTEL_EXPORTER_OTLP_HEADERS="Authorization=Basic ${LANGFUSE_BASIC_AUTH}" \
  OTEL_EXPORTER_OTLP_TRACES_HEADERS="Authorization=Basic ${LANGFUSE_BASIC_AUTH}"

# Open WebUI's built-in HTTP OTLP exporter accepts a username/password pair
# rather than a pre-encoded header. Keep the provisioning and runtime mirrors
# separate so each Argo CD application owns only the Secret it consumes.
kv_put mini-platform/open-webui-langfuse-project \
  LANGFUSE_PUBLIC_KEY="$OPEN_WEBUI_LANGFUSE_PUBLIC_KEY" \
  LANGFUSE_SECRET_KEY="$OPEN_WEBUI_LANGFUSE_SECRET_KEY"
kv_put mini-platform/open-webui-langfuse \
  OTEL_BASIC_AUTH_USERNAME="$OPEN_WEBUI_LANGFUSE_PUBLIC_KEY" \
  OTEL_BASIC_AUTH_PASSWORD="$OPEN_WEBUI_LANGFUSE_SECRET_KEY"

# The kagent project's pair. No runtime mirror here, unlike the two above:
# kagent exports nothing itself, Alloy exports for it, and otelcol.auth.basic
# takes whichever env vars alloy-values.yaml maps these keys onto.
kv_put mini-platform/kagent-langfuse-project \
  LANGFUSE_PUBLIC_KEY="$KAGENT_LANGFUSE_PUBLIC_KEY" \
  LANGFUSE_SECRET_KEY="$KAGENT_LANGFUSE_SECRET_KEY"
# Langfuse headless init user: makes the auto-provisioned org/project visible in
# the UI (org/project alone are API-only; a fresh signup joins no org).
#
# The address is the realm's platform-admin, deliberately, and it is the only
# thing making SSO useful here. Langfuse links an OIDC identity to an existing
# account by matching email; seeded under any other address, nothing matches, a
# Keycloak login lands on a brand-new account belonging to no organization, and
# the seeded org and its projects stay invisible to the person who just
# logged in. Matching it makes the SSO login *be* the owner account. Keep it in
# step with the seed user in minikube/values/keycloak-values.yaml.
#
# Written directly rather than through kv_put, because a seed-missing pass is
# exactly the case that has to change: an existing cluster already holds this
# path under the old admin@ address, kv_put would keep it, and the mismatch
# above would survive the upgrade that is meant to fix it. Only the password is
# a credential, so carry that forward and rewrite the rest.
LANGFUSE_INIT_USER_PASSWORD="${LANGFUSE_INIT_USER_PASSWORD:-$(reuse_or_generate mini-platform/langfuse-init-user LANGFUSE_INIT_USER_PASSWORD)}"
LANGFUSE_INIT_USER_PASSWORD="${LANGFUSE_INIT_USER_PASSWORD:-$(rand_b64)}"
vault_cli kv put mini-platform/langfuse-init-user \
  LANGFUSE_INIT_USER_EMAIL=platform-admin@mini-platform.test \
  LANGFUSE_INIT_USER_NAME="Platform Admin" \
  LANGFUSE_INIT_USER_PASSWORD="$LANGFUSE_INIT_USER_PASSWORD"

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
# Open WebUI otherwise generates this in the container filesystem. Every pod
# replacement then invalidates browser cookies and in-flight OIDC sessions.
WEBUI_SECRET_KEY="$(sso_secret WEBUI_SECRET_KEY)"
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
  WEBUI_SECRET_KEY="$WEBUI_SECRET_KEY" \
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

# grafana-mcp loads this Secret with envFrom, so the field names are the env
# vars mcp-grafana reads. Same credentials Grafana enforces, carried over from
# grafana-admin above.
kv_put mini-platform/kagent-grafana \
  GRAFANA_USERNAME="$GRAFANA_ADMIN_USER" \
  GRAFANA_PASSWORD="$GRAFANA_ADMIN_PASSWORD"

# HolmesGPT mounts these with envFrom, so the field names are the env vars it
# reads. Its gateway key is mirrored with the agentgateway keys below; this one
# is a mirror of Grafana's own credential.
kv_put mini-platform/holmes-grafana \
  GRAFANA_USERNAME="$GRAFANA_ADMIN_USER" \
  GRAFANA_PASSWORD="$GRAFANA_ADMIN_PASSWORD"

# External, read-only credentials for Holmes' GitHub MCP and Argo CD toolsets.
# Require each only when its Vault path will actually be written, matching the
# HF/DeepSeek upgrade behavior above. Existing tokens survive seed-missing
# upgrades; --rotate-secrets deliberately demands replacements.
if [[ "$SEED_MISSING_ONLY" != true ]] || ! vault_cli kv get mini-platform/holmes-github >/dev/null 2>&1; then
  : "${HOLMES_GITHUB_TOKEN:?Set HOLMES_GITHUB_TOKEN to a read-only GitHub PAT for Holmes MCP.}"
fi
kv_put mini-platform/holmes-github token="$HOLMES_GITHUB_TOKEN"

if [[ "$SEED_MISSING_ONLY" != true ]] || ! vault_cli kv get mini-platform/holmes-argocd >/dev/null 2>&1; then
  : "${HOLMES_ARGOCD_AUTH_TOKEN:?Set HOLMES_ARGOCD_AUTH_TOKEN to a token for the Argo CD holmes account.}"
fi
kv_put mini-platform/holmes-argocd ARGOCD_AUTH_TOKEN="$HOLMES_ARGOCD_AUTH_TOKEN"

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


# agentgateway, the platform's model and tool gateway (docs/agentgateway.md).
# One API key per client. agentgateway reads agentgateway-api-keys, one entry
# per client whose JSON value carries the key and the client name the OPA
# policy keys on (policies/gateway); each client reads its raw key from
# agentgateway-client-keys. Both are written from the same values, reused on a
# SEED_MISSING_ONLY pass so a client never holds a key the gateway does not.
AGW_CLIENTS=(open-webui kagent holmes admin)
agw_raw=() agw_json=()
for client in "${AGW_CLIENTS[@]}"; do
  key="$(reuse_or_generate mini-platform/agentgateway-client-keys "$client")"
  key="${key:-$(rand_b64)}"
  agw_raw+=("$client=$key")
  agw_json+=("$client={\"key\":\"$key\",\"metadata\":{\"client\":\"$client\"}}")
done
kv_put mini-platform/agentgateway-client-keys "${agw_raw[@]}"
kv_put mini-platform/agentgateway-api-keys "${agw_json[@]}"

# The clients' own copies, under the env names each one reads. Taken from the
# path just written (not the loop) so a SEED_MISSING_ONLY pass that kept an
# existing agentgateway-client-keys still hands out the key the gateway knows.
# kagent: OPENAI_API_KEY, its OpenAI-protocol client's name. Holmes: anything
# but OPENAI_API_KEY (see holmes-values.yaml).
kv_put mini-platform/kagent-agentgateway \
  OPENAI_API_KEY="$(kv_field mini-platform/agentgateway-client-keys kagent)"
kv_put mini-platform/holmes-agentgateway \
  AGENTGATEWAY_API_KEY="$(kv_field mini-platform/agentgateway-client-keys holmes)"
kv_put mini-platform/open-webui-agentgateway \
  OPENAI_API_KEY="$(kv_field mini-platform/agentgateway-client-keys open-webui)"

# DeepSeek, the hosted model kagent's agents and Holmes use through the
# gateway, which sends this value as the Authorization header (with Bearer
# added). Required only when this secret is actually written, matching how
# HF_TOKEN is handled above.
if [[ "$SEED_MISSING_ONLY" != true ]] || ! vault_cli kv get mini-platform/agentgateway-deepseek >/dev/null 2>&1; then
  : "${DEEPSEEK_API_KEY:?Set DEEPSEEK_API_KEY to a DeepSeek API key for the deepseek-v4-pro model on the gateway.}"
fi
kv_put mini-platform/agentgateway-deepseek Authorization="${DEEPSEEK_API_KEY:-}"

# agentregistry's PostgreSQL (its own release). The URL repeats the user
# password, so both are written from one value, reused on a SEED_MISSING_ONLY
# pass so they can't drift apart.
AGENTREGISTRY_DB_PASSWORD="$(reuse_or_generate mini-platform/agentregistry-postgresql password)"
AGENTREGISTRY_DB_PASSWORD="${AGENTREGISTRY_DB_PASSWORD:-$(rand_hex)}"
kv_put mini-platform/agentregistry-postgresql \
  postgres-password="$(rand_hex)" \
  password="$AGENTREGISTRY_DB_PASSWORD"
kv_put mini-platform/agentregistry-db \
  AGENT_REGISTRY_DATABASE_URL="postgres://agentregistry:${AGENTREGISTRY_DB_PASSWORD}@agentregistry-postgresql:5432/agentregistry?sslmode=disable"

# MinIO accounts for the OPA policy bundles: OCP writes them, OPA reads them.
# The access key names the account; the field names are what the AWS SDKs in
# both read from the environment.
kv_put mini-platform/opa-bundles-writer \
  AWS_ACCESS_KEY_ID=ocp \
  AWS_SECRET_ACCESS_KEY="$(rand_b64)"
kv_put mini-platform/opa-bundles-reader \
  AWS_ACCESS_KEY_ID=opa \
  AWS_SECRET_ACCESS_KEY="$(rand_b64)"

printf '%s\n' \
  "Base Mini Platform secrets, including Langfuse project bootstrap keys, have been written to Vault."
