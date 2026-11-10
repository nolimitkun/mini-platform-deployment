# Design: per-project model policy at scale

Status: **design, with a spike** (2026-11-10). Nothing in this doc is deployed
yet. Today's gateway ([agentgateway.md](agentgateway.md)) has four clients, one
key each, and a data class per client.

This doc covers the next step: about **200 projects, each with several API
keys**. Each project gets its own model policy:

- on-prem only, cloud only, or both
- a single model
- "give me the cheapest" or "give me the fastest"
- token budgets and MCP tools

## The rule: keys say who, data says what

A key identifies a project and nothing more. Every rule is data about the
project, read by one generic Rego policy. Nobody writes Rego for a project, and
adding a project or a model is a data change.

```mermaid
flowchart LR
  subgraph git[Git: this repo]
    proj[projects/*.yaml<br/>one per project, CODEOWNERS]
    cat[models catalog<br/>one list for gateway + OPA]
    lib[policies/gateway<br/>generic Rego, platform-owned]
  end
  rank[ranking job<br/>Prometheus TTFT, prices] -->|JSON in MinIO| ocp
  proj --> ocp[OCP]
  cat --> ocp
  lib --> ocp
  ocp -->|bundle| minio[(MinIO)] --> opa[OPA, 2+ replicas]
  vault[(Vault: keys<br/>metadata project, key_id)] -->|VSO| agw
  client[client, project key] --> agw[agentgateway]
  agw -->|ext_authz: may this project<br/>call this model or tool?| opa
  agw -->|virtual model 'auto': callout<br/>which model for this project?| opa
  agw -->|global rate limit<br/>by project| rl[rate-limit service + Redis]
  agw --> models[concrete models<br/>vLLM, Vertex, DeepSeek]
```

## Parts

| Part | Holds | Lives in | Owner |
|------|-------|----------|-------|
| **Project files** | One file per project: owner, data class, placement, models, routing, budget, MCP tools | `projects/<id>.yaml` in this repo. Each team owns its file through CODEOWNERS. Git is enough for 200 projects; a self-service portal, if one comes later, writes to Git instead of replacing it | The project's team |
| **Exceptions** | Anything beyond what the project's data class allows, each with an owner and a reason | `projects/_exceptions.yaml` | Platform team |
| **Model catalog** | One entry per model: placement, provider, price per million input and output tokens, capabilities, visibility | One file that generates both the `models` values of `agentgateway-config` and the `models` data for OPA. Today these are two lists that can drift | Platform team |
| **API keys** | Several keys per project, so a key can be rotated with no gap. Metadata is `{"project": ..., "key_id": ...}` only. Policy never goes in the key | Vault, mirrored by VSO into the gateway's key Secret. About 1,000 keys at roughly 150 bytes each is far below the 1 MiB Secret limit. `secretSelector` can also split them across Secrets | Bootstrap script now, a key service later |
| **Generic policy** | `authz`: may the project use this model, Google API or tool? `select`: which model `auto` means | `policies/gateway/*.rego` | Platform team |
| **OPA** | The bundle | At least 2 replicas and a PodDisruptionBudget. The gateway fails closed, so OPA's availability is the gateway's | Platform team |
| **OCP** | Builds one bundle from the sources | `opa-policy` chart | Platform team |
| **Ranking job** | Per-model latency (p50 time to first token from `agentgateway_gen_ai_server_time_to_first_token`) and health | A CronJob writes JSON to MinIO. OCP pulls it as an `http` datasource when it builds the bundle | Platform team |
| **Rate limits and budgets** | Tokens per minute and a monthly spend cap per project | agentgateway's global (remote) rate limiting, with a rate-limit service and Redis, keyed by `project`. This is live state, so it does not go in an OPA bundle | Platform team |

### A project file

```yaml
project: payments
owner: team-payments
data_class: confidential          # caps placement; see "Guardrails"
placement: [onprem]               # onprem | gcp | external
models:
  allow: ["*"]                    # or ["qwen3.6-27b"] for a single model
routing: cheapest                 # cheapest | fastest | fixed:<model>
budget:
  tokens_per_minute: 50000
  usd_per_month: 200
mcp_tools: ["grafana_*"]
```

