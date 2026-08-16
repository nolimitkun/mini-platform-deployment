# Mini Platform

Mini Platform is a self-contained Kubernetes reference stack for local LLM
inference, LLM observability, experiment tracking, and SQL analytics. **This is
the deployment repo:** it holds the integration overlays under
[`minikube/values/`](minikube/values/), the Argo CD app-of-apps wiring under
[`minikube/gitops/`](minikube/gitops/), and the bootstrap scripts. The vendored
upstream Helm charts live in a **separate charts repo**
([`mini-platform`](https://github.com/nolimitkun/mini-platform)); **Argo CD**
reconciles the stack by combining the two.

Each generated Argo CD Application is **multi-source**: it pulls its chart from
the charts repo and its values file from this repo via a `$deploy` source ref.
The `minikube/` directory is one environment overlay — additional environments
live beside it and reuse the same charts repo.

Two principles shape the design:

- **GitOps.** Argo CD is the only thing that deploys workloads. After you change
  an overlay or GitOps chart, commit and push it — Argo CD does not read a local
  working tree.
- **No credentials in Git.** **Vault** is the source of truth for application
  credentials, and **Vault Secrets Operator (VSO)** materializes only the
  Kubernetes Secrets each release needs.

## Architecture

The default AI request path is:

```text
Open WebUI ──▶ LiteLLM ──▶ vLLM Router ──▶ vLLM
                  │
                  └──▶ Langfuse (request traces)
```

Open WebUI talks to LiteLLM as an OpenAI-compatible gateway; LiteLLM routes the
`qwen3.6-27b` model to the vLLM router serving `unsloth/Qwen3.6-27B-MTP-GGUF:Q4_K_M`, and emits
traces to Langfuse using project keys it shares with Langfuse through Vault.

Supporting subsystems:

```text
Vault ──▶ Vault Secrets Operator ──▶ Kubernetes Secrets ──▶ workloads

Ingress NGINX ──▶ Open WebUI, LiteLLM, Langfuse, MLflow, Grafana,
                  JupyterHub, Superset, MinIO Console, Keycloak, kagent,
                  HolmesGPT, Argo CD

Prometheus     ──▶ Grafana            (metrics + dashboards)
Alloy ──▶ Loki ──▶ Grafana            (pod logs, every pod in every namespace)
Keycloak, Trino, vLLM, LiteLLM, Open WebUI, kagent, Argo CD
      ─OTLP─▶ Alloy ─┬─▶ Tempo        (traces)
                     └─▶ Prometheus   (OTLP metrics, remote write)
kagent ──▶ LiteLLM                    (agents; DeepSeek through the gateway)
       └─▶ Grafana MCP ──▶ Prometheus, Loki, Tempo
HolmesGPT ──▶ LiteLLM                 (root-cause analysis; same gateway)
          ├─▶ Kubernetes API          (read-only ClusterRole)
          ├─▶ Prometheus              (direct)
          ├─▶ Grafana ──▶ Loki, Tempo (datasource proxy)
          └─OTLP/HTTP─▶ Langfuse      (native investigation traces)
MLflow                                (experiment + artifact tracking)
Qdrant                                (vector store for notebook/RAG examples)
Spark Operator ──▶ Spark batch jobs
Superset       ──▶ Trino ──▶ analytics sources
Keycloak                              (identity provider; SSO for every UI)
MinIO                                 (shared S3-compatible object store)
Argo CD        ──▶ reconciles every release + secret mapping from Git
```

Langfuse, MLflow, and Superset each deploy their own isolated stateful
dependencies so their upgrades stay independent of the LiteLLM gateway. Vault
runs as a single persistent standalone server in this starter configuration and
**must be initialized and unsealed before dependent applications turn healthy.**

Every browser-facing service authenticates against Keycloak — see
[Single Sign-On](#single-sign-on).

## Repository Layout

| Path | Purpose |
| --- | --- |
| `minikube/values/` | Mini Platform integration overlays — no committed credentials |
| `minikube/values/*-resources.yaml` | Per-release `.test` ingress route and `VaultStaticSecret` mappings, rendered inside that release's own Argo CD Application |
| `minikube/gitops/mini-platform/` | Argo CD app-of-apps chart defining every managed release and its sync wave |
| `minikube/gitops/app-resources/` | Shared chart that turns a `*-resources.yaml` into Ingresses (including the oauth2-proxy forward-auth wiring) and Vault secret mappings |
| `minikube/gitops/root-application.yaml` | Root Argo CD Application that bootstraps the app-of-apps |
| `scripts/deploy-minikube.sh` | Creates/resets Minikube and automates the Argo CD + Vault bootstrap |
| `scripts/bootstrap-vault-secrets.sh` | Generates and writes initial credentials into Vault |
| `scripts/port-forward-services.sh` | Host-local or LAN port forwards for browser services |
| `scripts/check-local-deployment.sh` | Verifies local Argo CD sync/health, pod readiness, secret sync, and optional Open WebUI smoke test |
| `scripts/set-repo.sh` | Repoints the charts/deploy repo URLs and revisions in one command |
| `scripts/validate-gitops.sh` | Lints/renders the GitOps charts and shellchecks the scripts; run in CI too |
| `tools/` | Optional utility workloads (e.g. network diagnostics) |

The vendored charts (`charts/`) live in the separate
[`mini-platform`](https://github.com/nolimitkun/mini-platform) repo. Several
scripts expect a local checkout of it as a sibling directory
(`../mini-platform`); override with `--charts-dir` or `CHARTS_DIR`.

## Deployment

All commands run from the repository root.

> **GitOps reminder.** The stack reconciles from two sources — the charts repo
> and this deployment repo — each with its own URL and revision. When deploying
> forks or different branches, repoint every reference in one step, then commit
> and push before syncing:
>
> ```bash
> ./scripts/set-repo.sh \
>   --charts-repo-url https://github.com/<owner>/mini-platform.git --charts-revision main \
>   --deploy-repo-url https://github.com/<owner>/mini-platform-deployment.git --deploy-revision main
> ```
>
> This rewrites
> [`minikube/gitops/root-application.yaml`](minikube/gitops/root-application.yaml),
> [`minikube/gitops/mini-platform/values.yaml`](minikube/gitops/mini-platform/values.yaml),
> and the `scripts/deploy-minikube.sh` defaults so they stay in sync.

### Prerequisites

- Kubernetes `1.33` or newer. The JupyterHub chart needs `1.28`; the floor is
  `1.33` because that is where kube-proxy's nftables mode went GA, and this
  platform has too many Services for the iptables mode to program.
- `helm` 3, `kubectl`, `git`, `jq`, and `openssl` for the automated workflow.
  The manual Vault steps additionally need the Vault CLI.
- Network access from Argo CD to **both** the charts repo and this deployment
  repo (or to pushed forks carrying your changes).
- A local checkout of the charts repo as a sibling directory (`../mini-platform`)
  for the automated script's Argo CD bootstrap; override with `--charts-dir`.
- A default `StorageClass` for platform PVCs, including Vault.
- An NVIDIA-capable node and device plugin for the default vLLM values. Edit
  [`minikube/values/vllm-values.yaml`](minikube/values/vllm-values.yaml) for
  CPU-only testing.

### Recommended: Automated Minikube Deployment

On a GPU-enabled Minikube host, with both repos pushed somewhere Argo CD can
reach:

```bash
# Two external credentials are seeded into Vault during the run. Both are
# demanded well after the cluster and Vault are already up, so a missing one
# aborts the deploy midway rather than at the start.
export HF_TOKEN='hf_xxxxxxxxxxxxxxxxxxxx'        # vLLM model pull
export DEEPSEEK_API_KEY='sk-xxxxxxxxxxxxxxxxxxxx' # model kagent's agents run on

./scripts/deploy-minikube.sh \
  --charts-repo-url https://github.com/<owner>/mini-platform.git --charts-revision main \
  --deploy-repo-url https://github.com/<owner>/mini-platform-deployment.git --deploy-revision main
```

The script picks both up from disk when they are not exported —
`~/.cache/huggingface/token` and `~/.deepseek-key` respectively — so the exports
are only needed the first time. Neither is required on a re-run once its Vault
secret exists; see the script's `--help` for the exact rule.

The script:

- creates/starts the `mini-platform` Minikube profile with NVIDIA GPU
  passthrough by default, and enables the storage and ingress addons;
- installs Argo CD and configures the root Application source;
- initializes and unseals Vault, retaining recovery material at
  `~/.vault-mini-platform-init.json`;
- configures Kubernetes auth and seeds initial credentials; and
- waits for VSO secret synchronization and platform pods to become ready.

Useful flags:

| Flag | Effect |
| --- | --- |
| `--reset` | Delete and recreate the profile first (backs up any existing Vault init JSON) |
| `--local-source` | Serve both committed checkouts (charts + deploy) through a cluster-only Git service instead of a remote |
| `--no-gpu` | Start without GPU passthrough (use only with a CPU-capable vLLM overlay) |
| `--rotate-secrets` | Rewrite Vault credentials on an already-initialized Vault |
| `--skip-image-preload` | Skip loading host-cached images into Minikube |
| `--skip-workload-wait` | Return after secret sync instead of waiting for pods |

Re-running an initialized deployment keeps existing credentials; pass
`--rotate-secrets` only when you intend to replace them.

Rotation is a coordinated operation for the SSO credentials in particular:
Keycloak holds whatever the last realm import wrote, and each component reads
its client secret from an environment variable fixed when its pod started, so
neither side notices a new value in Vault. The script therefore re-runs the
realm import and restarts every consumer as part of the same
`--rotate-secrets` run. Rotating by writing to Vault directly, without that
pass, leaves the two sides disagreeing and SSO fails at the next unrelated pod
restart.

The same restart covers every other workload holding a rotated secret in its
pod spec, not just the SSO consumers — `holmes-holmes`, whose `HOLMES_API_KEY`
*is* its authentication, and `kagent-grafana-mcp`. Without it, Holmes would keep
honouring the old key while the lookup below hands out the new one.

**Deploying from a local checkout.** When the repos live only on the Minikube
host, or are private and Argo CD has no credential, use `--local-source`. Both
the deployment repo and the sibling charts checkout must have a clean tree:

```bash
git -C . status --short                       # this deploy repo — must be clean
git -C ../mini-platform status --short        # charts repo — must be clean
./scripts/deploy-minikube.sh --reset --local-source
```

This creates a persistent, cluster-internal `gitops-source/git-source` service
that serves both repos and pins Argo CD to their current commits. Re-run it
after committing later changes to refresh the source.

**Rootless Docker on Linux.** If Minikube uses rootless Docker on a remote host,
ensure the user's Docker service keeps running without an active login (user
lingering). Otherwise the cluster stops when the SSH session exits — the script
warns about this but does not change the setting for you.

### Manual Deployment Steps

#### Optional: Prepare a Minikube cluster

Minikube's defaults are too small for this stack. For a CPU-only evaluation
cluster:

```bash
minikube start -p mini-platform \
  --driver=docker \
  --kubernetes-version=v1.34.4 \
  --extra-config=kube-proxy.mode=nftables \
  --cpus=8 --memory=65536 --disk-size=100g
```

`kube-proxy.mode=nftables` is not optional. In its default iptables mode
kube-proxy pushes the whole ruleset through a single `iptables-restore`, and the
bundled iptables 1.8.9 sends that as one netlink message; this platform's ~70
Services exceed the 64 KiB message limit, so every sync fails and no Service
VIP — cluster DNS included — is ever programmed.

The default
[`minikube/values/vllm-values.yaml`](minikube/values/vllm-values.yaml) requests
an NVIDIA GPU. On a host with NVIDIA container runtime support, start with GPU
passthrough instead:

```bash
minikube start -p mini-platform \
  --driver=docker --container-runtime=docker --gpus=nvidia \
  --kubernetes-version=v1.34.4 \
  --extra-config=kube-proxy.mode=nftables \
  --cpus=8 --memory=65536 --disk-size=100g
```

Without GPU access, adjust the vLLM overlay before deploying or its pod stays
unschedulable. Then confirm a default StorageClass exists:

```bash
kubectl config use-context mini-platform
kubectl get nodes
kubectl get storageclass
# If no default is shown:
minikube addons enable storage-provisioner -p mini-platform
minikube addons enable default-storageclass -p mini-platform
```

Enable the ingress controller (the checked-in routes use `.test` hostnames):

```bash
minikube addons enable ingress -p mini-platform
kubectl -n ingress-nginx rollout status deployment/ingress-nginx-controller --timeout=120s
kubectl -n ingress-nginx patch service ingress-nginx-controller \
  --type merge -p '{"spec":{"type":"LoadBalancer"}}'
```

With the Docker driver on macOS or Windows, keep one tunnel running for the
ingress controller rather than a port-forward per service:

```bash
minikube tunnel -p mini-platform
```

Once the tunnel assigns an external IP, map the local hostnames:

```bash
export INGRESS_IP="$(kubectl -n ingress-nginx get service ingress-nginx-controller \
  -o jsonpath='{.status.loadBalancer.ingress[0].ip}')"
printf '%s %s\n' "$INGRESS_IP" \
  'argocd.test open-webui.test litellm.test langfuse.test mlflow.test grafana.test jupyterhub.test superset.test minio.test keycloak.test kagent.test holmes.test' \
  | sudo tee -a /etc/hosts
```

On hosts that can reach `minikube ip` directly, the `ingress-dns` addon is an
alternative to editing `/etc/hosts`.

#### 1. Create the namespace

```bash
export NS=mini-platform
kubectl create namespace "$NS" --dry-run=client -o yaml | kubectl apply -f -
```

Do **not** create workload credential Secrets by hand — VSO creates them after
Vault is configured in step 4.

#### 2. Bootstrap Argo CD

Argo CD is installed once with Helm; afterward it reconciles its own chart and
every platform release.

The Argo CD chart comes from the charts repo checkout (`../mini-platform` by
default); its values come from this repo:

```bash
export ARGO_NS=argocd
export CHARTS_DIR=../mini-platform
kubectl create namespace "$ARGO_NS" --dry-run=client -o yaml | kubectl apply -f -
helm upgrade --install argocd "$CHARTS_DIR/charts/argo-cd" \
  -n "$ARGO_NS" -f minikube/values/argo-cd-values.yaml --wait

kubectl -n "$ARGO_NS" get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' | base64 -d
```

With ingress prepared, the Argo CD UI is at `http://argocd.test`. The local
route is plain HTTP; configure TLS and identity integration before exposing it
beyond a development cluster.

#### 3. Apply the root Application

[`minikube/gitops/root-application.yaml`](minikube/gitops/root-application.yaml)
renders the app-of-apps chart, which in turn creates one multi-source Argo CD
Application per release. When deploying forks or other revisions, run
`scripts/set-repo.sh` (above) so both `spec.source.repoURL` /
`spec.source.targetRevision` (the deployment repo, where the app-of-apps chart
lives) **and** the four `spec.source.helm.parameters` (`chartsRepo`,
`chartsRevision`, `deployRepo`, `deployRevision`, which tell that chart where
every managed app reads its chart and values) are updated together.

```bash
kubectl apply -f minikube/gitops/root-application.yaml
kubectl -n argocd get applications
```

Sync waves order the rollout: Argo CD and Vault/VSO come first, then the
stateful dependencies, then the application tier, and finally LiteLLM, Open
WebUI and the agents. Each release brings its own ingress route and
`VaultStaticSecret` mappings with it, so a secret is declared on the
earliest-syncing application that consumes it — and, where a release needs a
dependency *running* rather than just a Secret, a wave later still (MinIO reads
its OIDC configuration once at startup, so it syncs after Keycloak). Early
reconciliations may show missing-secret failures until Vault is initialized in
step 4 and those `VaultStaticSecret` resources synchronize.

#### 4. Initialize Vault and seed secrets

The starter overlay installs one persistent Vault server reachable only over
cluster networking and port-forward. Initialize it once and store the unseal key
and root token **outside this repository**.

```bash
umask 077
kubectl -n "$NS" exec vault-0 -- vault operator init \
  -key-shares=1 -key-threshold=1 -format=json > "$HOME/.vault-mini-platform-init.json"

export VAULT_UNSEAL_KEY='<unseal-key-from-init-output>'
kubectl -n "$NS" exec vault-0 -- vault operator unseal "$VAULT_UNSEAL_KEY"

kubectl -n "$NS" port-forward svc/vault-ui 8200:8200
```

In a second terminal, configure the KV store and Kubernetes auth that VSO uses,
then seed credentials:

```bash
export VAULT_ADDR=http://127.0.0.1:8200
export VAULT_TOKEN='<initial-root-token-from-init-output>'
# Hugging Face token used by vLLM to pull the model weights and the base
# tokenizer (Qwen/Qwen3.6-27B). Accept any gated-model licenses at
# huggingface.co with this account first, or the vLLM pull will 401.
export HF_TOKEN='hf_xxxxxxxxxxxxxxxxxxxx'
# DeepSeek key for the hosted `deepseek-v4-pro` model LiteLLM serves. kagent's
# agents and HolmesGPT run on it; nothing else on the platform requires it.
export DEEPSEEK_API_KEY='sk-xxxxxxxxxxxxxxxxxxxx'

vault secrets enable -path=mini-platform kv-v2
vault auth enable kubernetes
vault write auth/kubernetes/config \
  kubernetes_host=https://kubernetes.default.svc.cluster.local:443

vault policy write mini-platform-read - <<'EOF'
path "mini-platform/data/*" {
  capabilities = ["read"]
}
path "mini-platform/metadata/*" {
  capabilities = ["read", "list"]
}
EOF

vault write auth/kubernetes/role/mini-platform \
  bound_service_account_names=vault-auth \
  bound_service_account_namespaces=mini-platform \
  audience=vault \
  policies=mini-platform-read \
  ttl=1h

vault audit enable file file_path=/vault/audit/audit.log
./scripts/bootstrap-vault-secrets.sh
```

`bootstrap-vault-secrets.sh` generates random credentials for every component
and writes them under `mini-platform/`. It also writes the `HF_TOKEN` you export
to `mini-platform/vllm-hf-token`, which vLLM uses to pull the model weights, and
the `DEEPSEEK_API_KEY` to `mini-platform/litellm-deepseek` for the hosted model
kagent runs on. Four of the secrets it writes are copies rather than fresh
credentials — `mini-platform/kagent-litellm` and `mini-platform/holmes-litellm`
mirror the LiteLLM master key, `mini-platform/kagent-grafana` and
`mini-platform/holmes-grafana` the Grafana admin login — so on a
`SEED_MISSING_ONLY=true` upgrade the script reads the existing values back out
of Vault instead of generating new ones that the owning service would reject.
Notably, it writes shared Langfuse project keys to
`mini-platform/litellm-langfuse`: Langfuse's headless init provisions the
starter organization and project from those keys, and LiteLLM consumes the same
Vault-managed secret for tracing. It also derives the Basic-auth header in
`mini-platform/holmes-langfuse`, which lets Holmes send its own investigation
traces directly to that project without mounting the raw project keys.

VSO then creates the destination Kubernetes Secrets. Check synchronization:

```bash
kubectl -n "$NS" get vaultstaticsecrets
kubectl -n "$NS" get secrets
```

> This starter configuration uses manual unseal and disables in-cluster TLS. For
> production, configure TLS, auto-unseal, tightly scoped tokens, backups, and an
> HA storage backend before storing real credentials.

#### 5. Managed releases

The app-of-apps reconciles these applications. Each is multi-source: the chart
below, plus — where the release owns an ingress route or Vault secrets — the
shared `minikube/gitops/app-resources` chart rendered against a sibling
`minikube/values/<name>-resources.yaml`:

| Argo CD application | Chart | Values |
| --- | --- | --- |
| `mini-platform-argocd` | `charts/argo-cd` | `minikube/values/argo-cd-values.yaml` |
| `mini-platform-vault` | `charts/vault` | `minikube/values/vault-values.yaml` |
| `mini-platform-vault-secrets-operator` | `charts/vault-secrets-operator` | `minikube/values/vault-secrets-operator-values.yaml` |
| `mini-platform-postgresql` | `charts/postgresql` | `minikube/values/postgresql-values.yaml` |
| `mini-platform-redis` | `charts/redis` | `minikube/values/redis-values.yaml` |
| `mini-platform-qdrant` | `charts/qdrant` | `minikube/values/qdrant-values.yaml` |
| `mini-platform-minio` | `charts/minio` | `minikube/values/minio-values.yaml` |
| `mini-platform-spark-operator` | `charts/spark-operator` | `minikube/values/spark-operator-values.yaml` |
| `mini-platform-keycloak` | `charts/keycloak` | `minikube/values/keycloak-values.yaml` |
| `mini-platform-langfuse` | `charts/langfuse` | `minikube/values/langfuse-values.yaml` |
| `mini-platform-mlflow` | `charts/mlflow` | `minikube/values/mlflow-values.yaml` |
| `mini-platform-trino` | `charts/trino` | `minikube/values/trino-values.yaml` |
| `mini-platform-vllm` | `charts/vllm-stack` | `minikube/values/vllm-values.yaml` |
| `mini-platform-llm-d-modelserver`† | `minikube/gitops/llm-d-modelserver` | `minikube/gitops/llm-d-modelserver/values.yaml` |
| `mini-platform-llm-d-scheduler`† | `charts/llm-d-scheduler` | `minikube/values/llm-d-scheduler-values.yaml` |
| `mini-platform-prometheus` | `charts/prometheus` | `minikube/values/prometheus-values.yaml` |
| `mini-platform-loki` | `charts/loki` | `minikube/values/loki-values.yaml` |
| `mini-platform-tempo` | `charts/tempo` | `minikube/values/tempo-values.yaml` |
| `mini-platform-grafana` | `charts/grafana` | `minikube/values/grafana-values.yaml` |
| `mini-platform-alloy` | `charts/alloy` | `minikube/values/alloy-values.yaml` |
| `mini-platform-jupyterhub` | `charts/jupyterhub` | `minikube/values/jupyterhub-values.yaml` |
| `mini-platform-superset` | `charts/superset` | `minikube/values/superset-values.yaml` |
| `mini-platform-litellm` | `charts/litellm-helm` | `minikube/values/litellm-values.yaml` |
| `mini-platform-open-webui` | `charts/open-webui` | `minikube/values/open-webui-values.yaml` |
| `mini-platform-kagent-crds` | `charts/kagent-crds` | `minikube/values/kagent-crds-values.yaml` |
| `mini-platform-kagent` | `charts/kagent` | `minikube/values/kagent-values.yaml` |
| `mini-platform-holmes` | `charts/holmes` | `minikube/values/holmes-values.yaml` |
| `mini-platform-oauth2-proxy` | `charts/oauth2-proxy` | `minikube/values/oauth2-proxy-values.yaml` |

† **llm-d serving path** (disabled by default): an alternative to the
production-stack router, using the Gateway API Inference Extension standalone
scheduler with llm-d's prefix-cache/load-aware scoring plus a vLLM decode
deployment that mirrors the production-stack engine configuration. The node's
single GPU cannot host both inference paths simultaneously — to switch, set
`enabled: true` on the two llm-d apps **and** scale the `vllm` overlay's
`replicaCount` to 0 (or the reverse), then commit and push. The llm-d client
entrypoint is `llm-d-epp.mini-platform.svc` port 80.

## Accessing Services

### Via ingress

Every browser-facing service is reached by hostname, and **single sign-on only
works this way** — see [Reaching the ingress](#reaching-the-ingress) for how to
get there from your machine, and the note on port 80 in particular.

Map the `.test` hosts in your local resolver or `/etc/hosts`, pointed at
whichever address reaches the ingress controller (see below), then open the
service hostnames:

| Service | Endpoint |
| --- | --- |
| Argo CD | `http://argocd.test` |
| Open WebUI | `http://open-webui.test` |
| LiteLLM API | `http://litellm.test` |
| Langfuse | `http://langfuse.test` |
| MLflow | `http://mlflow.test` |
| Grafana | `http://grafana.test` |
| JupyterHub | `http://jupyterhub.test` |
| Superset | `http://superset.test` |
| MinIO Console | `http://minio.test` |
| Keycloak | `http://keycloak.test` |
| kagent | `http://kagent.test` |
| HolmesGPT API | `http://holmes.test` |

All of these log in through Keycloak — except HolmesGPT, which has no browser UI
and authenticates with its own API key. See
[Single Sign-On](#single-sign-on) for the realm users and what each group
grants.

Vault, Prometheus, Loki, Tempo, Trino, the databases, and vLLM stay
cluster-internal by default — logs and traces are read through Grafana, not
their own UIs. For Vault administration, use a targeted port-forward:

```bash
kubectl -n "$NS" port-forward svc/vault-ui 8200:8200
```

### Reaching the ingress

**Everything below must land on port 80.** Each OIDC client in the Keycloak
realm registers an exact redirect URI — `http://grafana.test/login/generic_oauth`
and so on — with no port, and Keycloak rejects anything that does not match
character for character. Reach a service on `http://grafana.test:8080` and the
page loads, but the login bounces to a port nothing is listening on. The same
applies to `http://keycloak.test` itself, which is the issuer.

Pick whichever of these matches your Docker setup.

**Routable node IP.** Where the Minikube node IP is reachable from the host —
the usual case with rootful Docker or the KVM driver — point the hosts entries
straight at it:

```bash
minikube ip -p mini-platform
```

If the ingress `LoadBalancer` stays `<pending>`, keep a tunnel open in another
terminal:

```bash
minikube tunnel -p mini-platform
```

**Rootless Docker, or any setup where the node IP is not routable.** Rootless
Docker runs the cluster inside a user network namespace: the node IP has no
route from the host at all, and neither the node port nor `minikube tunnel`
helps. Check with `ip route get $(minikube ip -p mini-platform)` — if it
resolves via your default gateway rather than a `br-*` interface, you are in
this case. Forward the ingress controller to localhost instead:

```bash
sudo sysctl -w net.ipv4.ip_unprivileged_port_start=80
```

```bash
kubectl -n ingress-nginx port-forward svc/ingress-nginx-controller 80:80
```

The `sysctl` is what lets a non-root process bind port 80; `sudo -E kubectl …`
works instead if you would rather not change it. Then point every hosts entry at
`127.0.0.1`:

```bash
echo "127.0.0.1 argocd.test grafana.test holmes.test jupyterhub.test kagent.test keycloak.test langfuse.test litellm.test minio.test mlflow.test open-webui.test superset.test" | sudo tee -a /etc/hosts
```

**From other machines on the LAN.** Bind the same forward to all interfaces:

```bash
kubectl -n ingress-nginx port-forward --address 0.0.0.0 svc/ingress-nginx-controller 80:80
```

Then give each client the same hosts line with the *host's* LAN address in place
of `127.0.0.1`; on Windows the file is `C:\Windows\System32\drivers\etc\hosts`,
edited as Administrator. Nothing in the platform changes — the realm, its
clients and oauth2-proxy are all keyed on hostnames, so only the client's name
resolution moves. Open port 80 if a host firewall is enabled, and remember the
whole session, passwords included, crosses the network in cleartext; see
[Production Hardening](#production-hardening).

### Via port-forward

This path reaches each Service directly on its own high port, bypassing the
ingress. **Single sign-on does not work through it** — the redirect URIs in the
realm are `http://<host>/…` on port 80, so a UI served at
`http://127.0.0.1:3000` cannot complete a login. Use it for the break-glass
local accounts (see [Break-glass logins](#break-glass-logins)), for the services
that have no ingress route at all, and as a fallback when host-to-ingress
routing is unavailable. Note that it also bypasses oauth2-proxy: forwarding
MLflow or kagent exposes them unauthenticated, because the forward-auth lives on
the ingress, not on the Service.

Run the port-forward script on the host running Minikube. For host-local access
on `127.0.0.1`:

```bash
./scripts/port-forward-services.sh
```

For LAN access from other machines on a trusted network (listens on all
interfaces and prints the detected LAN IP):

```bash
./scripts/port-forward-services.sh --mode lan
```

If LAN IP autodetection picks the wrong interface, pass it explicitly:

```bash
./scripts/port-forward-services.sh restart --mode lan --address 192.168.1.54
```

Services are then reachable at endpoints like `http://192.168.1.54:8080`. Stop
the forwards with `./scripts/port-forward-services.sh stop`.

For LAN access *with* SSO, forward the ingress controller on port 80 instead —
see [Reaching the ingress](#reaching-the-ingress).

### Retrieving credentials

Vault remains the system of record for browser-service logins; the bootstrap
script never prints them and nothing caches a copy.

The quickest way to see them is the port-forward helper, which reads each value
back out of Vault at print time and lists it under the service URLs:

```bash
scripts/port-forward-services.sh start
```

Pass `--no-credentials` to suppress that table when the output is going into a
screenshare, a log, or an issue. The table degrades to a one-line notice if
Vault is sealed or no token is available — it reads `VAULT_TOKEN` if set, and
otherwise falls back to the root token in
`~/.vault-mini-platform-init.json`. Argo CD is the one entry not backed by
Vault: its initial admin password is generated by the Argo CD chart into a
Kubernetes Secret and is read from there.

To query Vault directly instead, with `VAULT_ADDR` and an authorized
`VAULT_TOKEN` set:

```bash
vault kv get -field=SSO_ADMIN_PASSWORD mini-platform/keycloak-sso
vault kv get -field=SSO_USER_PASSWORD mini-platform/keycloak-sso
vault kv get -field=admin-password mini-platform/grafana-admin
vault kv get -field=admin-password mini-platform/mlflow-auth
vault kv get -field=SUPERSET_ADMIN_PASSWORD mini-platform/superset-env
vault kv get -field=admin-password mini-platform/keycloak-admin
vault kv get -field=rootPassword mini-platform/minio-root-credentials
vault kv get -field=LANGFUSE_INIT_USER_PASSWORD mini-platform/langfuse-init-user
vault kv get -field=PROXY_MASTER_KEY mini-platform/litellm-master-key
```

The first two are the Keycloak realm logins that work across every UI. The rest
are per-component break-glass accounts — see
[Single Sign-On](#single-sign-on) for which ones still accept a form login.

## Single Sign-On

Keycloak is the identity provider for every browser-facing service. The
`mini-platform` realm, its clients, roles, groups and two seed users are
provisioned declaratively by `keycloak-config-cli`, which the Keycloak chart
runs as a post-sync Job — the realm lives in
`minikube/values/keycloak-values.yaml` and is re-imported on every Argo CD sync,
so clients edited by hand in the admin console are reverted. Client secrets are
generated into Vault by `scripts/bootstrap-vault-secrets.sh` and interpolated
into the realm at import time; none of them are in Git.

### Logging in

| Realm user | Group | Password |
| --- | --- | --- |
| `platform-admin` | `platform-admins` | `vault kv get -field=SSO_ADMIN_PASSWORD mini-platform/keycloak-sso` |
| `platform-user` | `platform-users` | `vault kv get -field=SSO_USER_PASSWORD mini-platform/keycloak-sso` |

Add more users in the Keycloak admin console at `http://keycloak.test` (the
`master`-realm admin from `mini-platform/keycloak-admin`), and put them in one
of the two groups — the import does not delete users it did not create.

Authorization everywhere derives from those two groups, carried in a `groups`
claim:

| Component | `platform-admins` | `platform-users` |
| --- | --- | --- |
| Grafana | Admin | Viewer |
| Superset | Admin | Gamma |
| Open WebUI | admin | user |
| JupyterHub | admin | user |
| Argo CD | `role:admin` | `role:readonly` |
| MinIO Console | `consoleAdmin` | `consoleAdmin` |
| MLflow, kagent, LiteLLM UI | access | access |

MinIO authorizes from a claim naming one of its own policies rather than from a
group list, so both groups currently map to `consoleAdmin`; narrowing that means
adding a MinIO policy and mapping the realm role onto it. MLflow, kagent and the
LiteLLM UI sit behind oauth2-proxy, which admits both groups and cannot express
a role distinction downstream.

### How each component is wired

Seven components speak OIDC themselves and are configured in their own overlay:
Grafana, Open WebUI, Superset, JupyterHub, Argo CD, MinIO Console and Langfuse.

Three cannot, and sit behind **oauth2-proxy** as ingress-nginx forward-auth
(`minikube/values/oauth2-proxy-values.yaml`, with each route in its own
component's `minikube/values/<name>-resources.yaml`):

- **MLflow** — the Bitnami chart offers a single basic-auth account and no OIDC.
  The browser UI is protected; `/api` is not, because the MLflow SDK and CLI
  send basic-auth credentials and cannot follow an interactive SSO redirect.
  MLflow authenticates those routes itself with the account in
  `mini-platform/mlflow-auth`. That account guards the UI too, so MLflow is the
  one service that asks twice: Keycloak first, then MLflow's own
  `WWW-Authenticate: Basic` prompt. Both are deliberate — forward-auth cannot
  cover `/api`, and MLflow has no way to trust an identity the proxy already
  established — so the browser prompt is answered with the `mlflow-auth`
  credentials, not a Keycloak account.
- **kagent** — ships no authentication at all.
- **LiteLLM** — its built-in SSO is license-gated. Only `/ui` is protected;
  `/v1` stays open because LiteLLM authenticates API traffic itself with the
  master key and virtual keys.

**HolmesGPT** is outside this scheme entirely. It has no browser UI — every
route is API — so there is no interactive login to federate, and it
authenticates each request itself against `HOLMES_API_KEY` from
`mini-platform/holmes-api`. Putting forward-auth in front of it would 302 every
caller for no gain, which is the same reasoning that keeps MLflow's `/api` and
LiteLLM's `/v1` exempt.

The pattern in both exceptions is the same: a route lists the prefixes it wants
behind Keycloak in `protectedPaths`, and carves back out any path whose clients
authenticate themselves with `openPaths`. nginx matches the longest prefix, so
the exemption wins over the broader protected path.

### The MinIO console loses its SSO button after a cluster restart

MinIO resolves its OIDC discovery URL once, during startup. If that lookup fails
it logs `Unable to initialize OpenID` and carries on without a provider: the
console offers username/password and no Keycloak button, and it never retries.
Keycloak not being up yet is only one way to get there — a CoreDNS rollout or a
recreated pod sandbox does it just as well, and the console stays that way until
MinIO restarts. `deploy-minikube.sh` checks for this and restarts MinIO itself
at the end of a bring-up, but nothing reconciles it afterwards, so a
`minikube stop` / `minikube start` can leave the console without its SSO button.
Check and fix with:

```bash
kubectl -n mini-platform exec deploy/minio -- curl -s http://localhost:9001/api/v1/login
```

`"loginStrategy":"redirect"` means SSO is wired; `"form"` means it is not, and a
restart once the platform is up recovers it:

```bash
kubectl -n mini-platform rollout restart deploy/minio
```

### Break-glass logins

Local accounts are deliberately left enabled, so a broken realm import does not
lock you out: Grafana, Argo CD, MinIO, Langfuse, MLflow and Keycloak's own
`master` realm all still accept their Vault-managed password.

Langfuse's is a special case worth knowing about, because the local account and
the SSO identity are deliberately the *same* account. Its headless init seeds
the owner of the Mini Platform org under the realm's `platform-admin` address,
and `AUTH_KEYCLOAK_ALLOW_ACCOUNT_LINKING` matches on email — so the first
Keycloak login attaches to that account instead of starting an empty one, and
`LANGFUSE_INIT_USER_PASSWORD` is the form-login fallback into the same place.
Seeding it under any other address is what makes an SSO login land in a Langfuse
with no organization and no project visible.

**Superset is the exception.** Flask-AppBuilder supports one `AUTH_TYPE` at a
time, so switching it to `AUTH_OAUTH` retires the username/password form
outright. The `admin` account still exists in the database and its password is
still in Vault, but reaching it means temporarily removing the `keycloak_oauth`
block from `minikube/values/superset-values.yaml`. JupyterHub previously used
z2jh's dummy authenticator, which was not a credential to preserve.

### One issuer URL

Browsers reach Keycloak at `http://keycloak.test` through the ingress, and so do
the in-cluster OIDC clients: `deploy-minikube.sh` adds a CoreDNS `rewrite` so
`keycloak.test` resolves to the Keycloak Service from inside the cluster.

This matters because the issuer has to be identical on both sides. A pod
redeeming an authorization code against `keycloak.mini-platform.svc` would be
handed an `iss` of the internal name while the browser was issued one for
`keycloak.test`, and Argo CD, oauth2-proxy and Langfuse all reject that
mismatch. CoreDNS lives in `kube-system`, outside Argo CD's reconciliation, so
the rewrite is applied imperatively during bring-up; it is idempotent.

Two consequences worth knowing:

- Keycloak issues redirects to `keycloak.test` unconditionally, so its admin
  console is **not** reachable over a port-forward. Use the ingress.
- The registered redirect URIs are all `.test` hostnames, so SSO logins only
  work through the ingress. Port-forwarded UIs still offer their local login
  (where one exists), and port-forwarding MLflow or kagent bypasses
  oauth2-proxy entirely — it protects the ingress path, not the Service.

### Adding a component to SSO

1. Add a client to the realm in `minikube/values/keycloak-values.yaml`, with
   `secret: $(env:<NAME>_CLIENT_SECRET)` and its exact callback URL.
2. Add that same key to the `mini-platform/keycloak-sso` write in
   `scripts/bootstrap-vault-secrets.sh`. The names must match — an unresolved
   variable is imported literally and produces a client secret nothing can
   authenticate with.
3. Point the component's overlay at `secretKeyRef: {name: keycloak-sso, key: …}`
   and the issuer `http://keycloak.test/realms/mini-platform`.

If the component has no OIDC support, skip steps 1–3 and instead add
`protectedPaths` to its route in `minikube/values/<name>-resources.yaml` and a
callback URL on the existing `oauth2-proxy` client.

## Verifying the Stack

**Langfuse + LiteLLM tracing.** Langfuse creates the `mini-platform` org and
`litellm` project from the Vault-managed keys written in step 4; VSO exposes the
same keys to LiteLLM. Confirm the secret synced and both apps are healthy:

```bash
kubectl -n "$NS" get vaultstaticsecret litellm-langfuse
kubectl -n "$NS" get pods -l app.kubernetes.io/instance=langfuse
kubectl -n "$NS" get pods -l app.kubernetes.io/name=litellm
```

**LLM gateway smoke test.** LiteLLM serves the `qwen3.6-27b` model backed by
`http://vllm-router-service.mini-platform.svc.cluster.local/v1`:

```bash
export LITELLM_MASTER_KEY="$(kubectl -n "$NS" get secret litellm-master-key \
  -o jsonpath='{.data.PROXY_MASTER_KEY}' | base64 -d)"
curl http://litellm.test/v1/chat/completions \
  -H "Authorization: Bearer ${LITELLM_MASTER_KEY}" \
  -H 'Content-Type: application/json' \
  -d '{"model":"qwen3.6-27b","messages":[{"role":"user","content":"Say hello in one sentence."}]}'
```

**Analytics.** Superset imports the starter Trino `tpch` catalog at
`trino://superset@trino.mini-platform.svc.cluster.local:8080/tpch`. Trino is
unauthenticated on an internal `ClusterIP` service in this starter config —
configure TLS and authentication before exposing it.

**Spark.** Submit `SparkApplication` resources into `mini-platform` with
`serviceAccount: spark-operator-spark`.

**kagent.** The chat UI is at `http://kagent.test`. Four agents ship enabled —
`k8s-agent`, `helm-agent`, `promql-agent`, and `observability-agent` — all
running on `deepseek-v4-pro` through LiteLLM, so their turns appear in Langfuse
alongside every other LLM call. The agents that target components this platform
does not run (Istio, kgateway, Cilium, Argo Rollouts) are disabled in the
overlay. `observability-agent` is the one wired to live telemetry: it reaches
Prometheus, Loki, and Tempo through `grafana-mcp`, which proxies Grafana's
datasource API using the same admin credentials Grafana itself enforces.

```bash
kubectl -n "$NS" get agents
kubectl -n "$NS" get modelconfig default-model-config -o yaml
# Should report Accepted; a failure here is usually the LiteLLM key or baseUrl.
kubectl -n "$NS" get remotemcpservers
```

Note that `promql-agent` only writes and explains PromQL — it holds no
Prometheus connection of its own. Ask `observability-agent` when you want a
query actually executed.

**HolmesGPT.** An investigation API at `http://holmes.test`, on the same
`deepseek-v4-pro` model through LiteLLM. Where kagent is a chat UI you drive, this
is one HTTP call that reads the cluster and its telemetry and answers with what
it found and how it got there. Its toolsets cover the Kubernetes API (over a
read-only ClusterRole with no access to Secrets), Prometheus directly, and Loki
and Tempo through Grafana's datasource proxy — so an answer can cite a metric, a
log line, and a trace in the same breath, with links back into Grafana.

There is no UI and no SSO. Every request carries the API key instead:

```bash
export HOLMES_API_KEY="$(kubectl -n "$NS" get secret holmes-api \
  -o jsonpath='{.data.HOLMES_API_KEY}' | base64 -d)"

curl -sS http://holmes.test/api/chat \
  -H "X-API-Key: $HOLMES_API_KEY" \
  -H 'Content-Type: application/json' \
  -d '{"ask": "are any pods in mini-platform unhealthy, and why?"}' | jq -r .analysis
```

`GET /api/model` lists the models it will accept, and `GET /api/info` reports
which toolsets loaded — the quickest way to see that the Grafana credentials and
the Prometheus URL actually resolved:

```bash
curl -sS http://holmes.test/api/info -H "X-API-Key: $HOLMES_API_KEY" | jq
```

Investigations are slow (tens of seconds to minutes) and cost tokens on every
turn. Holmes sends one native investigation trace directly to Langfuse over
OTLP/HTTP, including its LLM turns, reasoning, tool calls and results, initiating
user/session, and final answer. Its model requests still route through LiteLLM,
but carry `no-log: true` so the gateway does not create duplicate Langfuse
traces.

**Observability.** All three signals are read through Grafana, which ships
provisioned `prometheus`, `loki` and `tempo` data sources with fixed uids so
the cross-links between them resolve. To check coverage without leaving the
cluster:

```bash
kubectl -n "$NS" exec deploy/grafana -- wget -qO- 'http://prometheus-server/api/v1/query?query=count(up==0)%20or%20vector(0)'
```

That should report `0` — every scrape target healthy. The `or vector(0)` is
what makes it say so: on a healthy cluster `up==0` matches nothing, and
counting an empty vector yields an empty result rather than a zero.

Logs cover every pod in every namespace, since Alloy discovers them rather
than being told about them:

```bash
kubectl -n "$NS" exec deploy/grafana -- wget -qO- 'http://loki:3100/loki/api/v1/label/namespace/values'
```

Traces come from the components that ship an OTel SDK — Keycloak, Trino, vLLM,
LiteLLM, Open WebUI and Argo CD. They export to Alloy rather than to Tempo
directly, so one endpoint covers every producer and Alloy decides where each
signal lands:

```bash
kubectl -n "$NS" exec deploy/grafana -- wget -qO- 'http://tempo:3200/api/search/tag/service.name/values'
```

A service appears here only once it has served traffic; an idle component
reports nothing, which is not a fault. Two things are worth knowing when
reading traces: Argo CD names its services `argocd-controller` and
`argocd-repo-server`, so the trace-to-logs jump does not line up with Loki's
single `argocd` app label, and vLLM spans emitted before its
`OTEL_SERVICE_NAME` was set stay under `unknown_service` until they age out of
the 168h retention window.

Some components report less than the rest, for lack of an endpoint rather than
lack of wiring: Superset speaks statsd only, Open WebUI has no Prometheus
endpoint and reports through OTLP alone, and Langfuse's bundled OpenTelemetry
is wired to Sentry rather than to a generic OTLP exporter.

**Single sign-on.** The realm import is the part most likely to fail, and it
fails quietly — components come up healthy and only reject logins. Check the
import job first, then confirm the realm is discoverable under the same hostname
a pod would use:

```bash
kubectl -n "$NS" logs job/keycloak-keycloak-config-cli --tail=20
```

```bash
kubectl -n "$NS" run oidc-check --rm -it --restart=Never --image=curlimages/curl -- \
  curl -sS http://keycloak.test/realms/mini-platform/.well-known/openid-configuration
```

The second command exercises the CoreDNS rewrite as well as Keycloak: a DNS
failure means the rewrite did not apply, and an `issuer` that is anything other
than `http://keycloak.test/realms/mini-platform` means `KC_HOSTNAME` is not
taking effect — either one breaks every login. To confirm forward-auth is in
place, an unauthenticated request to a protected host should redirect to
Keycloak rather than return the app. Sending it from inside the cluster keeps
the check independent of whether the ingress is reachable from your machine:

```bash
kubectl -n "$NS" run authcheck --rm -it --restart=Never --image=curlimages/curl -- \
  curl -sS -o /dev/null -w '%{http_code} %{redirect_url}\n' \
  -H 'Host: mlflow.test' http://ingress-nginx-controller.ingress-nginx.svc.cluster.local/
```

Expect `302 http://mlflow.test/oauth2/start?rd=%2F`. Swapping the host header
for `litellm.test` with path `/v1/models` should instead return `401` and no
redirect — LiteLLM authenticates API traffic itself, and only `/ui` sits behind
oauth2-proxy.

**General health:**

```bash
./scripts/check-local-deployment.sh
```

Add `--smoke-open-webui` to verify Open WebUI responds through a temporary
port-forward. For a manual snapshot, inspect the same resources directly:

```bash
kubectl -n argocd get applications
kubectl -n "$NS" get vaultstaticsecrets
kubectl -n "$NS" get pods
kubectl -n "$NS" get svc
```

## Validating Changes

Before committing a change to the GitOps wiring, run the same checks CI runs
(`.github/workflows/validate.yaml`):

```bash
./scripts/validate-gitops.sh
```

It confirms every `valuesFile` referenced by the app-of-apps exists locally and
every `chartPath` resolves (charts/* against the sibling charts checkout at
`CHARTS_DIR`, first-party `minikube/gitops/*` locally), lints and renders the
three `minikube/gitops/` charts, runs `kubeconform` over the rendered manifests,
and `shellcheck`s the scripts. `kubeconform` and `shellcheck` are used if
installed and skipped otherwise; CI installs both.

## Production Hardening

This repository is a local reference stack. Before any non-development use, at
minimum: enable in-cluster TLS, replace Vault manual unseal with an auto-unseal
mechanism and HA storage, scope administrative tokens tightly, and add backups.

Single sign-on is wired for every browser-facing service, but it is configured
for a plain-HTTP local cluster and needs revisiting alongside TLS:

- The realm sets `sslRequired: none` and oauth2-proxy runs with
  `--cookie-secure=false`, so session cookies travel in the clear. Both change
  once the `.test` hostnames are served over HTTPS.
- Break-glass local accounts are left enabled on purpose. Disable them once
  Keycloak itself is highly available.
- Trino, Prometheus, Loki, Tempo, vLLM and the databases have no authentication
  at all; they are only cluster-internal. Exposing any of them means putting
  something in front of it — oauth2-proxy already provides the pattern.
