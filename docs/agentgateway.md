# Model and tool gateway: agentgateway, OPA, OCP, agentregistry

Every model call and every shared MCP tool call on the platform goes through one
gateway, [agentgateway](https://agentgateway.dev). Before routing a request, the
gateway asks OPA whether this client may use this model or tool. OPA's policy is
Rego in this repo; the OPA Control Plane (OCP) builds it into a bundle and OPA
loads it. agentregistry is the catalog where people find the tools.

agentgateway replaces LiteLLM, which this platform used before.

```mermaid
flowchart LR
  subgraph clients[Clients, one API key each]
    owui[Open WebUI]
    kagent[kagent]
    holmes[HolmesGPT]
  end
  subgraph gw[agentgateway-proxy]
    keys[API key check]
    authz[ext_authz]
    route[model / route / MCP]
  end
  opa[OPA<br/>opa-envoy]
  ocp[OCP]
  git[(policies/ in Git)]
  minio[(MinIO<br/>opa-bundles)]
  clients --> keys --> authz --> route
  authz <-->|gRPC :9191| opa
  git --> ocp -->|bundle.tar.gz| minio --> opa
  route --> vllm[vLLM<br/>on-prem GPU]
  route -->|VPN + PSC, keyless| gcp[Vertex AI Gemini<br/>Speech, TTS]
  route -->|internet| ds[DeepSeek]
  route --> mcp[Grafana MCP<br/>kagent tools]
  reg[agentregistry] -.->|catalog points at| gw
```

## The pieces

| Piece | Argo CD app | What it does |
|-------|-------------|--------------|
| agentgateway controller | `agentgateway`, `agentgateway-crds` | Creates the GatewayClass `agentgateway`. For each Gateway, it runs a proxy Deployment, Service and ServiceAccount named after the Gateway |
| Gateway config | `agentgateway-config` (`minikube/gitops/agentgateway-config`) | The `agentgateway-proxy` Gateway, one `AgentgatewayModel` per model, passthrough routes to Google's APIs, the merged MCP endpoint, and policies for API keys, OPA and tracing |
| OPA | `opa-policy` (`minikube/gitops/opa-policy`) | `opa-envoy`, answering ext_authz over gRPC on `opa:9191` |
| OCP | `opa-policy` | Builds `policies/<bundle>` from this repo's `main` branch on GitHub into `opa-bundles/<bundle>/bundle.tar.gz` in MinIO |
| Rate-limit service | `rate-limit` (`minikube/gitops/rate-limit`) | Per-project request, token and spend limits, in Redis (see "Rate limits and budgets") |
| vLLM Semantic Router | `semantic-router` | Classifies `auto` prompts into task classes for the gateway, over ext_proc (see "The semantic router") |
| agentregistry | `agentregistry`, `agentregistry-postgresql`, `agentregistry-catalog` | The catalog of MCP servers (and later agents), at `agentregistry.test` behind the Keycloak login. Its entries live in `minikube/gitops/agentregistry-catalog/files/catalog.yaml` |

Endpoints inside the cluster:

- Models: `http://agentgateway-proxy.mini-platform.svc.cluster.local/v1` (OpenAI API:
  `/chat/completions`, `/models`, `/responses`, `/messages`, `/embeddings`).
- Tools (MCP, streamable HTTP): `http://agentgateway-proxy.mini-platform.svc.cluster.local/mcp`.
- Google APIs: `http://agentgateway-proxy.mini-platform.svc.cluster.local/google/<api>/...`.

Outside the cluster, the same endpoints are at `http://agentgateway.test`.

## Models

| Model | Where | Placement |
|-------|-------|-----------|
| `qwen3.6-27b` | vLLM on the local GPU | `onprem` |
| `gemini-4-argon`, `gemini-3.8-flash`, `gemini-3.5-flash`, `gemini-3.5-flash-lite` | Vertex AI `eu`, through `aiplatform.eu.rep.googleapis.com` and the VPN | `gcp` |
| `deepseek-v4-pro` | `api.deepseek.com` over the internet | `external` |

The names are the ones LiteLLM used, so no client had to rename a model.

Every model and Google API is declared once, in the model catalog
[`catalog/models.yaml`](../catalog/models.yaml), with its placement and provider
settings. `scripts/gen-catalog.py` validates the catalog and generates two files
from it:

- `minikube/gitops/agentgateway-config/files/catalog.json`, which the gateway
  chart turns into `AgentgatewayModel` objects and Google API routes.
- `policies/gateway/catalog/data.json`, which OPA reads as `data.catalog` for
  placements.

A model therefore can't be routed without a placement, or allowed without a
route.

To add a model or a Google API:

1. Add it to `catalog/models.yaml`.
2. Run `python3 scripts/gen-catalog.py` and commit the generated files with it.
   CI (`validate-gitops.sh`) fails if they are out of date.

The policy change goes live when OCP rebuilds the bundle from `main`. The
gateway change goes live on the next Argo CD sync.

### Google login without a key

The proxy runs as the ServiceAccount `agentgateway-proxy`. Its projected token is
exchanged for a Google token through the `onprem-k8s` workload identity pool,
then impersonates `litellm-stt` (`GOOGLE_APPLICATION_CREDENTIALS`, set by
`AgentgatewayParameters`). Google accepts only the subjects listed in
mini-cloud's `infra/modules/gcp-stt-poc` `k8s_subjects`. Renaming the Gateway
breaks this until that list is updated.

### Speech and other Google APIs

agentgateway doesn't translate OpenAI `/v1/audio` calls into Speech or TTS
calls the way LiteLLM did. Instead, clients call Google's own APIs through the
gateway, which adds the Google token:

| Route | Google API |
|-------|------------|
| `/google/speech/...` | Speech-to-Text v2, Chirp 3, `eu-speech.googleapis.com` |
| `/google/tts/...` | Text-to-Speech, Chirp 3 HD voices, `eu-texttospeech.googleapis.com` |
| `/google/vertex-eu/...` | Vertex AI `eu`, for Gemini TTS through `generateContent` |
| `/google/vertex-europe-west1/...` | Vertex AI `europe-west1`, for the Gemini Live websocket |

For example, a TTS call:

```bash
curl -s http://agentgateway.test/google/tts/v1/text:synthesize \
  -H "Authorization: Bearer $KEY" -H 'content-type: application/json' \
  -d '{"input":{"text":"Bonjour"},"voice":{"languageCode":"fr-FR","name":"fr-FR-Chirp3-HD-Aoede"},"audioConfig":{"audioEncoding":"MP3"}}'
```

## Projects and keys

Every API key belongs to a **project**. Each project is one file,
`projects/<id>.yaml`, checked against [`projects/schema.json`](../projects/schema.json):

```yaml
project: holmes
owner: platform team
data_class: internal            # caps placement (see below)
placement: [onprem]             # optional; may only narrow the class
models:
  allow: ["gemini-3.5-*"]       # optional, default ["*"]; globs over catalog names
routing: cheapest               # optional, for model "auto": cheapest | fastest | semantic | fixed:<model>
limits:                         # optional; shared by all the project's keys
  requests_per_minute: 60
  tokens_per_minute: 200000
budget:                         # optional
  usd_per_30_days: 25
keys: [holmes, holmes-2]        # key ids; the secrets are in Vault
mcp_tools: ["grafana_*"]        # optional; no MCP access without it
```

`scripts/gen-projects.py` validates the files, including rules across files:

- the file name is the project id
- placement stays within the data class
- every `models.allow` pattern matches a catalog model
- key ids are `<project>` or `<project>-<suffix>`, and unique

It then generates `policies/gateway/projects/data.json` (`data.projects`) and
`policies/gateway/exceptions/data.json` (`data.exceptions`). CI fails if they
are out of date.

Today's projects are the four former clients, each with one key whose id is the
project id:

| Project | Data class | Mirror (env name the client reads) |
|---------|------------|------------------------------------|
| `open-webui` | `internal` | `open-webui-agentgateway` |
| `kagent` | `internal`, plus the DeepSeek exception | `kagent-agentgateway` |
| `holmes` | `internal`, plus the DeepSeek exception | `holmes-agentgateway` |
| `admin` | `public` | none: for people |

Keys are created by `scripts/bootstrap-vault-secrets.sh`, which reads the key
ids with `gen-projects.py --keys`, so it needs python3 with PyYAML and
jsonschema:

- `mini-platform/agentgateway-api-keys` is what the gateway reads: one entry per
  key id, `{"key": ..., "metadata": {"project": ..., "key_id": ...}}`.
- `mini-platform/agentgateway-client-keys` holds the raw keys under the same
  ids.

To add a project, write its file and run `python3 scripts/gen-projects.py`.
Then merge, and run the bootstrap with `SEED_MISSING_ONLY=true` to create its
keys.

To rotate a key:

1. Add a second id, such as `holmes-2`, and create it with the bootstrap.
2. Move the client to the new key.
3. Remove the old id from the project file. OPA refuses the old key as soon as
   the new bundle is live (`key holmes is not active for project holmes`). The
   next bootstrap run drops it from Vault.

## Policy

`policies/gateway/authz.rego` decides each request from:

- `data.projects` and `data.exceptions`, generated from `projects/`
- `data.catalog`, generated from `catalog/models.yaml`
- `data.gateway.classes` in `policies/gateway/data.json`, which maps each data
  class to the placements it may use

The rules:

- **Data classes,** as in mini-cloud's `docs/gcp/ai-inference.md`:
  - `restricted` and `confidential`: `onprem` only
  - `internal`: `onprem` and `gcp`
  - `public`: also `external`

  A project may use a model if the model's placement is in the project's
  placement (capped by its class) and the name matches `models.allow`.
- **Exceptions** (`projects/_exceptions.yaml`, owned by the platform team). A
  project can get named models outside its class, each with an owner and a
  reason. Today kagent and Holmes have one for DeepSeek.
- **Keys.** The key's id must be listed in its project's file.
- **Google APIs.** Allowed when the API's placement (`gcp`) is in the project's
  placement.
- **MCP.** A project with `mcp_tools` may open sessions and list tools. Each
  `tools/call` must name a tool that matches one of its patterns, such as
  `grafana_*`. Tool names carry the target's prefix: `grafana_...` or
  `kagent-tools_...`.
- **Everything else** is denied, with a 403 whose body gives the reason:
  ```json
  {"error":{"message":"model deepseek-v4-pro is not allowed for project open-webui (internal data)","type":"policy_denied"}}
  ```

### Rate limits and budgets

A project's `limits` and `budget` are enforced by the `rate-limit` app
(`envoyproxy/ratelimit`, chart `minikube/gitops/rate-limit`). Its counters are
in the shared Redis, so they hold across gateway replicas and restarts.
`gen-projects.py` generates its config, `rate-limit/files/config.yaml`, from
the project files. The gateway's `rateLimit` policy (`templates/ratelimit.yaml`)
asks the service on every request, with three counters per project:

| Field | Counted | When |
|-------|---------|------|
| `limits.requests_per_minute` | requests | before the call |
| `limits.tokens_per_minute` | input + output tokens | when the call completes |
| `budget.usd_per_30_days` | agentgateway's cost of the call (`llm.cost.total`), in micro-USD | when the call completes |

Tokens and cost are only known once a call completes. So the call that crosses
a limit still finishes, and the next one gets 429. The budget uses agentgateway's
prices, the same as the catalog's, so on-prem Qwen costs nothing. Its window is
the rate-limit service's "month": a fixed 30-day period counted from the Unix
epoch, not a calendar month.

A project without `limits` or `budget` has no entry in the service's config and
is never limited. Today only `admin` has limits: 60 requests a minute and $25
per 30 days.

The policy fails open. If the rate-limit service is down, requests go through;
limits and budgets are cost control, and OPA still decides access.

A change to a project's limits goes live on the next Argo CD sync of
`rate-limit`, which restarts the service with the new config. It does not go
through OCP.

### Model selection for `auto`

`policies/gateway/select.rego` answers which model a project gets when it lets
the platform choose. It takes `{"project": ..., "task": ...}`, with `task`
optional, at `/v1/data/gateway/select/result`, and returns `{"model": ...,
"routing": ...}`.

It only ever picks from `lib.allowed(project)`, the same set authorization
uses (`policies/gateway/lib.rego`). An unknown project, or one with no allowed
model, gets no result. The project's `routing` decides the order:

| `routing` | Order |
|-----------|-------|
| `cheapest` (default) | Blended price, `(3 × input + output) / 4`, from the catalog's `price` |
| `fastest` | Median model request duration over the last 6 hours (`rankings.rego`), fastest first. Models with fewer than 3 requests in that window come last, in `cheapest` order |
| `semantic` | The task class's list in the catalog's `tasks` (the vLLM Semantic Router supplies the class), then `cheapest` |
| `fixed:<model>` | That model, then `cheapest` |

`rankings.rego` asks Prometheus directly, through OPA's `http.send`, for
`fastest` projects only. It has a 300 ms timeout and keeps the answer for 2
minutes in OPA's cache. If Prometheus doesn't answer, nothing is ranked and
`fastest` behaves like `cheapest`. Authorization never depends on it.

Failed calls count toward the duration too, so a model Google is throttling
(429 after retries) ranks as slow.

The rankings are not in the policy bundle because OCP fails the whole bundle
build when a data source is unreachable. Rankings there would block every
policy change, key revocations included, during a Prometheus outage. A
separate bundle doesn't work either: OPA's readiness waits for every bundle,
so a missing rankings bundle would make OPA unready and the gateway refuse
everything.

Catalog prices are the rates agentgateway v1.7.0's built-in price table bills
in USD per million tokens, checked against its cost metrics. On-prem Qwen has
no per-token charge, so `cheapest` picks it whenever a project may use it.

Clients reach it through the gateway's virtual models
(`agentgateway-config` `templates/auto.yaml`):

| `model` | Asks OPA with |
|---------|---------------|
| `auto` | the caller's project |
| `auto-code`, `auto-reasoning`, `auto-general` (one per catalog task) | the project and that task class |

Each one is an `AgentgatewayModel` whose `callout` posts to `opa:8181` on every
request and routes the request to the model OPA names. A cache
(`auto.cacheTTL`) is off on purpose. A cache hit skips OPA, and the gateway's
ext_authz only ever sees `auto`. So after a policy change revokes the cached
model, the gateway would keep serving it until the entry expired. Uncached, the
callout adds about a millisecond.

If OPA has no answer for the project, the request fails with 503
`virtual_model_callout_failed`. There is no fallback model on purpose: a
fallback would also serve projects OPA doesn't know.

Authorization allows the `auto` names for any project with at least one allowed
model. The gateway's ext_authz check runs before the virtual model is resolved,
so it sees `auto`, not the model behind it. The selected model is always one of
the project's allowed models (`select_test.rego` checks this for every project
and routing). Token and cost metrics carry the concrete model in
`gen_ai_request_model`.

