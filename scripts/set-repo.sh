#!/usr/bin/env bash
# Point the GitOps configuration at different Git repositories and/or revisions.
#
# Two sources back this deployment, each with a URL and a revision that must
# stay in sync across several files for Argo CD to reconcile correctly:
#   chartsRepo / chartsRevision  - the vendored Helm charts (charts/) repo.
#   deployRepo / deployRevision  - this deployment repo (minikube/ overlay).
#
# Touched files:
#   - minikube/gitops/root-application.yaml      (source + helm parameters)
#   - minikube/gitops/mini-platform/values.yaml  (app-of-apps defaults)
#   - scripts/deploy-minikube.sh                 (*_REPO_URL / *_REVISION defaults)
#
# Run this after forking so a fork is a one-command change instead of many edits.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

usage() {
  cat <<EOF
Usage: scripts/set-repo.sh [options]

Each value is optional; only the ones you pass are rewritten.

Options:
  --charts-repo-url URL    Git URL of the vendored charts repository.
  --charts-revision REV    Revision (branch/tag/commit) of the charts repo.
  --deploy-repo-url URL    Git URL of this deployment repository.
  --deploy-revision REV    Revision of the deployment repo.
  --help                   Show this help.

Example:
  scripts/set-repo.sh \\
    --charts-repo-url https://github.com/me/mini-platform.git --charts-revision main \\
    --deploy-repo-url https://github.com/me/mini-platform-deployment.git --deploy-revision main
EOF
}

CHARTS_URL=""
CHARTS_REV=""
DEPLOY_URL=""
DEPLOY_REV=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --charts-repo-url) CHARTS_URL="${2:?--charts-repo-url needs a value}"; shift 2 ;;
    --charts-revision) CHARTS_REV="${2:?--charts-revision needs a value}"; shift 2 ;;
    --deploy-repo-url) DEPLOY_URL="${2:?--deploy-repo-url needs a value}"; shift 2 ;;
    --deploy-revision) DEPLOY_REV="${2:?--deploy-revision needs a value}"; shift 2 ;;
    --help|-h) usage; exit 0 ;;
    *) printf 'Unknown argument: %s\n\n' "$1" >&2; usage; exit 1 ;;
  esac
done

if [[ -z "$CHARTS_URL$CHARTS_REV$DEPLOY_URL$DEPLOY_REV" ]]; then
  printf 'ERROR: pass at least one value to set.\n\n' >&2
  usage
  exit 1
fi

# Rewrite the YAML keys and the matching Argo CD helm parameter (- name: /
# value:) pairs, in place, without touching other keys. The root Application's
# bare source.repoURL / source.targetRevision point at the deployment repo.
rewrite_yaml() {
  local file="$1" tmp
  tmp="$(mktemp)"
  awk \
    -v charts_url="$CHARTS_URL" -v charts_rev="$CHARTS_REV" \
    -v deploy_url="$DEPLOY_URL" -v deploy_rev="$DEPLOY_REV" '
    function indent_of(s) { match(s, /^[[:space:]]*/); return substr(s, 1, RLENGTH) }
    function set_key(line, key, val,    ind) {
      if (val == "") return line
      ind = indent_of(line)
      return ind key ": " val
    }
    {
      line = $0
      # Plain app-of-apps keys.
      if (line ~ /^[[:space:]]*chartsRepo:[[:space:]]/)     { print set_key(line, "chartsRepo", charts_url); next }
      if (line ~ /^[[:space:]]*chartsRevision:[[:space:]]/) { print set_key(line, "chartsRevision", charts_rev); next }
      if (line ~ /^[[:space:]]*deployRepo:[[:space:]]/)     { print set_key(line, "deployRepo", deploy_url); next }
      if (line ~ /^[[:space:]]*deployRevision:[[:space:]]/) { print set_key(line, "deployRevision", deploy_rev); next }
      # Root Application bare source points at the deployment repo.
      if (line ~ /^[[:space:]]*repoURL:[[:space:]]/)        { print set_key(line, "repoURL", deploy_url); next }
      if (line ~ /^[[:space:]]*targetRevision:[[:space:]]/) { print set_key(line, "targetRevision", deploy_rev); next }
      # Root Application helm parameters: remember which name we saw, rewrite its value.
      if (line ~ /^[[:space:]]*-[[:space:]]*name:[[:space:]]*chartsRepo[[:space:]]*$/)     { pending="charts_url"; print; next }
      if (line ~ /^[[:space:]]*-[[:space:]]*name:[[:space:]]*chartsRevision[[:space:]]*$/) { pending="charts_rev"; print; next }
      if (line ~ /^[[:space:]]*-[[:space:]]*name:[[:space:]]*deployRepo[[:space:]]*$/)     { pending="deploy_url"; print; next }
      if (line ~ /^[[:space:]]*-[[:space:]]*name:[[:space:]]*deployRevision[[:space:]]*$/) { pending="deploy_rev"; print; next }
      if (pending != "" && line ~ /^[[:space:]]*value:[[:space:]]/) {
        if      (pending == "charts_url") print set_key(line, "value", charts_url)
        else if (pending == "charts_rev") print set_key(line, "value", charts_rev)
        else if (pending == "deploy_url") print set_key(line, "value", deploy_url)
        else if (pending == "deploy_rev") print set_key(line, "value", deploy_rev)
        pending=""; next
      }
      print
    }
  ' "$file" > "$tmp"
  mv "$tmp" "$file"
  printf '  updated %s\n' "${file#"$ROOT"/}"
}