CI checks each file against a JSON Schema. One malformed file must not break
the bundle for all 200 projects. OPA keeps serving the last good bundle, but CI
is the place to catch it.

## Policy

### Rules are about model attributes, not model names

"On-prem only" means `catalog[m].placement in project.placement`. It does not
mean a list of on-prem models. When a new on-prem model joins the catalog,
every on-prem project can use it without anyone editing 200 files. A project
that wants a fixed set uses `models.allow`.

The set of models a project may use is:

```
allowed(p) = { m in catalog
             | placement(m) ∈ placement(p) ∩ class_placements(data_class(p))
             ∧ m matches models.allow(p) }
             ∪ exceptions(p)
```

### Guardrails

- **The data class caps placement.** A `restricted` project that lists `gcp` in
  `placement` still gets only on-prem models. The class table is the one in
  mini-cloud's `docs/gcp/ai-inference.md`, already in `policies/gateway/data.json`.
- **Exceptions live in a file the platform team owns,** not in the project's
  own file.
- **Default deny.** An unknown project, model or tool is refused with a 403
  that gives the reason, as today.

OCP does not limit which data paths a source may write. It rejects two sources
with overlapping Rego packages, but it does not stop one team's file from
writing another team's data. That is why project files are YAML checked by CI
against the schema and assembled by CI, never Rego written by the teams.

### Choosing the model: virtual model `auto` with an OPA callout

A client that wants the policy to choose sends `"model": "auto"`.
`auto` is an agentgateway **virtual model** in `callout` mode: the gateway posts
the project to OPA's REST API, and OPA answers with a model name.

```yaml
apiVersion: agentgateway.dev/v1alpha1
kind: AgentgatewayModel
metadata:
  name: auto
spec:
  parentRefs: [{group: gateway.networking.k8s.io, kind: Gateway, name: agentgateway-proxy, sectionName: http}]
  match: {model: auto}
  virtualModel:
    callout:
      backendRef: {name: opa, port: 8181}
      headers:
        ":path": '"/v1/data/gateway/select"'
        ":method": '"POST"'
        content-type: '"application/json"'
      body: '{"input": {"project": apiKey.project}}'
      transformation:
        model: 'callout.body.result.model'
      cache:
        key: ['apiKey.project']
        ttl: 1m
      # No fallback, so a failed callout returns 503. A fallback would also
      # serve projects OPA doesn't know. If one is added, make it the most
      # restricted model (on-prem).
```

The selection rule uses the same `allowed(p)` set as authorization, so it can
only pick a model the project may use:

```rego
select := {"model": m} if {
	some m in allowed(project)
	every n in allowed(project) { score(m) <= score(n) }
}

score(m) := price(m) if routing == "cheapest"
score(m) := data.rankings[m].ttft_ms if routing == "fastest"
```

`fixed:<model>` returns that model, if it is allowed.

There is also a choice of which mechanism makes the pick:

- **Fastest at this moment.** `failover` virtual models are the better fit.
  Targets at the same priority are picked by a health and latency score that
  the gateway itself measures. Use them for a group such as "fast on-prem
  models". OPA's choice is better for "fastest by policy", based on
  minutes-old rankings.
- **Simple per-project rules.** `conditional` virtual models pick by CEL, for
  example `apiKey.project == "x"`. They need no OPA, but every rule lives in
  gateway YAML. That doesn't scale to 200 projects.

### Authorization still runs, on `auto`

The gateway's ext_authz call runs before the virtual model is resolved, so OPA
sees `model: "auto"` (spike, below). `authz.rego` therefore allows `auto` for
any project whose `allowed` set is not empty. The concrete model is then
whatever `select` returned.

Both rules come from the same bundle and the same `allowed` set, so the pair
holds by construction. A unit test checks it for every project:
`select(p) in allowed(p)`.

Concrete models that should only be reached through `auto` get
`visibility: Internal`. A direct request for one returns 404.

## OCP

- **One bundle,** `gateway`, for the gateway's OPA. 200 projects is a few
  hundred kilobytes of data. Separate bundles only make sense when separate
  OPA fleets need different policy.
