package gateway.select_test

import rego.v1

import data.gateway.lib
import data.gateway.select

# A project for these tests; fields default like gen-projects.py's output.
proj(overrides) := object.union(
	{
		"data_class": "internal", "placement": ["onprem", "gcp"], "models_allow": ["*"],
		"keys": ["t"], "mcp_tools": [], "owner": "t", "routing": "cheapest",
	},
	overrides,
)

pick(p, task) := m if {
	m := select.result.model with input as {"project": "t", "task": task}
		with data.projects.t as p
}

pick_no_task(p) := m if {
	m := select.result.model with input as {"project": "t"}
		with data.projects.t as p
}

test_cheapest if {
	# On-prem Qwen has no per-token charge.
	pick_no_task(proj({})) == "qwen3.6-27b"

	# GCP only: blended (3 x input + output) / 4 makes Flash Lite cheapest.
	pick_no_task(proj({"placement": ["gcp"]})) == "gemini-3.5-flash-lite"
}

test_cheapest_respects_models_allow if {
	pick_no_task(proj({"models_allow": ["gemini-4-*", "gemini-3.8-*"]})) == "gemini-3.8-flash"
}

test_fastest_uses_rankings if {
	rankings := {"gemini-3.8-flash": {"ttft_ms": 120}, "qwen3.6-27b": {"ttft_ms": 900}}
	select.result.model == "gemini-3.8-flash" with input as {"project": "t"}
		with data.projects.t as proj({"routing": "fastest"})
		with data.rankings as rankings
}

test_fastest_without_rankings_is_cheapest if {
	pick_no_task(proj({"routing": "fastest"})) == "qwen3.6-27b"
}

test_semantic_follows_task_prefs_within_allowed if {
	all := proj({"routing": "semantic", "data_class": "public", "placement": ["onprem", "gcp", "external"]})
	internal := proj({"routing": "semantic"})
	onprem := proj({"routing": "semantic", "placement": ["onprem"]})

	pick(all, "code") == "deepseek-v4-pro"
	pick(internal, "code") == "gemini-3.8-flash"
	pick(onprem, "code") == "qwen3.6-27b"
	pick(all, "reasoning") == "gemini-4-argon"
	pick(internal, "general") == "gemini-3.5-flash-lite"
}

test_semantic_without_task_is_cheapest if {
	pick_no_task(proj({"routing": "semantic", "placement": ["gcp"]})) == "gemini-3.5-flash-lite"
	pick(proj({"routing": "semantic", "placement": ["gcp"]}), "no-such-task") == "gemini-3.5-flash-lite"
}

test_semantic_uses_exceptions if {
	# kagent: internal, with a DeepSeek exception.
	select.result.model == "deepseek-v4-pro" with input as {"project": "kagent", "task": "code"}
		with data.projects.kagent.routing as "semantic"
}

test_fixed if {
	pick_no_task(proj({"routing": "fixed:gemini-4-argon"})) == "gemini-4-argon"

	# Not allowed (gen-projects.py refuses this, but the policy holds anyway).
	pick_no_task(proj({"routing": "fixed:deepseek-v4-pro"})) == "qwen3.6-27b"
}

test_no_result if {
	not select.result with input as {"project": "nobody"}
	not select.result with input as {"project": "t"}
		with data.projects.t as proj({"models_allow": ["gemini-*"], "placement": ["onprem"]})
}

# The selection never leaves what authorization allows: for every project,
# as configured and narrowed in ways that rule out the overall cheapest model,
# under every routing rule and every task class.
test_selection_within_allowed if {
	routings := {"cheapest", "fastest", "semantic", "fixed:gemini-4-argon", "fixed:deepseek-v4-pro", "fixed:qwen3.6-27b"}
	narrowing := [{}, {"placement": ["gcp"]}, {"placement": ["external"]}, {"models_allow": ["gemini-4-*", "deepseek-*"]}]
	tasks := object.union({t: true | some t, _ in data.catalog.tasks}, {"": true})
	every project_id, project in data.projects {
		every overrides in narrowing {
			every routing in routings {
				every task, _ in tasks {
					within_allowed(project_id, object.union(project, object.union(overrides, {"routing": routing})), task)
				}
			}
		}
	}
}

# Either no model at all, or one the project may use.
within_allowed(project_id, variant, task) if {
	projects := object.union(data.projects, {project_id: variant})
	not select.result with input as {"project": project_id, "task": task}
		with data.projects as projects
}

within_allowed(project_id, variant, task) if {
	projects := object.union(data.projects, {project_id: variant})
	m := select.result.model with input as {"project": project_id, "task": task}
		with data.projects as projects
	allowed := lib.allowed(project_id) with data.projects as projects
	m in allowed
}

# The rankings used by "fastest" in the check above: the overall fastest model
# is one most narrowed projects may not use.
test_selection_within_allowed_with_rankings if {
	test_selection_within_allowed with data.rankings as {"deepseek-v4-pro": {"ttft_ms": 50}, "qwen3.6-27b": {"ttft_ms": 60}}
}