```bash
curl -s http://agentgateway.test/v1/chat/completions -H "Authorization: Bearer $KEY" \
  -H 'content-type: application/json' \
  -d '{"model":"auto","messages":[{"role":"user","content":"hi"}]}' | jq -r .model
```

### The semantic router

The vLLM Semantic Router (VSR, app `semantic-router`, chart 0.4.0) classifies
the prompt of every chat completion whose model is `auto`. It rewrites the
model to `auto-code`, `auto-reasoning` or `auto-general`, and OPA then picks
the project's model for that class. The steps:

1. agentgateway sends the request to VSR over ext_proc, in the `PreRouting`
   phase (`templates/vsr.yaml`). Nothing else goes to VSR: other paths, or
   other models, never leave the gateway for it.
2. VSR's decisions (`minikube/values/semantic-router-values.yaml`) match
   domain signals: computer science and engineering → `auto-code`; math,
   physics or "step by step" → `auto-reasoning`; anything else →
   `auto-general`. `gen-catalog.py --check` fails if a decision names anything
   but the catalog's task classes.
3. The task class matters only for projects whose routing is `semantic`.
   Today that is `admin`; the others keep `cheapest` and ignore it.

VSR never chooses the concrete model. It has no per-project allowlist, so it
can't tell that an on-prem-only project must not go to Gemini; OPA can.

