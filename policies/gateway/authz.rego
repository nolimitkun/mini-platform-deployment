# Gateway authorization for agentgateway, evaluated by OPA through Envoy's
# ext_authz protocol. OCP builds this directory into a bundle and publishes it
# to MinIO, where the OPA next to the gateway picks it up (opa-policy chart).
#
# Every API key belongs to a project (projects/*.yaml, generated into
# data.projects by scripts/gen-projects.py). A project has a data class, which
# caps the placements it may use (mini-cloud docs/gcp/ai-inference.md); each
# model or Google API has one placement (data.catalog, from catalog/models.yaml).
# Anything not explicitly allowed is denied.
package gateway.authz

import rego.v1

import data.gateway.lib

default allow := false

# What agentgateway attaches after checking the API key (agentgateway-config
# policies.yaml, requestMetadata). OPA-Envoy hands the protobuf over as
# protojson, hence the camelCase.
key_metadata := input.attributes.metadataContext.filterMetadata.agentgateway

project_id := key_metadata.project

key_id := key_metadata.key_id

project := data.projects[project_id]

# The key is one the project lists. Dropping a key id from the project file
# revokes it as soon as OPA loads the new bundle.
authenticated if key_id in project.keys

# The registered agent the key belongs to (agents/*.yaml), if any. Its calls
# get the agent's scope: fewer models and tools than the project, never more.
agent_id := project.agent_keys[key_id]

agent := data.agents[agent_id]

# The models this key may use (lib.scoped).
scope_models := lib.scoped(project_id, key_id)

# Without the query string, so "/v1/models?x" is still "/v1/models".
path := split(input.attributes.request.http.path, "?")[0]

# Model calls: the requested model must be one the project may use.
allow if {
	authenticated
	model_path
	allowed_model(input.parsed_body.model)
}

# Listing models reveals nothing a project can't already ask for.
allow if {
	authenticated
	path == "/v1/models"
}

# Google's native APIs (speech, TTS, Vertex) under /google/<api>/.
allow if {
	authenticated
	parts := split(path, "/")
	parts[1] == "google"
	count(parts) > 3
	data.catalog.google_apis[parts[2]].placement in lib.placements(project_id)
}

# MCP (the merged endpoint at /mcp). A project with mcp_tools may open
# sessions, list tools and so on; each tools/call must name a tool matching one
# of its patterns. Tool names carry the target as a prefix, e.g.
# grafana_query_prometheus.
allow if {
	authenticated
	mcp_path
	count(project.mcp_tools) > 0
	agent_may_use_mcp
	not tool_call
}

allow if {
	authenticated
	tool_call
	some pattern in project.mcp_tools
	glob.match(pattern, [], input.parsed_body.params.name)
	agent_allows_tool(input.parsed_body.params.name)
}

# An agent's key needs MCP tools of its own; the project's other keys don't.
agent_may_use_mcp if not agent_id

agent_may_use_mcp if count(agent.mcp_tools) > 0

agent_allows_tool(_) if not agent_id

agent_allows_tool(name) if {
	some pattern in agent.mcp_tools
	glob.match(pattern, [], name)
}

mcp_path if {
	parts := split(path, "/")
	parts[1] == "mcp"
}

tool_call if {
	mcp_path
	input.parsed_body.method == "tools/call"
}

model_path if path in {"/v1/chat/completions", "/v1/completions", "/v1/responses", "/v1/messages", "/v1/embeddings"}

allowed_model(m) if m in scope_models

# The gateway's virtual models (agentgateway-config templates/auto.yaml). The
# gateway asks select.rego which model they stand for after this check, and
# it only ever names one of lib.allowed(project), so allowing the name is
# enough when the project has any model at all.
virtual_models := {"auto"} | {sprintf("auto-%s", [t]) | some t, _ in data.catalog.tasks}

allowed_model(m) if {
	m in virtual_models
	count(scope_models) > 0
}

# Why a request was refused, for the decision log and the 403 body.
reason := "unknown project" if {
	not project
} else := sprintf("key %v is not active for project %v", [key_id, project_id]) if {
	not authenticated
} else := sprintf("model %v is not allowed for agent %v (project %v)", [input.parsed_body.model, agent_id, project_id]) if {
	model_path
	agent_id
} else := sprintf("model %v is not allowed for project %v (%v data)", [input.parsed_body.model, project_id, project.data_class]) if {
	model_path
} else := sprintf("tool %v is not allowed for agent %v (project %v)", [input.parsed_body.params.name, agent_id, project_id]) if {
	tool_call
	agent_id
} else := sprintf("tool %v is not allowed for project %v", [input.parsed_body.params.name, project_id]) if {
	tool_call
} else := sprintf("agent %v may use no MCP tools (project %v)", [agent_id, project_id]) if {
	mcp_path
	agent_id
} else := sprintf("project %v may use no MCP tools", [project_id]) if {
	mcp_path
} else := "denied"

# The models a project sees in /v1/models: the ones it may name, plus the
# virtual models when it has any. agentgateway answers /v1/models itself with
# every public model; a response transformation (agentgateway-config
# policies.yaml) keeps only the ids OPA lists in this header. Cosmetic only:
# authorization above decides what a project can call.
listed_models_header := "x-allowed-models"

listed_models := scope_models | virtual_models if {
	count(scope_models) > 0
} else := set()

# What OPA-Envoy returns to agentgateway: allow, or a 403 with the reason.
# Headers on an allowed decision are set on the request, replacing any the
# client sent.
decision := {"allowed": true, "headers": {listed_models_header: concat(",", sort(listed_models))}} if {
	allow
	path == "/v1/models"
} else := {"allowed": true} if allow

decision := {
	"allowed": false,
	"http_status": 403,
	"body": json.marshal({"error": {"message": reason, "type": "policy_denied"}}),
	"headers": {"content-type": "application/json"},
} if not allow
