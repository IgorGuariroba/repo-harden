#!/usr/bin/env bash
# Read-only audit for the repo-harden checklist. Changes nothing.
# Usage: audit.sh [owner/repo]   (run from the repository root)
# Output: one line per item: <id>\t<status>\t<detail>
#   status: ok | missing | drift | n/a | manual | info
set -uo pipefail

repo="${1:-}"
if [ -z "$repo" ]; then
  url=$(git remote get-url origin 2>/dev/null) || { echo "error: no origin remote" >&2; exit 2; }
  repo=$(printf '%s' "$url" | sed -E 's#^(git@github\.com:|https://github\.com/|ssh://git@github\.com/)##; s#\.git$##')
fi

row() { printf '%s\t%s\t%s\n' "$1" "$2" "$3"; }
api() { gh api "$@" 2>/dev/null; }

meta=$(api "repos/$repo") || { echo "error: cannot read repos/$repo (gh auth?)" >&2; exit 2; }
default_branch=$(jq -r .default_branch <<<"$meta")
visibility=$(jq -r .visibility <<<"$meta")
row repo info "$repo default=$default_branch visibility=$visibility"

# ---------- project ----------
has_pkg=0; publishable=0
if [ -f package.json ]; then
  has_pkg=1
  [ "$(jq -r '.private // false' package.json)" != "true" ] && publishable=1
  scripts=$(jq -r '.scripts // {} | keys | map(select(test("^(test|typecheck|lint|build|check)$"))) | join(",")' package.json)
  row node.scripts info "validation: ${scripts:-none}; publishable=$publishable"
  if [ -f package-lock.json ]; then
    vulns=$(npm audit --json 2>/dev/null | jq -r '.metadata.vulnerabilities.total // "?"')
    [ "$vulns" = "0" ] && row npm.audit ok "0 vulnerabilities" || row npm.audit missing "$vulns vulnerabilities (npm audit fix, never --force)"
  else
    row npm.audit missing "no package-lock.json"
  fi
else
  row node.scripts n/a "no package.json (npm/publish items do not apply)"
fi

# ---------- .github files ----------
dep=.github/dependabot.yml; [ -f "$dep" ] || dep=.github/dependabot.yaml
if [ -f "$dep" ]; then
  miss=""
  grep -q 'package-ecosystem: *"\?github-actions' "$dep" || miss="$miss github-actions"
  if [ $has_pkg = 1 ]; then
    grep -q 'package-ecosystem: *"\?npm' "$dep" || miss="$miss npm"
    grep -q 'security-patch-minor' "$dep" || miss="$miss grupo:security-patch-minor"
  fi
  [ -z "$miss" ] && row dependabot.yml ok "$dep" || row dependabot.yml drift "missing:$miss"
else
  row dependabot.yml missing ".github/dependabot.yml"
fi