If VSR is down, the ext_proc filter fails open. The request goes on as `auto`,
and the project gets its default, the cheapest model it may use.

VSR sees prompts but keeps none of them. Its response cache, Responses API store
and tools are off, and response bodies are never sent to it. Its classifier
models (about 3.6 GB) come from Hugging Face on first start and stay on its
PVC. It uses about 3 GiB of memory on CPU and adds about 40 ms per `auto`
request. Its responses carry `x-vsr-selected-decision` and
`x-vsr-selected-confidence` headers, which show the class it chose.

### Changing a policy

1. Edit the Rego, the data or a project file, regenerate with
   `scripts/gen-projects.py`, and run `opa test policies/gateway`. CI runs the
   generators' `--check`, `opa check`, `opa fmt` and `opa test` too
   (`scripts/validate-gitops.sh`).
2. Merge to `main`. OCP checks Git about every 30–60 seconds and publishes a new
   bundle. OPA checks MinIO every 10–30 seconds and loads it. No Argo CD sync is
   involved.
3. Check the bundle with `kubectl -n mini-platform port-forward deploy/opa
   8181` and `curl localhost:8181/v1/data/system/bundles`. The manifest names
   the Git commit it was built from.

OPA logs every decision to stdout, and Loki collects them. Request bodies and
the `authorization` header are masked (`policies/gateway/log_mask.rego`).

