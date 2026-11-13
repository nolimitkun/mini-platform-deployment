# Design: project registry (phase 2)

Status: **proof of concept built and deployed on minikube** (2026-11-13): the
core below, in [nolimitkun/project-registry](https://github.com/nolimitkun/project-registry)
and the `project-registry` and `opa-policy` apps. OAuth clients for callers and
the portal page are not built yet. [Proof of concept](#proof-of-concept) has
what was built, what differs from this design and what was measured.

Today a project is a file, `projects/<id>.yaml`, changed by pull request.
[multi-project-policy.md](multi-project-policy.md) records that design and
how it was built. It works for about 200 projects. This document is the next
step, for 1,000 projects or more on several sites, edited through a portal.

## Goals

- **One source of truth.** A registry service holds every project: its
  models, exceptions, limits and budget. The portal reads and writes the
  registry.
- **Small, fast changes.** A change touches one project and is live within
  minutes.
- **Controls a bank needs:** approval by the right people, an audit trail,
  replay of past decisions before publishing, and signed bundles.
- **Decisions don't depend on the registry.** If the registry is down, no
  request decision changes.
- **No OPA Control Plane.** CI builds and signs the policy bundle, and the
  publisher builds and signs the data bundle. OCP is retired (see
  [Why OCP goes](#why-ocp-goes)).

**Out of scope:** the Rego policy, the model catalog (`catalog/models.yaml`)
and the project schema stay in Git, reviewed by the platform team.

## Architecture

```mermaid
flowchart LR
  kc[Keycloak<br/>people, one OAuth client per project]
  ui[Portal UI] --> api[Registry API]
  api --> pg[(Postgres<br/>projects, changes,<br/>approvals, audit log)]
  api -->|diff| opap[OPA: required approvals]
  api --> kc
  pg -->|outbox| pub[Publisher<br/>render, replay,<br/>build and sign]
  git[Git: Rego, catalog, schema] -->|merge| ci[CI<br/>opa test, replay,<br/>build and sign]
  vt[Vault Transit<br/>signing key] -.-> pub
  vt -.-> ci
  pub -->|gateway-projects| s3[(Object store<br/>versioned bundles,<br/>copied to each site)]
  ci -->|gateway-policy| s3
  s3 --> opa[OPA, N per site<br/>verifies signatures]
  opa -->|status: bundle revisions| api
  gw[agentgateway] -->|ext_authz| opa
  opa -->|allow + limits in<br/>dynamic metadata| gw
  gw -->|descriptors with<br/>limitOverride| rl[rate-limit service]
```

## Decisions

### Limits travel with the decision

This is the decision the rest depends on.

- **OPA returns the limits.** Each project's limits and budget are fields in
  the `gateway-projects` data bundle. The allow decision returns them as gRPC
  `dynamic_metadata`.
- **The gateway applies them.** agentgateway reads that metadata in CEL as
  `extauthz.*`, and each rate-limit descriptor sets `limitOverride` from it,
  for example `{"unit": "minute", "requestsPerUnit": extauthz.rpm}`.
- **The rate-limit service counts.** It honours an override for any
  descriptor in a known domain, with no entry for the project in its config.
  Its config shrinks to the domain and a default entry with a limit of 0, and
  stops changing with projects.

What this fixes:

- **A limit change is atomic.** It is one field in one project's data, so it
  goes live in the same bundle as the project's access.
- **No more paths out of step.** Today a project change reaches OPA, the
  rate-limit config and the alert rules separately. That gap, and a new
  project being let through without limits until the rate-limit sync, both
  go away.
- **No tiers.** An earlier draft had a fixed set of tiers. The spike showed
  the value itself can travel, so each project gets its own number.

**Every override expression needs a default of 0**, for example
`has(extauthz.rpm) ? extauthz.rpm : 0`. agentgateway skips a descriptor whose
expression fails to evaluate, which means no limit. With the default, a
project OPA allows but has no limits for is refused.

Metadata, not a request header. A client cannot forge `extauthz.*`, and a
header would also have to be stripped before the upstream call.

### Two signed bundles, no OCP

| Bundle | Roots | Built by | When |
|--------|-------|----------|------|
| `gateway-policy` | `gateway`, `catalog`, `system` | CI, on merge to `main` | a few times a week |
| `gateway-projects` | `projects`, `exceptions`, `agents` | the publisher | on every approved change |

- **Signing:** both builders run `opa build --signing-key`. The key lives in
  Vault Transit and is never exported, and each builder can only sign.
- **Verification:** OPA verifies each bundle with the public key in its
  `keys` config and refuses a bundle without a valid signature. A bundle that
  fails verification leaves the last good one active (`persist: true`).
- **Roots:** each bundle declares its roots in `.manifest`, and the roots are
  disjoint, as today (`policies/gateway-projects`).
- **Versions:** each bundle is written under its revision. A `latest` object
  points at the active revision, so a rollback is moving `latest` back.

### Callers authenticate with JWTs

- **One OAuth client per project or agent.** Each project gets a client in Keycloak
  (client credentials), and its tokens carry a `project` claim.
- **The gateway validates tokens** against Keycloak's JWKS. OPA reads the
  project from the claim instead of the API key's metadata.
- **The key path goes away.** Keys are created in Vault, synced by VSO and
  pushed to the gateway over xDS. That chain grows with every project and is
  removed.
- **The registry manages the clients.** It creates, rotates and revokes them
  through Keycloak's admin API. A client secret is shown once, in the portal.
- **Migration:** OPA accepts both the claim and the API key metadata while
  projects move over. API keys get an end date.

### One validation library

`gen-projects.py`'s loading, model resolution, agent checks and schema
validation become a library:

- the registry calls it when a change is submitted;
- the publisher calls it when it renders;
- CI keeps calling it on the YAML during migration.

The model choices a project sees are the intersection of the catalog in Git
and the model registry's versions in lifecycle `prod`, so a model the
onboarding pipeline promotes shows up without a catalog edit.

### Approval rules are policy

The registry sends a change's diff to OPA and asks
`data.portal.required_approvals`. The rules are Rego in Git, reviewed like
the gateway policy.

| The change | Approved by |
|------------|-------------|
| Add or remove models within the data class, lower a limit, edit a description | the project owner |
| Raise a limit or the budget | plus the cost owner |
| Raise `data_class`, add an exception (with an expiry date), wildcard `mcp_tools`, raise an agent's `autonomy` | plus security |
| Create a project | the platform team and security |

Two rules hold for every change:

- **Four eyes:** nobody approves their own change.
- **No bypass:** platform admins can't skip approval either.

### "Active" comes from OPA

- **OPA reports.** Every OPA runs the status plugin and reports the bundle
  revisions it has loaded to the registry's `/opa/status`.
- **Active means everywhere.** A change is `active` once every OPA on every
  site reports a revision at or after the change's.
- **Late changes alert.** A change that isn't active within a set time raises
  an alert.

### The registry is off the request path

- **Requests keep working.** OPA keeps deciding with its cached bundles. While
  the registry is down, nobody can change a project; nothing else stops.
- **Modest availability.** One Postgres primary with a standby and
  point-in-time recovery is enough.
- **Multiple sites.** The registry runs on one primary site. Bundles are
  copied to an object store on each site, and each site's OPA pulls only from
  its own.

## Data model (Postgres)

```
project(id, owner_group, data_class, placement, routing, limits jsonb,
        budget_usd_per_30_days, mcp_tools[],
        status[active|suspended|deleted], revision)
project_model(project_id, model)              -- explicitly granted models
exception(project_id, models[], why, owner, expires_at)
agent(project_id, name, autonomy, models, mcp_tools, ...)  -- as in agents/*.yaml today
oauth_client(project_id, client_id, created_at, rotated_at, revoked_at)
change_request(id, project_id, diff jsonb, state, required_approvals jsonb,
               replay_report jsonb, bundle_revision, created_by, created_at)
approval(change_id, approver, role, decision, comment, at)
audit_log(seq, at, actor, action, object, before jsonb, after jsonb)
outbox(seq, change_id, published_at)
```

- **The audit log is append-only.** It is exported to WORM storage and the
  SIEM.
- **Change states:** `draft → pending_approval → approved → publishing →
  active`. A change can also end in `rejected`, `failed` or `rolled_back`.

## Publishing

The publisher:

1. **Takes approved changes** from the outbox. Changes are batched, at most
   one publish every 30 seconds.
2. **Renders** every project's `data.json` with the shared library. Only the
   changed projects differ, and the output has a stable hash.
3. **Replays** the last N days of decision logs against the new data bundle
   and the active policy bundle (`scripts/policy-replay.py`):
   - decisions change only for the changed projects: continue;
   - decisions change for any other project: stop and mark the change
     `failed`. This is the safety valve.
4. **Builds, signs and uploads** the bundle under its revision, then moves
   `latest`.
5. **Waits for OPA** to report the revision, then marks the change `active`.

CI does the same for the policy bundle on merge: `opa test`, a replay with
the active data bundle, then build, sign and upload. A policy change is
expected to change decisions, so CI attaches the replay diff to the pull
request for review instead of stopping on it.

**Order of operations:**

- **A new project:** create the OAuth client first, then publish the bundle
  that allows it.
- **A removed project:** publish the bundle with status `deleted`, wait until
  it is active, then revoke the client.
- **A rollback:** point `latest` at the previous revision, one action in the
  portal, recorded in the audit log.

## Budgets and reporting

- **Budget alerts:** the registry exports `project_budget_usd{project}` on
  `/metrics`. One alert rule joins it `on(project)` with spend, so the number
  of rules no longer grows with projects.
- **Usage pages** in the portal read Prometheus (spend, requests),
  agentgateway Analytics and Langfuse.
- **The budget window** stays the rate-limit service's fixed 30-day window
  (`budget.usd_per_30_days`), now sent as an override with unit `month`.

## API

Built in the proof of concept. `{collection}` is `projects`, `agents` or
`exceptions`; every edit creates a change request, and the record changes only
once it is published.

```
GET    /{collection}                  GET    /{collection}/{id}
POST   /{collection}/{id}             create  (body: {"spec": {...}}; a project also
                                               needs "owner_group")
PATCH  /{collection}/{id}             update  (body: {"spec": <JSON merge patch>})
DELETE /{collection}/{id}             delete
GET    /changes/{id}                  the diff, approvals needed and given, replay
                                      report, state, bundle revision
POST   /changes/{id}/approve|reject   (body: {"comment": ...})
GET    /publications                  published revisions, newest first
POST   /rollback/{revision}           platform team only
POST   /opa/status                    OPA's status reports (cluster-internal)
GET    /healthz
```

Designed, not built yet: `GET /projects?owner=me`,
`GET /projects/{id}/allowed-models`, `POST /projects/{id}/clients[/rotate|/revoke]`
and `GET /metrics`.

### Using it

The registry has no ingress yet. From a workstation with cluster access:

```bash
kubectl -n mini-platform port-forward svc/project-registry 8080:8080
kubectl -n mini-platform port-forward svc/keycloak 8090:80
```

Log in as a Keycloak user of the realm, through the registry's client:

```bash
TOKEN=$(curl -s -H 'Host: keycloak.test' \
  -d grant_type=password -d client_id=project-registry -d username=platform-user \
  --data-urlencode "password=$PASSWORD" \
  http://127.0.0.1:8090/realms/mini-platform/protocol/openid-connect/token | jq -r .access_token)
```

The `Host` header makes the token's issuer `http://keycloak.test/...`, which the
registry checks. The passwords are in Vault: `platform-admin` and `platform-user`
in `mini-platform/keycloak-sso`, `security-reviewer` and `cost-owner` in
`mini-platform/keycloak-registry-users`.

Lower a project's request limit, then let someone else approve it:

```bash
curl -s -X PATCH -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  -d '{"spec": {"limits": {"requests_per_minute": 30}}}' http://127.0.0.1:8080/projects/admin
curl -s -X POST -H "Authorization: Bearer $OWNER_TOKEN" -H 'Content-Type: application/json' \
  -d '{"comment": "ok"}' http://127.0.0.1:8080/changes/<id>/approve
curl -s -H "Authorization: Bearer $TOKEN" http://127.0.0.1:8080/changes/<id>
```

The change is `active` within about a minute of its last approval. Every
imported project's owner group is `platform-admins`.

## Why OCP goes

Before phase 2, OCP built both bundles from Git and uploaded them to MinIO. In phase 2:

| OCP did | Phase 2 | Why not OCP |
|----------------|---------|-------------|
| Builds bundles from Git | CI builds `gateway-policy`; the publisher builds `gateway-projects` from Postgres | project data no longer comes from Git |
| Uploads to the object store | CI and the publisher upload | one upload needs no service |
| Pulls HTTP data sources on a timer | the publisher pushes on approved changes | a timer leaves no place for checks before publishing |

And phase 2 needs three things OCP 0.10 doesn't do:

1. **Signing.** OCP has no signing option in its config or its code.
2. **Checks before publishing.** Replay and approval have to pass before a
   bundle goes out. OCP publishes whatever it builds.
3. **Activation status.** This comes from OPA status reports, which don't
   involve OCP.

Retiring OCP also removes:

- its single replica and SQLite state;
- the manual override of `ocp.repo` and `ocp.reference` that deploying a
  branch to the cluster needs today. While that override is in place the
  root app's auto-sync has to stay off. With CI builds, a branch build goes
  to its own prefix in the object store instead.

Distributing bundles through an OCI registry later is `opa build` plus
`oras push`, so it doesn't need OCP either.

## Migration from `projects/*.yaml`

1. **Policy bundle to CI.** CI builds, signs and uploads `gateway-policy`,
   and OPA verifies signatures on that bundle. OCP keeps building
   `gateway-projects` only.
2. **Import.** Load `projects/*.yaml` into Postgres.
3. **Shadow run.** The publisher renders next to `gen-projects.py`, and every
   CI run compares the two; the output must match byte for byte. Cut over
   after a week without a difference.
4. **Cut over the data.** OPA pulls `gateway-projects` from the publisher's
   location and verifies its signature. OCP is removed.
   `projects/` becomes read-only, with a daily snapshot exported to Git for
   reading and disaster recovery.
5. **Limits to OPA.** Add the limits to OPA's metadata and `limitOverride` to
   the descriptors while the per-project rate-limit config is still there,
   compare the counts, then cut the config down to the default entry.
6. **JWTs.** New projects get only an OAuth client. Existing API keys get an
   end date.

**In the proof of concept**, steps 1 to 5 were done together, without the
week of shadow running:

- The import compared its render with Git once, byte for byte. It matched, so
  it published.
- The limits moved to OPA one deployment after the registry, so OPA already
  returned them when the gateway started reading them.
- `projects/` is not read-only yet and nothing exports to it. Since the
  import, it is a stale snapshot for anything the registry changes.
- Step 6 is the next round.

## Proof of concept

### What was built

- **The registry** (`registry/api.py`, FastAPI on its own PostgreSQL). Every
  edit is a change request.
  - It is validated by rendering the whole data bundle with it, using
    `scripts/gen-projects.py` from this repo at the commit of the active policy
    bundle. That makes it the one validation library, kept in Git.
  - Its approvals come from `data.portal.required_approvals`
    (`policies/gateway/portal.rego`, in the policy bundle) and are checked
    against the caller's Keycloak groups. Nobody approves their own change.
  - Every step goes to the append-only audit log.
- **The publisher** (`registry/publisher.py`) runs in one database transaction:
  1. take approved changes, batched at most every 30 seconds, and apply them;
  2. render the bundle;
  3. replay recent decisions;
  4. build, sign and upload the bundle, then activate it.

  A failure anywhere leaves the records, and what OPA loads, unchanged, and
  marks the changes `failed` with the reason. A change is `active` once every
  OPA has reported its revision through the status plugin.
- **The policy build** (`registry/policybuild.py`): a CronJob that, when `main`
  moves, runs `opa test`, then builds, signs and activates `gateway-policy`.
  It replaces OPA Control Plane, which is removed.
- **Signing**: one RSA key in Vault Transit, not exportable. The builders'
  Vault role (`bundle-signer`) can only sign. `opa build` computes the file
  hashes with a throwaway key, and the token is then re-signed through Transit
  (`registry/bundles.py`). OPA verifies both bundles.
- **The import** (`registry/importer.py`, a PostSync hook): the first load from
  `projects/*.yaml` and `agents/*.yaml`. It activates only if the registry's
  render equals the commit's `policies/gateway-projects` byte for byte. It
  did: 5 projects, 5 agents, 2 exceptions.
- **Limits from OPA**: the allow decision carries `limits` as dynamic metadata.
  Every descriptor's `limitOverride` reads it, defaulting to 0. The rate-limit
  config is down to the domain and a default entry.

### Where it differs from this design

- **CI is a CronJob in the cluster.** GitHub Actions can't reach this cluster's
  Vault or MinIO. It isn't an Argo CD PostSync hook either: a commit that only
  changes `policies/` renders no different manifests, so Argo CD never syncs
  and the hook never runs.
- **The replay compares the active and the candidate data bundle.** Both are
  evaluated against the logged inputs, under the active policy. Comparing with
  the logged verdicts, as first written, would blame a project change for
  every verdict a policy or catalog change had flipped since the requests were
  logged, and block every publish for the replay window.
- **Records are documents.** The registry stores each project, agent and
  exception as the JSON of its YAML file (`resource.spec`), not in the
  normalized tables of the data model above. Rendering through
  `gen-projects.py` needs exactly that format.
- **Owners are groups.** Each project has an owner group (`project_owner`). The
  import gives every project `platform-admins`. Who may submit a change is not
  restricted yet; who approves it is.
- **Callers still use API keys.** The OAuth clients (and the JWT-versus-API-key
  check below) come with the portal, in the next round.

### Checks (all on the cluster, through the gateway)

| Check | Result |
|-------|--------|
| `admin` 60 → 3 requests a minute, then 3 → 120 | 3/min: `admin` gets 429 at once, `open-webui` keeps 200; 120/min: 200 again. Active everywhere 9 s after the last approval. The rate-limit pod never restarted (0 restarts across 7 publishes) |
| Approvals | Lowering a limit: the owner only. Raising: the owner and the cost owner. Security can't approve a cost change (403), and nobody can approve their own (403) |
| Replay | 1,800–1,860 logged decisions replayed per publish; 0 changed for other projects |
| Bad signature | A `gateway-projects` bundle with `admin` edited to 1/min, uploaded straight to MinIO: OPA refuses it (`data.json: digest mismatch`) and keeps the signed one; `admin` keeps its real limit |
| Registry down | API and publisher at 0 pods: the gateway keeps serving models and chat, and OPA's status reports fail quietly |
| Policy build | A failing `opa test` publishes nothing (tested in the repo); on the cluster the first build replaced OCP's unsigned bundle, which OPA refused for its missing signature |

A change that alters another project's decisions can't be produced through
valid project data with the current Rego: every rule reads only the
requesting project's entries, and agents are checked against their project.
The valve is tested with real `opa eval` in the repo (`tests/test_replay.py`);
on the cluster, every publish so far changed nothing for other projects.

### Not built yet

- one OAuth client per project and the JWT path (decision "Callers authenticate
  with JWTs");
- the portal page;
- `project_budget_usd` on `/metrics` and the one join alert rule;
- the daily export of the registry to `projects/` in Git (until then, Git keeps
  the import's snapshot, and API keys in Vault are still provisioned from it);
- copies of the bundles to other sites;
- the model choices as the intersection of the catalog and the model
  registry's `prod` versions.

A key rotation in Transit needs a new key id in OPA's config: the public key
OPA has is version 1's.

## Spike: limits set by OPA

**Question:** can agentgateway take rate-limit values from the ext_authz
response? Decision 1 depends on it.

**Source checks** (agentgateway v1.7.0, envoyproxy/ratelimit 5ae0682e):

- **Order.** ext_authz runs before remote rate limiting. Gateway-level
  policies merge into the route phase, so they also run after ext_authz.
- **Metadata in CEL.** OPA's gRPC `dynamic_metadata` is readable in CEL as
  `extauthz.*`.
- **Overrides.** Descriptors take `limitOverride`, a CEL expression returning
  `{"unit", "requestsPerUnit"}`, and the installed CRD has the field.
- **The service.** `GetLimit` uses an override for any descriptor in a known
  domain.

**The test:** agentgateway 1.7.0, OPA 1.22.2-envoy, ratelimit and Redis, in
Docker, the same images as the cluster. The cluster was not touched.

| Case | Result |
|------|--------|
| Project a, OPA data rpm 2 | `200 200 429 429` |
| Project b, rpm 5 | five 200s, then 429 |
| Project c, allowed, no limit in the data | 429 from the first call (default 0) |
| Project z, denied by OPA | 403 |
| Client sends `x-rl-rpm: 1000` | no effect, still 429 |
| Change a to 10 and c to 3 through OPA's data API | live at once, no rate-limit restart |
| Rate-limit service stopped, `failClosed` | 500 (the cluster uses `FailOpen` on purpose) |

**Followed up in the proof of concept** (on the cluster, with the registry):

- **Tokens.** A limit of 30 tokens a minute: two 20-token calls went through
  and the third was refused. So the override still applies when the cost is
  counted on the response.
- **Budget.** A budget of 1 micro-USD refused the next call, DeepSeek or the
  free local model, because the project had already spent more than that in
  the 30-day window. Restoring it to $25 let calls through again.
- **Changing a limit mid-window.** The window's count carries over: the cache
  key doesn't include the limit. Lowering a limit below what was already
  counted refuses the next call at once, and raising it lets calls through at
  once.
