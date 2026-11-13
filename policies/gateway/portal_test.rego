package portal_test

import rego.v1

import data.portal

project := {"project": "p", "owner": "team", "data_class": "internal", "keys": ["p"], "limits": {"requests_per_minute": 60}}

roles(kind, op, before, after) := r if {
	r := portal.required_approvals with input as {
		"change": {"kind": kind, "object_id": "p", "op": op, "before": before, "after": after},
		"requester": "alice",
	}
}

test_lowering_a_limit_needs_the_owner_only if {
	roles("project", "update", project, object.union(project, {"limits": {"requests_per_minute": 30}})) == {"project_owner"}
}

test_raising_or_removing_a_limit_needs_the_cost_owner if {
	roles("project", "update", project, object.union(project, {"limits": {"requests_per_minute": 120}})) == {"project_owner", "cost_owner"}
	roles("project", "update", project, object.remove(project, ["limits"])) == {"project_owner", "cost_owner"}
	roles("project", "update", project, object.union(project, {"budget": {"usd_per_30_days": 10}})) == {"project_owner"}
	budgeted := object.union(project, {"budget": {"usd_per_30_days": 10}})
	roles("project", "update", budgeted, object.union(project, {"budget": {"usd_per_30_days": 20}})) == {"project_owner", "cost_owner"}
}

test_data_class_placement_and_wildcard_tools_need_security if {
	roles("project", "update", project, object.union(project, {"data_class": "public"})) == {"project_owner", "security"}
	roles("project", "update", object.union(project, {"placement": ["onprem"]}), object.union(project, {"placement": ["onprem", "gcp"]})) == {"project_owner", "security"}
	roles("project", "update", project, object.union(project, {"mcp_tools": ["grafana_*"]})) == {"project_owner", "security"}
	roles("project", "update", project, object.union(project, {"mcp_tools": ["grafana_list_dashboards"]})) == {"project_owner"}
}

test_a_new_project_needs_platform_and_security if {
	roles("project", "create", null, project) == {"platform", "security"}
}

test_exceptions_need_security_except_their_removal if {
	exc := {"owner": "team", "why": "x", "models": ["m"]}
	roles("exception", "create", null, exc) == {"project_owner", "security"}
	roles("exception", "delete", exc, null) == {"project_owner"}
}

test_more_agent_autonomy_needs_security if {
	agent := {"agent": "a", "project": "p", "autonomy": "read-only"}
	roles("agent", "update", agent, object.union(agent, {"autonomy": "supervised"})) == {"project_owner", "security"}
	roles("agent", "update", object.union(agent, {"autonomy": "supervised"}), agent) == {"project_owner"}
	roles("agent", "create", null, agent) == {"project_owner"}
}

test_every_change_has_an_approver if {
	every kind in ["project", "agent", "exception"] {
		count(roles(kind, "delete", {"project": "p"}, null)) > 0
	}
}

may(kind, op, groups, owner) := r if {
	r := portal.may_submit with input as {
		"change": {"kind": kind, "object_id": "p", "op": op, "before": null, "after": {}},
		"requester": "bob", "groups": groups, "owner_group": owner,
	}
}

test_owners_and_the_platform_team_may_propose_changes if {
	may("project", "update", ["team-p"], "team-p")
	may("agent", "update", ["team-p"], "team-p")
	may("exception", "create", ["team-p"], "team-p")
	may("project", "update", ["platform-admins"], "team-p")
}

test_others_may_not_propose_changes_to_a_project if {
	not may("project", "update", ["team-q"], "team-p")
	not may("project", "delete", ["security-reviewers", "cost-owners"], "team-p")
	not may("project", "update", [], null)
}

test_anyone_may_ask_for_a_new_project if {
	may("project", "create", [], "team-new")
}