The gateway fails closed: if OPA is down, every request is denied.

## MCP and agentregistry

The gateway merges Grafana MCP and kagent's tool server into one MCP endpoint at
`/mcp`. It sets `Host` to the target's Service name and does not forward the
client's API key to the target. For that reason, `kagent-values.yaml` adds the
port-less Service name to Grafana MCP's `--allowed-hosts`.

Holmes' GitHub MCP server stays direct: it reads its GitHub token from the
`Authorization` header, which is the header the gateway's API key uses.

kagent's own agents still use their `RemoteMCPServer` entries directly. The chart
generates those, with no way to add the gateway key.

agentregistry lists `platform-tools`, the gateway's MCP endpoint. agentregistry
v0.4.0 accepts only Bedrock models, so models are not in it; `GET /v1/models` on
the gateway is the model list.

To add an entry, edit `minikube/gitops/agentregistry-catalog/files/catalog.yaml`.
A PostSync Job posts it to `/v0/apply` and fails the sync if any entry is
rejected.

## Telemetry

- **Metrics.** Prometheus finds the proxy, the controller and OPA through their
  `prometheus.io` pod annotations. The proxy's main metrics are
  `agentgateway_gen_ai_client_token_usage`, `agentgateway_gen_ai_client_cost_usd_total`,
  `agentgateway_gen_ai_server_time_to_first_token` and
  `agentgateway_requests_total`. The upstream dashboard is in Grafana as
  **Agentgateway**.
