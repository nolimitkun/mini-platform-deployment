# Who has to approve a change in the project registry (nolimitkun/project-registry,
# docs/project-registry.md "Approval rules are policy"). The registry asks for
# data.portal.required_approvals with the change as input:
#
#   input.change   {kind: project | agent | exception | policy, object_id,
#                   op: create | update | delete, before, after}
#                   before / after: the record as in projects/*.yaml, agents/*.yaml,
#                   or one entry of _exceptions.yaml; for a policy change (a commit
#                   of policies/gateway), {commit} and {commit, subject, author, ref}
#   input.requester  who submitted it
#
# The answer is a set of roles; one approval per role, none by the requester:
#   project_owner  the project's owner group     security    security-reviewers
#   cost_owner     cost-owners                    platform    platform-admins
# An empty answer would let a change through unapproved, so every change needs at
# least its project's owner (a policy change: the platform team), and the
# registry refuses an answer without roles. The answer for a policy change comes
# from the policy active now, not the one proposed.
package portal

import rego.v1

change := input.change

before := object.get(change, "before", {}) if change.before != null

else := {}

after := object.get(change, "after", {}) if change.after != null

else := {}

# --- every change to a project's records ---
required_approvals contains "project_owner" if change.kind in {"agent", "exception"}

required_approvals contains "project_owner" if {
	change.kind == "project"
	change.op != "create"
}

# --- a new project: the platform team and security ---
required_approvals contains "platform" if {
	change.kind == "project"
	change.op == "create"
}

required_approvals contains "security" if {
	change.kind == "project"
	change.op == "create"
}

# --- projects: cost ---
required_approvals contains "cost_owner" if {
	change.kind == "project"
	change.op == "update"
	some field in ["requests_per_minute", "tokens_per_minute"]
	raised(object.get(before, ["limits", field], null), object.get(after, ["limits", field], null))
}

required_approvals contains "cost_owner" if {
	change.kind == "project"
	change.op == "update"
	raised(object.get(before, ["budget", "usd_per_30_days"], null), object.get(after, ["budget", "usd_per_30_days"], null))
}

# A limit is raised when it goes up or goes away (absent: no limit).
raised(old, new) if {
	old != null
	new == null
}

raised(old, new) if {
	old != null
	new != null
	new > old
}

# --- projects: security ---
# Any change of data class: more sensitive data, or a wider placement.
required_approvals contains "security" if {
	change.kind == "project"
	change.op == "update"
	before.data_class != after.data_class
}

required_approvals contains "security" if {
	change.kind == "project"
	change.op == "update"
	some p in object.get(after, "placement", [])
	not p in object.get(before, "placement", [])
}

required_approvals contains "security" if {
	change.kind in {"project", "agent"}
	change.op != "delete"
	some t in object.get(after, "mcp_tools", [])
	contains(t, "*")
	not t in object.get(before, "mcp_tools", [])
}

# --- the policy itself (this file included): it decides for every project ---
required_approvals contains "platform" if change.kind == "policy"

required_approvals contains "security" if change.kind == "policy"

# --- exceptions: models beyond the data class, always reviewed by security ---
required_approvals contains "security" if {
	change.kind == "exception"
	change.op != "delete"
}

# --- agents: more autonomy ---
autonomy_rank := {"read-only": 0, "supervised": 1, "autonomous": 2}

required_approvals contains "security" if {
	change.kind == "agent"
	change.op == "create"
	after.autonomy != "read-only"
}

required_approvals contains "security" if {
	change.kind == "agent"
	change.op == "update"
	autonomy_rank[after.autonomy] > autonomy_rank[object.get(before, "autonomy", "read-only")]
}

# --- who may propose a change (approval, above, is a separate question) ---
# The registry asks data.portal.may_submit with input.change, input.requester,
# input.groups (the requester's Keycloak groups) and input.owner_group (the
# project's owner group; for a new project, the one it asks for). Anything but
# true refuses the change (403).
default may_submit := false

# Anyone signed in may ask for a new project: the platform team and security
# approve it.
may_submit if {
	change.kind == "project"
	change.op == "create"
}

# Otherwise the project's owners, for the project and its agents and exceptions,
may_submit if {
	input.owner_group
	input.owner_group in input.groups
}

# and the platform team, for any project. Proposing is not approving: their
# change still needs the approvals above, from someone else.
may_submit if "platform-admins" in input.groups
