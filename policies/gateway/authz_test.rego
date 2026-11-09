package gateway.authz_test

import rego.v1

import data.gateway.authz

req(client, path, body) := {
	"attributes": {
		"request": {"http": {"path": path, "method": "POST"}},
		"metadataContext": {"filterMetadata": {"agentgateway": {"client": client}}},
	},
	"parsed_body": body,
}

chat(client, model) := req(client, "/v1/chat/completions", {"model": model})

test_internal_client_gets_onprem_and_gemini if {
	authz.allow with input as chat("open-webui", "qwen3.6-27b")
	authz.allow with input as chat("open-webui", "gemini-4-argon")
}

test_internal_client_denied_external_model if {
	not authz.allow with input as chat("open-webui", "deepseek-v4-pro")
}

test_exception_allows_named_model_only if {
	authz.allow with input as chat("kagent", "deepseek-v4-pro")
	not authz.allow with input as chat("kagent", "some-other-model")
}

test_restricted_client_is_onprem_only if {
	authz.allow with input as chat("vault-app", "qwen3.6-27b")
		with data.gateway.clients["vault-app"] as "restricted"
	not authz.allow with input as chat("vault-app", "gemini-3.5-flash")
		with data.gateway.clients["vault-app"] as "restricted"
	not authz.allow with input as req("vault-app", "/google/speech/v2/projects/p/locations/eu/recognizers/_:recognize", {})
		with data.gateway.clients["vault-app"] as "restricted"
}

test_unknown_client_and_model_denied if {
	not authz.allow with input as chat("stranger", "qwen3.6-27b")
	not authz.allow with input as chat("open-webui", "not-a-model")
	not authz.allow with input as chat("", "qwen3.6-27b")
}

test_google_api_for_gcp_classes if {
	authz.allow with input as req("open-webui", "/google/tts/v1/text:synthesize", {})
	not authz.allow with input as req("open-webui", "/google/unknown/x", {})
	not authz.allow with input as req("open-webui", "/google/tts", {})
}

test_models_listing if {
	authz.allow with input as req("holmes", "/v1/models", {})
	authz.allow with input as req("holmes", "/v1/models?limit=5", {})
}

test_other_paths_denied if {
	not authz.allow with input as req("admin", "/admin", {})
}

test_reason if {
	authz.reason == "model deepseek-v4-pro is not allowed for internal data" with input as chat("open-webui", "deepseek-v4-pro")
	authz.reason == "unknown client" with input as chat("stranger", "x")
	authz.reason == "unknown client" with input as {"attributes": {"request": {"http": {"path": "/v1/models"}}}}
}

test_decision_shape if {
	authz.decision == {"allowed": true} with input as chat("open-webui", "qwen3.6-27b")
	d := authz.decision with input as chat("open-webui", "deepseek-v4-pro")
	d.allowed == false
	d.http_status == 403
}

mcp(client, body) := req(client, "/mcp", body)

test_mcp_session_and_listing if {
	authz.allow with input as mcp("kagent", {"method": "initialize"})
	authz.allow with input as mcp("kagent", {"method": "tools/list"})
	authz.allow with input as req("kagent", "/mcp", null)
}

test_mcp_tool_calls_by_pattern if {
	authz.allow with input as mcp("kagent", {"method": "tools/call", "params": {"name": "grafana_query_prometheus"}})
	authz.allow with input as mcp("holmes", {"method": "tools/call", "params": {"name": "grafana_query_loki_logs"}})
	not authz.allow with input as mcp("holmes", {"method": "tools/call", "params": {"name": "kagent-tools_k8s_delete_resource"}})
	authz.reason == "tool kagent-tools_k8s_delete_resource is not allowed for holmes" with input as mcp("holmes", {"method": "tools/call", "params": {"name": "kagent-tools_k8s_delete_resource"}})
}

test_mcp_needs_an_entry if {
	not authz.allow with input as mcp("open-webui", {"method": "initialize"})
}