- **Per project.** Every proxy metric carries a `project` label, taken from
  the API key's metadata (`policies.yaml`, `frontend.metrics`). Requests
  without a valid key get `unknown`. Key ids and users are not labels; they
  are in OPA's decision log. The **Agentgateway projects** dashboard
  (`app-resources/dashboards/agentgateway-projects.json`) shows, per project:
  - requests, refusals by policy (403), tokens and cost
  - a table of cost and tokens by project and model
  - the model mix, which shows what `auto` picked
  - model request duration and MCP calls

  Cost uses agentgateway's own price table, the same prices as
  `catalog/models.yaml`. Self-hosted models count as $0.
- **Traces.** OTLP goes to Alloy, then to Tempo, under service name
  `agentgateway-proxy`. Langfuse gets the clients' own traces (kagent, Holmes,
  Open WebUI projects), not a per-call gateway project like LiteLLM's.

## Checks

```bash
KEY=$(vault kv get -field=admin mini-platform/agentgateway-client-keys)
curl -s http://agentgateway.test/v1/models -H "Authorization: Bearer $KEY" | jq -r '.data[].id'
curl -s http://agentgateway.test/v1/chat/completions -H "Authorization: Bearer $KEY" \
  -H 'content-type: application/json' \
  -d '{"model":"gemini-3.5-flash-lite","messages":[{"role":"user","content":"hi"}]}'
```

| Check | Expected |
|-------|----------|
| No key | 401 |
| Open WebUI key, `deepseek-v4-pro` | 403, `not allowed for internal data` |
| Holmes key, `tools/call` of `kagent-tools_*` | 403, `tool ... is not allowed for holmes` |
| `curl opa:8181/v1/data/system/bundles` | Manifest with the latest `main` commit |

## Limits

- **Model list not filtered.** `/v1/models` lists every model to every client.
  OPA only refuses the call.
- **No MCP auth to the targets.** The targets trust the network.
  NetworkPolicy, on a CNI that enforces it, should allow only the proxy to reach
  them.
- **Gemini Live websocket.** Routed as plain passthrough. Not tested yet.

## Scaling to many projects

[multi-project-policy.md](multi-project-policy.md) describes how this grows to
hundreds of projects with several keys each. It covers per-project placement,
model and routing rules, and `model: "auto"`. For `auto`, vLLM Semantic Router
classifies the prompt and OPA picks the best model the project is allowed. Both
were checked in spikes on agentgateway 1.7.