wf_dir=.github/workflows
ci_files=$(grep -lE '^\s*pull_request:' $wf_dir/*.y*ml 2>/dev/null | xargs -r grep -L 'pull_request_target' || true)
if [ -n "$ci_files" ]; then
  names=$(grep -hE '^\s{4}name:' $ci_files | sed -E 's/^\s*name:\s*//; s/^["'\'']|["'\'']$//g' | paste -sd',' -)
  row ci.workflow ok "$(echo $ci_files) jobs=[${names:-no fixed name}]"
else
  row ci.workflow missing "no workflow triggered by pull_request"
fi

am=$(grep -lE 'dependabot/fetch-metadata' $wf_dir/*.y*ml 2>/dev/null | head -1)
if [ -n "$am" ]; then
  issues=""
  grep -q 'pull_request_target' "$am" || issues="$issues no-pull_request_target"
  grep -qE 'actions/checkout' "$am" && issues="$issues CHECKS-OUT-PR-CODE(dangerous)"
  grep -q 'security-patch-minor' "$am" || issues="$issues no-group-filter"
  grep -q 'match-head-commit' "$am" || issues="$issues no-match-head-commit"
  grep -q "github.repository == '$repo'" "$am" || issues="$issues no-repo-guard"
  [ -z "$issues" ] && row automerge.workflow ok "$am" || row automerge.workflow drift "$am:$issues"
elif [ $has_pkg = 1 ]; then
  row automerge.workflow missing "dependabot-auto-merge.yml"
else
  row automerge.workflow n/a "no npm"
fi

unpinned=$(grep -hE '^\s*-?\s*uses:' $wf_dir/*.y*ml 2>/dev/null | grep -vE '@[0-9a-f]{40}' | grep -vE 'uses:\s*\./' | sed -E 's/^\s*-?\s*uses:\s*//' | sort -u | paste -sd' ' -)
if ls $wf_dir/*.y*ml >/dev/null 2>&1; then
  [ -z "$unpinned" ] && row actions.pinned ok "all pinned by SHA" || row actions.pinned drift "not pinned: $unpinned"
fi

# ---------- publish (npm OIDC) ----------
if [ $publishable = 1 ]; then
  pub=$(grep -lE 'npm publish' $wf_dir/*.y*ml 2>/dev/null | head -1)
  if [ -n "$pub" ]; then
    issues=""
    grep -q 'id-token: write' "$pub" || issues="$issues no-id-token"
    grep -q -- '--provenance' "$pub" || issues="$issues no-provenance"
    grep -qE 'NPM_TOKEN|NODE_AUTH_TOKEN' "$pub" && issues="$issues uses-token"
    grep -q 'merge-base --is-ancestor' "$pub" || issues="$issues no-tag-validation"
    env_name=$(grep -E '^\s+environment:' "$pub" | head -1 | sed -E 's/.*environment:\s*//; s/["'\'']//g')
    [ -z "$env_name" ] && issues="$issues no-environment"
    [ -z "$issues" ] && row publish.workflow ok "$pub env=$env_name" || row publish.workflow drift "$pub:$issues"
  else
    row publish.workflow missing "publish.yml (OIDC)"; env_name=npm
  fi
  rurl=$(jq -r '.repository.url // .repository // ""' package.json)
  case "$rurl" in *"github.com/$repo"*) row package.repository ok "$rurl";; *) row package.repository drift "repository.url='$rurl' (expected git+https://github.com/$repo.git)";; esac

  env_name=${env_name:-npm}
  envj=$(api "repos/$repo/environments/$env_name")
  if [ -z "$envj" ]; then
    row env.exists missing "environment '$env_name'"
    row env.tag-policy missing "tag policy"
  else
    row env.exists ok "$env_name"
    custom=$(jq -r '.deployment_branch_policy.custom_branch_policies // false' <<<"$envj")
    pols=$(api "repos/$repo/environments/$env_name/deployment-branch-policies" | jq -r '[(.branch_policies // [])[] | "\(.type):\(.name)"] | join(",")')
    if [ "$custom" = "true" ] && [ -n "$pols" ] && ! grep -q 'branch:' <<<"$pols"; then
      row env.tag-policy ok "$pols"
    else
      row env.tag-policy missing "custom=$custom policies=[${pols}] (expected only tag:v*)"
    fi
  fi
  pkgname=$(jq -r .name package.json)
  npmver=$(npm view "$pkgname" version 2>/dev/null)
  row npm.trust manual "package ${pkgname} on npm: ${npmver:-NOT published}; verify with: npm trust list $pkgname"
fi

# ---------- repository settings ----------
chk() { # id campo esperado
  v=$(jq -r ".$2" <<<"$meta")
  [ "$v" = "$3" ] && row "$1" ok "$2=$v" || row "$1" drift "$2=$v (expected $3)"
}
chk repo.auto-merge allow_auto_merge true
chk repo.delete-branch delete_branch_on_merge true
chk repo.squash allow_squash_merge true
chk repo.no-merge-commit allow_merge_commit false
chk repo.no-rebase allow_rebase_merge false
chk repo.squash-title squash_merge_commit_title PR_TITLE
chk repo.squash-message squash_merge_commit_message PR_BODY
chk repo.update-branch allow_update_branch true

sa=$(jq '.security_and_analysis // {}' <<<"$meta")
for k in dependabot_security_updates secret_scanning secret_scanning_non_provider_patterns secret_scanning_push_protection; do
  v=$(jq -r ".$k.status // \"unavailable\"" <<<"$sa")
  [ "$v" = "enabled" ] && row "sec.$k" ok enabled || row "sec.$k" missing "$v"
done

# ---------- rulesets ----------
rulesets=$(api "repos/$repo/rulesets?includes_parents=false" | jq -r '.[].id')
branch_rs=""; tag_rs=""
for id in $rulesets; do
  rs=$(api "repos/$repo/rulesets/$id")
  tgt=$(jq -r .target <<<"$rs")
  inc=$(jq -r '.conditions.ref_name.include | join(",")' <<<"$rs")
  if [ "$tgt" = branch ] && grep -qE "~DEFAULT_BRANCH|refs/heads/$default_branch" <<<"$inc"; then branch_rs=$rs; fi
  if [ "$tgt" = tag ] && grep -qE 'refs/tags/v\*' <<<"$inc"; then tag_rs=$rs; fi
done

if [ -n "$branch_rs" ]; then
  id=$(jq -r .id <<<"$branch_rs"); issues=""
  [ "$(jq -r .enforcement <<<"$branch_rs")" = active ] || issues="$issues enforcement!=active"
  for t in deletion non_fast_forward pull_request required_status_checks; do
    jq -e --arg t "$t" '.rules | any(.type==$t)' <<<"$branch_rs" >/dev/null || issues="$issues no-$t"
  done
  jq -e '.rules[] | select(.type=="pull_request") | .parameters.allowed_merge_methods == ["squash"]' <<<"$branch_rs" >/dev/null || issues="$issues merge-methods!=squash"
  jq -e '.rules[] | select(.type=="required_status_checks") | .parameters.strict_required_status_checks_policy == true' <<<"$branch_rs" >/dev/null || issues="$issues strict=false"
  checks=$(jq -r '[.rules[] | select(.type=="required_status_checks") | .parameters.required_status_checks[] | "\(.context)#\(.integration_id // "-")"] | join(",")' <<<"$branch_rs")
  jq -e '.bypass_actors | any(.actor_id==5 and .actor_type=="RepositoryRole" and .bypass_mode=="pull_request")' <<<"$branch_rs" >/dev/null || issues="$issues bypass-admin!=pull_request"
  [ -z "$issues" ] && row ruleset.branch ok "id=$id checks=[$checks]" || row ruleset.branch drift "id=$id checks=[$checks]:$issues"
else
  row ruleset.branch missing "no ruleset on ~DEFAULT_BRANCH"
fi

if [ -n "$tag_rs" ]; then
  id=$(jq -r .id <<<"$tag_rs"); issues=""
  [ "$(jq -r .enforcement <<<"$tag_rs")" = active ] || issues="$issues enforcement!=active"
  for t in deletion non_fast_forward update; do
    jq -e --arg t "$t" '.rules | any(.type==$t)' <<<"$tag_rs" >/dev/null || issues="$issues no-$t"
  done
  jq -e '.bypass_actors | any(.actor_id==5 and .actor_type=="RepositoryRole" and .bypass_mode=="always")' <<<"$tag_rs" >/dev/null || issues="$issues bypass-admin!=always"
  [ -z "$issues" ] && row ruleset.tags ok "id=$id" || row ruleset.tags drift "id=$id:$issues"
else
  row ruleset.tags missing "no tag ruleset covering refs/tags/v*"
fi

if api "repos/$repo/branches/$default_branch/protection" >/dev/null; then
  row classic-protection drift "classic branch protection active on $default_branch (overlaps the ruleset)"
else
  row classic-protection ok "none"
fi

# ---------- local hooks ----------
mgr=""
[ -d .husky ] && mgr="husky"
ls lefthook.y*ml .lefthook.y*ml >/dev/null 2>&1 && mgr="lefthook"
[ -f .pre-commit-config.yaml ] && mgr="pre-commit"
[ -f package.json ] && jq -e '.["simple-git-hooks"]' package.json >/dev/null 2>&1 && mgr="simple-git-hooks"
hp=$(git config --get core.hooksPath || true)
hookdir=${hp:-.git/hooks}
if [ -x "$hookdir/pre-commit" ] && [ -x "$hookdir/pre-push" ] && grep -q 'protectedBranches\|ALLOW_MAIN' "$hookdir/pre-commit" "$hookdir/pre-push" 2>/dev/null; then
  row hooks.local ok "hooksPath=${hp:-default} manager=${mgr:-none}"
else
  row hooks.local missing "hooksPath=${hp:-default} manager=${mgr:-none} (main/master not blocked)"
fi
