package gateway.authz_test

import rego.v1

import data.gateway.authz

# A request with the project's main key (key id = project id).
req(project, path, body) := req_key(project, project, path, body)

req_key(project, key_id, path, body) := with_metadata({"project": project, "key_id": key_id}, path, body)

with_metadata(md, path, body) := {
	"attributes": {
		"request": {"http": {"path": path, "method": "POST"}},
		"metadataContext": {"filterMetadata": {"agentgateway": md}},
	},
	"parsed_body": body,
}

chat(project, model) := req(project, "/v1/chat/completions", {"model": model})

test_internal_project_gets_onprem_and_gemini if {
	authz.allow with input as chat("open-webui", "qwen3.6-27b")
	authz.allow with input as chat("open-webui", "gemini-4-argon")
}

test_internal_project_denied_external_model if {
	not authz.allow with input as chat("open-webui", "deepseek-v4-pro")
}

test_exception_allows_named_model_only if {
	authz.allow with input as chat("kagent", "deepseek-v4-pro")
	not authz.allow with input as chat("kagent", "some-other-model")
}

vault_app := {
	"data_class": "restricted", "placement": ["onprem"], "models_allow": ["*"],
	"keys": ["vault-app"], "mcp_tools": [], "owner": "t",
}

test_restricted_project_is_onprem_only if {
	authz.allow with input as chat("vault-app", "qwen3.6-27b")
		with data.projects["vault-app"] as vault_app
	not authz.allow with input as chat("vault-app", "gemini-3.5-flash")
		with data.projects["vault-app"] as vault_app
	not authz.allow with input as req("vault-app", "/google/speech/v2/projects/p/locations/eu/recognizers/_:recognize", {})
		with data.projects["vault-app"] as vault_app
}

# Even if the generated data listed gcp, the restricted class caps it.
test_data_class_caps_placement if {
	not authz.allow with input as chat("vault-app", "gemini-3.5-flash")
		with data.projects["vault-app"] as object.union(vault_app, {"placement": ["onprem", "gcp"]})
}

test_models_allow_narrows if {
	single := object.union(vault_app, {"data_class": "internal", "placement": ["onprem", "gcp"], "models_allow": ["gemini-3.5-*"]})
	authz.allow with input as chat("vault-app", "gemini-3.5-flash-lite")
		with data.projects["vault-app"] as single
	not authz.allow with input as chat("vault-app", "qwen3.6-27b")
		with data.projects["vault-app"] as single
	not authz.allow with input as chat("vault-app", "gemini-4-argon")
		with data.projects["vault-app"] as single
}

test_key_must_be_listed if {
	authz.allow with input as req_key("open-webui", "open-webui", "/v1/models", {})
	not authz.allow with input as req_key("open-webui", "open-webui-old", "/v1/models", {})
	authz.reason == "key open-webui-old is not active for project open-webui" with input as req_key("open-webui", "open-webui-old", "/v1/models", {})
	authz.allow with input as req_key("open-webui", "open-webui-2", "/v1/models", {})
		with data.projects["open-webui"].keys as ["open-webui", "open-webui-2"]
}

# Keys need both project and key_id: the pre-project {"client": ...} metadata,
# or a project without a key id, is refused.
test_incomplete_key_metadata_denied if {
	not authz.allow with input as with_metadata({"client": "open-webui"}, "/v1/chat/completions", {"model": "qwen3.6-27b"})
	not authz.allow with input as with_metadata({"project": "open-webui"}, "/v1/chat/completions", {"model": "qwen3.6-27b"})
	not authz.allow with input as with_metadata({"key_id": "open-webui"}, "/v1/models", {})
}

test_unknown_project_and_model_denied if {
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
	authz.reason == "model deepseek-v4-pro is not allowed for project open-webui (internal data)" with input as chat("open-webui", "deepseek-v4-pro")
	authz.reason == "unknown project" with input as chat("stranger", "x")
	authz.reason == "unknown project" with input as {"attributes": {"request": {"http": {"path": "/v1/models"}}}}
}

test_decision_shape if {
	authz.decision == {"allowed": true} with input as chat("open-webui", "qwen3.6-27b")
	d := authz.decision with input as chat("open-webui", "deepseek-v4-pro")
	d.allowed == false
	d.http_status == 403
}

mcp(project, body) := req(project, "/mcp", body)

test_mcp_session_and_listing if {
	authz.allow with input as mcp("kagent", {"method": "initialize"})
	authz.allow with input as mcp("kagent", {"method": "tools/list"})
	authz.allow with input as req("kagent", "/mcp", null)
}

test_mcp_tool_calls_by_pattern if {
	authz.allow with input as mcp("kagent", {"method": "tools/call", "params": {"name": "grafana_query_prometheus"}})
	authz.allow with input as mcp("holmes", {"method": "tools/call", "params": {"name": "grafana_query_loki_logs"}})
	not authz.allow with input as mcp("holmes", {"method": "tools/call", "params": {"name": "kagent-tools_k8s_delete_resource"}})
	authz.reason == "tool kagent-tools_k8s_delete_resource is not allowed for project holmes" with input as mcp("holmes", {"method": "tools/call", "params": {"name": "kagent-tools_k8s_delete_resource"}})
}

test_mcp_needs_an_entry if {
	not authz.allow with input as mcp("open-webui", {"method": "initialize"})
}

# Every model and Google API in the catalog has a placement some class allows,
# so nothing is routable but unusable by every project.
test_catalog_entries_usable_by_some_class if {
	every m in data.catalog.models {
		some placements in data.gateway.classes
		m.placement in placements
	}
	every a in data.catalog.google_apis {
		some placements in data.gateway.classes
		a.placement in placements
	}
}

test_placement_read_from_catalog if {
	not authz.allow with input as chat("open-webui", "qwen3.6-27b")
		with data.catalog.models["qwen3.6-27b"].placement as "external"
	authz.allow with input as chat("open-webui", "new-model")
		with data.catalog.models["new-model"] as {"placement": "onprem", "provider": "OpenAI"}
}

# Every project's generated placement is within its data class.
test_projects_within_their_class if {
	every p in data.projects {
		every pl in p.placement {
			pl in data.gateway.classes[p.data_class]
		}
	}
}

test_virtual_models_allowed_with_any_model if {
	authz.allow with input as chat("open-webui", "auto")
	authz.allow with input as chat("open-webui", "auto-code")
	authz.allow with input as chat("open-webui", "auto-reasoning")
	not authz.allow with input as chat("open-webui", "auto-nosuchtask")

	# A project with no model left may not use them either.
	not authz.allow with input as chat("vault-app", "auto")
		with data.projects["vault-app"] as object.union(vault_app, {"models_allow": ["gemini-*"]})
}