# Rewrite the bash default-assignment lines in the deploy script.
rewrite_deploy_defaults() {
  local file="$ROOT/scripts/deploy-minikube.sh"
  [[ -z "$CHARTS_URL" ]] || sed -i -E "s|^CHARTS_REPO_URL=\"\\\$\{CHARTS_REPO_URL:-[^}]*\}\"|CHARTS_REPO_URL=\"\${CHARTS_REPO_URL:-${CHARTS_URL//|/\\|}}\"|" "$file"
  [[ -z "$CHARTS_REV" ]] || sed -i -E "s|^CHARTS_REVISION=\"\\\$\{CHARTS_REVISION:-[^}]*\}\"|CHARTS_REVISION=\"\${CHARTS_REVISION:-${CHARTS_REV//|/\\|}}\"|" "$file"
  [[ -z "$DEPLOY_URL" ]] || sed -i -E "s|^DEPLOY_REPO_URL=\"\\\$\{DEPLOY_REPO_URL:-[^}]*\}\"|DEPLOY_REPO_URL=\"\${DEPLOY_REPO_URL:-${DEPLOY_URL//|/\\|}}\"|" "$file"
  [[ -z "$DEPLOY_REV" ]] || sed -i -E "s|^DEPLOY_REVISION=\"\\\$\{DEPLOY_REVISION:-[^}]*\}\"|DEPLOY_REVISION=\"\${DEPLOY_REVISION:-${DEPLOY_REV//|/\\|}}\"|" "$file"
  printf '  updated %s\n' "scripts/deploy-minikube.sh"
}

printf 'Updating GitOps sources:\n'
[[ -z "$CHARTS_URL" ]] || printf '  chartsRepo=%s\n' "$CHARTS_URL"
[[ -z "$CHARTS_REV" ]] || printf '  chartsRevision=%s\n' "$CHARTS_REV"
[[ -z "$DEPLOY_URL" ]] || printf '  deployRepo=%s\n' "$DEPLOY_URL"
[[ -z "$DEPLOY_REV" ]] || printf '  deployRevision=%s\n' "$DEPLOY_REV"
rewrite_yaml "$ROOT/minikube/gitops/root-application.yaml"
rewrite_yaml "$ROOT/minikube/gitops/mini-platform/values.yaml"
rewrite_deploy_defaults

cat <<EOF

Done. Review and commit the changes, then push so Argo CD can reconcile them:

  git diff
  git add minikube/gitops scripts/deploy-minikube.sh
  git commit -m "point GitOps at new sources"
  git push
EOF
