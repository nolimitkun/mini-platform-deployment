# What a project may use, shared by authorization (authz.rego) and model
# selection (select.rego), so "auto" can only ever pick a model the project
# would also be allowed to name itself.
package gateway.lib

import rego.v1

# The project's placements, capped by its data class even if the generated
# data says otherwise.
placements(project_id) := {p |
	project := data.projects[project_id]
	some p in project.placement
	p in data.gateway.classes[project.data_class]
}

# Catalog models in one of the project's placements that its models.allow
# patterns match, plus its named exceptions (projects/_exceptions.yaml).
allowed(project_id) := by_rule(project_id) | by_exception(project_id)

by_rule(project_id) := {m |
	some m, model in data.catalog.models
	model.placement in placements(project_id)
	some pattern in data.projects[project_id].models_allow

	# null: no delimiters, so * also matches the dots in "qwen3.6-27b"
	# ([] would default to "."). The same matching as fnmatch in gen-projects.py.
	glob.match(pattern, null, m)
}

by_exception(project_id) := {m |
	data.projects[project_id]
	some m in object.get(data.exceptions, project_id, {"models": []}).models
}