- **Sources** listed as `requirements` of the bundle:
  - the Rego, from Git at `policies/gateway`
  - the project and exception data, generated by CI from `projects/`, from Git
  - the rankings: an `http` datasource reading MinIO, fetched at build time.
    `rebuild_interval` on the bundle sets how stale they can get.
- **Stacks** add mandatory sources, such as org-wide guardrails, to every
  bundle whose labels match. With one bundle that is the same as a
  requirement. Stacks start to matter once there is more than one bundle, for
  example per environment.

## How long changes take

| Change | Path | Delay |
|--------|------|-------|
| Project or policy change | merge → OCP rebuild (30–60 s) → OPA polls (10–30 s), then up to the 1-minute callout cache for `auto` | about 1–3 min |
| Revoke a key quickly | add its `key_id` to `data.revoked_keys`, which authz checks | same as above |
| Remove a key | Vault → VSO refresh → gateway reload | VSO refresh interval |
| Rankings | CronJob → MinIO → next OCP rebuild | job interval + rebuild interval |

## Reporting

- **Metrics.** `frontend.metrics.attributes.add` on the Gateway adds
  `project` (from `apiKey.project`) as a label on every metric, token usage and
  cost included. That's enough for chargeback, a dashboard per project and
  budget alerts. 200 projects × a handful of models is an acceptable number of
  label combinations. `key_id` must not be a metric label; it goes in logs.
- **Decision logs.** OPA's decision logs in Loki carry `project`, `key_id`, the
  requested model and the reason.

## Spike results (2026-11-10, agentgateway v1.7.0, OPA 1.22.2)

The spike ran on the live cluster in a separate Gateway, `spike-gw`, so the
real gateway was untouched. It had:

- three mock OpenAI models with `visibility: Internal`, each with a placement,
  a price and a latency
- the `auto` virtual model above
- its own OPA serving `select` from a ConfigMap
- keys for three projects

Everything was deleted afterwards.

| Check | Result |
|-------|--------|
| `auto`, `cheapest`, on-prem + GCP | **200**, the cheapest on-prem model |
| `auto`, `fastest`, on-prem + GCP | **200**, the GCP model (lowest TTFT) |
| `auto`, `fastest`, on-prem only | **200**, the faster on-prem model; the GCP model was never considered |
| Direct request for an `Internal` model | **404** `model_not_found` |
| No key | **401** |
| Project OPA doesn't know (no `result`) | **503** `virtual_model_callout_failed` |
| OPA down, no fallback | **503** `virtual_model_callout_failed` |
| OPA down, `fallback` set | **200** from the fallback model |
| What ext_authz sees | `model: "auto"`. ext_authz runs before the callout |
| `project` label on metrics | Present on `agentgateway_requests_total` and `agentgateway_gen_ai_client_token_usage_*`. `gen_ai_request_model` is the concrete model, not `auto` |
| Added latency | About 1 ms with the callout result cached, against a mock model |

Two findings decide the design:

1. **OPA can pick the model** through the gateway's own `callout` virtual model.
   Neither of the fallbacks the earlier proposal named is needed: there is no
   header rewrite and no router service.
2. **Per-project cost and usage come from Prometheus,** not only from logs.

## Not covered yet

- **Global rate limiting** needs a rate-limit service. Its config and failure
  mode (open or closed) are a separate piece of work.
- **Spend cap.** `usd_per_month` needs a budget counter that the rate limiter
  or OPA can read. The price data is already in the catalog.
- **`/v1/models`** still lists every public model to every project.
- **Moving the four current clients** (`open-webui`, `kagent`, `holmes`,
  `admin`) to project files is mechanical. Each becomes a project with its
  current class.

## Plan

1. Model catalog as the single source for both the gateway values and the OPA
   data.
2. `projects/` schema, CI check and generator. Move the four current clients
   to projects.
3. Rego `allowed`, `select` and `authz` on `allowed`, with tests that include
   `select(p) in allowed(p)` for every project.
4. `auto` virtual model; `visibility: Internal` where a model should only be
   reached through it.
5. `project` metric label and a Grafana dashboard per project.
6. Ranking CronJob, and the OCP `http` datasource with `rebuild_interval`.
7. Global rate limiting and budgets.
