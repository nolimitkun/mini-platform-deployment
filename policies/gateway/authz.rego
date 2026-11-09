# Gateway authorization for agentgateway, evaluated by OPA through Envoy's
# ext_authz protocol. OCP builds this directory into a bundle and publishes it
# to MinIO, where the OPA next to the gateway picks it up (opa-policy chart).
#
# Placement follows the data classes in mini-cloud docs/gcp/ai-inference.md:
# each client has a class, each class may use some placements, each model or
# Google API has one placement. Anything not explicitly allowed is denied.
package gateway.authz

import rego.v1

default allow := false

# The client name agentgateway attaches after checking the API key
# (agentgateway-config policies.yaml, requestMetadata.client).
# OPA-Envoy hands the protobuf over as protojson, hence the camelCase.
client := input.attributes.metadataContext.filterMetadata.agentgateway.client

# Without the query string, so "/v1/models?x" is still "/v1/models".
path := split(input.attributes.request.http.path, "?")[0]

# Model calls: the requested model must be one the client's class may use.
allow if {
	model_path
	allowed_model(client, input.parsed_body.model)
}

# Listing models reveals nothing a client can't already ask for.
allow if {
	client
	path == "/v1/models"
}

# Google's native APIs (speech, TTS, Vertex) under /google/<api>/.
allow if {
	parts := split(path, "/")
	parts[1] == "google"
	count(parts) > 3
	data.gateway.google_apis[parts[2]] == "gcp"
	"gcp" in placements(client)
}

# MCP (the merged endpoint at /mcp). A client with an mcp_tools entry may open
# sessions, list tools and so on; each tools/call must name a tool matching one
# of its patterns. Tool names carry the target as a prefix, e.g.
# grafana_query_prometheus.
allow if {
	mcp_path
	data.gateway.mcp_tools[client]
	not tool_call
}

allow if {
	tool_call
	some pattern in data.gateway.mcp_tools[client]
	glob.match(pattern, [], input.parsed_body.params.name)
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

allowed_model(c, m) if data.gateway.models[m] in placements(c)

# Named, owned exceptions to the class rule.
allowed_model(c, m) if m in object.get(data.gateway.exceptions, c, {}).models

placements(c) := data.gateway.classes[data.gateway.clients[c]]

known_client if data.gateway.clients[client]

# Why a request was refused, for the decision log and the 403 body.
reason := "unknown client" if {
	not known_client
} else := sprintf("model %v is not allowed for %v data", [input.parsed_body.model, data.gateway.clients[client]]) if {
	model_path
} else := sprintf("tool %v is not allowed for %v", [input.parsed_body.params.name, client]) if {
	tool_call
} else := "denied"

# What OPA-Envoy returns to agentgateway: allow, or a 403 with the reason.
decision := {"allowed": true} if allow

decision := {
	"allowed": false,
	"http_status": 403,
	"body": json.marshal({"error": {"message": reason, "type": "policy_denied"}}),
	"headers": {"content-type": "application/json"},
} if not allow
