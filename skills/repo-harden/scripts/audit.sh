#!/usr/bin/env bash
# Read-only audit for the repo-harden checklist (references/checklist.md). Changes nothing.
# Usage: audit.sh            (run from the repository root)
# Output: one line per item: <id>\t<status>\t<detail>
#   status: ok | missing | drift | n/a | manual | verify | info
#     verify = this script cannot decide; the agent checks it with the platform/ecosystem tooling
set -uo pipefail

row() { printf '%s\t%s\t%s\n' "$1" "$2" "$3"; }
has() { command -v "$1" >/dev/null 2>&1; }

git rev-parse --show-toplevel >/dev/null 2>&1 || { echo "error: not a git repository" >&2; exit 2; }
cd "$(git rev-parse --show-toplevel)" || exit 2

# ---------- platform and scope ----------
url=$(git remote get-url origin 2>/dev/null || true)
host=$(printf '%s' "$url" | sed -E 's#^[a-z+]+://##; s#^[^@]*@##; s#[:/].*$##')
path=$(printf '%s' "$url" | sed -E 's#^[a-z+]+://[^/]+/##; s#^[^@]*@[^:]+:##; s#\.git$##')
case "$host" in
  github.com) platform=github ;;
  *gitlab*)   platform=gitlab ;;
  bitbucket.org) platform=bitbucket ;;
  dev.azure.com|*visualstudio.com) platform=azure ;;
  "") platform=none ;;
  *) platform=unknown ;;
esac

scope=local; default_branch=""; meta=""
if [ "$platform" = github ] && has gh && meta=$(gh api "repos/$path" 2>/dev/null); then
  default_branch=$(jq -r .default_branch <<<"$meta")
  perm=$(jq -r 'if .permissions.admin then "admin" elif .permissions.push then "repo-write" else "local" end' <<<"$meta")
  scope=$perm
  row platform info "github repo=$path default=$default_branch visibility=$(jq -r .visibility <<<"$meta") scope=$scope"
else
  default_branch=$(git symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null | sed 's#^origin/##')
  row platform info "$platform host=${host:-none} repo=${path:-none} default=${default_branch:-?} scope=$scope (server-side items need the platform's CLI/API and admin; otherwise they become maintainer recommendations)"
fi
default_branch=${default_branch:-main}

# ---------- ecosystems ----------
eco=""
add() { case " $eco " in *" $1 "*) ;; *) eco="$eco $1" ;; esac; }
manifests=$(git ls-files 2>/dev/null | grep -vE '(^|/)(node_modules|vendor|third_party|examples?|testdata|fixtures)/' || true)
grep -qE '(^|/)package\.json$' <<<"$manifests" && add node
grep -qE '(^|/)(pyproject\.toml|setup\.py|Pipfile|requirements[^/]*\.txt|uv\.lock)$' <<<"$manifests" && add python
grep -qE '(^|/)go\.mod$' <<<"$manifests" && add go
grep -qE '(^|/)Cargo\.toml$' <<<"$manifests" && add rust
other=""
for m in Gemfile:ruby pom.xml:java build.gradle:java build.gradle.kts:java composer.json:php mix.exs:elixir pubspec.yaml:dart Dockerfile:docker; do
  grep -qE "(^|/)${m%%:*}$" <<<"$manifests" && case " $other " in *" ${m#*:} "*) ;; *) other="$other ${m#*:}" ;; esac
done
eco=${eco# }; other=${other# }
row ecosystems info "profiled=[${eco:-none}] other=[${other:-none}] (profiles: references/ecosystems.md; research unlisted ones)"

# ---------- local: hooks ----------
mgr=""
[ -d .husky ] && mgr="husky"
ls lefthook.y*ml .lefthook.y*ml >/dev/null 2>&1 && mgr="lefthook"
[ -f .pre-commit-config.yaml ] && mgr="pre-commit"
[ -f package.json ] && jq -e '.["simple-git-hooks"]' package.json >/dev/null 2>&1 && mgr="simple-git-hooks"
hp=$(git config --get core.hooksPath || true)
hookdir=${hp:-$(git rev-parse --git-path hooks)}
hookfiles="$hookdir/pre-commit $hookdir/pre-push"
[ -n "$mgr" ] && hookfiles="$hookfiles $(ls .husky/* lefthook.y*ml .pre-commit-config.yaml 2>/dev/null | tr '\n' ' ')"
# shellcheck disable=SC2086
if [ -x "$hookdir/pre-commit" ] && [ -x "$hookdir/pre-push" ] && grep -qE 'protectedBranches|ALLOW_MAIN|refs/heads/(main|master)' $hookfiles 2>/dev/null; then
  row hooks.protect-branch ok "hooksPath=${hp:-default} manager=${mgr:-none}"
else
  row hooks.protect-branch missing "hooksPath=${hp:-default} manager=${mgr:-none}"
fi
scanners=$(for s in gitleaks trufflehog detect-secrets ggshield; do has "$s" && printf '%s ' "$s"; done)
# shellcheck disable=SC2086
if grep -qE 'gitleaks|trufflehog|detect-secrets|ggshield' $hookfiles 2>/dev/null; then
  row hooks.secrets ok "scanner wired into hooks"
else
  row hooks.secrets missing "installed scanners: [${scanners% }] (default: install the ecosystem's scanner unless declined)"
fi

# ---------- local: dependency vulnerabilities ----------
for e in $eco; do
  case $e in
    node)
      if [ -f package-lock.json ] && has npm; then
        v=$(npm audit --json 2>/dev/null | jq -r '.metadata.vulnerabilities.total // "?"')
        [ "$v" = 0 ] && row deps.vulns:node ok "npm audit: 0" || row deps.vulns:node missing "npm audit: $v vulnerabilities"
      else row deps.vulns:node verify "no package-lock.json or npm (other lockfile? use its audit)"; fi ;;
    go)
      if has govulncheck; then
        govulncheck ./... >/dev/null 2>&1 && row deps.vulns:go ok "govulncheck clean" || row deps.vulns:go missing "govulncheck reported findings (or failed)"
      else row deps.vulns:go verify "govulncheck not installed (go install golang.org/x/vuln/cmd/govulncheck@latest)"; fi ;;
    rust)
      if cargo audit --version >/dev/null 2>&1; then
        cargo audit -q >/dev/null 2>&1 && row deps.vulns:rust ok "cargo audit clean" || row deps.vulns:rust missing "cargo audit reported advisories (or failed)"
      else row deps.vulns:rust verify "cargo-audit not installed"; fi ;;
    python) row deps.vulns:python verify "run pip-audit in the project's environment (uvx pip-audit / pip-audit -r requirements.txt)" ;;
  esac
done
for e in $other; do row "deps.vulns:$e" verify "research the ecosystem's audit tool"; done

# ---------- repository files ----------
wf_dir=.github/workflows
wfs=$(ls $wf_dir/*.yml $wf_dir/*.yaml 2>/dev/null || true)
ci_cfg=""
[ -n "$wfs" ] && ci_cfg="github-actions"
[ -f .gitlab-ci.yml ] && ci_cfg="$ci_cfg gitlab-ci"
[ -f bitbucket-pipelines.yml ] && ci_cfg="$ci_cfg bitbucket"
ls azure-pipelines.y*ml >/dev/null 2>&1 && ci_cfg="$ci_cfg azure"
ci_cfg=${ci_cfg# }

# deps.bot: Dependabot or Renovate covering every ecosystem
dep=""; for f in .github/dependabot.yml .github/dependabot.yaml; do [ -f "$f" ] && dep=$f; done
ren=""; for f in renovate.json renovate.json5 .renovaterc .renovaterc.json .github/renovate.json .github/renovate.json5 .gitlab/renovate.json; do [ -f "$f" ] && ren=$f; done
if [ -n "$ren" ]; then
  row deps.bot verify "Renovate ($ren): confirm it covers [$eco $other] + CI actions and groups security patch/minor"
elif [ -n "$dep" ]; then
  miss=""
  want=""
  for e in $eco; do case $e in node) want="$want npm";; python) if grep -qE '(^|/)uv\.lock$' <<<"$manifests"; then want="$want uv"; else want="$want pip"; fi;; go) want="$want gomod";; rust) want="$want cargo";; esac; done
  [ -n "$wfs" ] && want="$want github-actions"
  for w in $want; do grep -qE "package-ecosystem: *[\"']?${w}[\"']?\s*\$" "$dep" || miss="$miss $w"; done
  [ -n "$eco" ] && ! grep -q 'security-patch-minor' "$dep" && miss="$miss group:security-patch-minor"
  [ -z "$miss" ] && row deps.bot ok "$dep covers:$want" || row deps.bot drift "$dep missing:$miss"
  [ -n "$other" ] && row deps.bot:other verify "check Dependabot support for [$other]"
elif [ "$platform" = github ]; then
  row deps.bot missing "no .github/dependabot.yml or Renovate config"
else
  row deps.bot verify "no Renovate/Dependabot config; on $platform check the native option or Renovate"
fi

# ci.pipeline
if [ "$platform" = github ] || [ -n "$wfs" ]; then
  ci_files=$(for f in $wfs; do grep -qE '^\s*pull_request:' "$f" && ! grep -q 'pull_request_target' "$f" && echo "$f"; done)
  if [ -n "$ci_files" ]; then
    # shellcheck disable=SC2086
    names=$(grep -hE '^\s{4}name:' $ci_files | sed -E 's/^\s*name:\s*//; s/^["'\'']|["'\'']$//g' | paste -sd',' -)
    row ci.pipeline ok "$(echo $ci_files) jobs=[${names:-no fixed job name}]"
  else
    row ci.pipeline missing "no workflow triggered by pull_request"
  fi
elif [ -n "$ci_cfg" ]; then
  row ci.pipeline verify "$ci_cfg present: check it runs on MRs/PRs and the default branch"
else
  row ci.pipeline missing "no CI configuration found"
fi

# ci.pinned
if [ -n "$wfs" ]; then
  # shellcheck disable=SC2086
  unpinned=$(grep -hE '^\s*-?\s*uses:' $wfs | grep -vE '@[0-9a-f]{40}' | grep -vE 'uses:\s*(\./|docker://)' | sed -E 's/^\s*-?\s*uses:\s*//' | sort -u | paste -sd' ' -)
  [ -z "$unpinned" ] && row ci.pinned ok "all actions pinned by SHA" || row ci.pinned drift "not pinned: $unpinned"
elif [ -n "$ci_cfg" ]; then
  row ci.pinned verify "$ci_cfg: check images/includes/components pinned by digest or SHA"
fi

# automerge
am=$(grep -lE 'dependabot/fetch-metadata' $wfs 2>/dev/null | head -1)
if [ -n "$am" ]; then
  issues=""
  grep -q 'pull_request_target' "$am" || issues="$issues no-pull_request_target"
  grep -qE 'actions/checkout' "$am" && issues="$issues CHECKS-OUT-PR-CODE(dangerous)"
  grep -q 'security-patch-minor' "$am" || issues="$issues no-group-filter"
  grep -q 'match-head-commit' "$am" || issues="$issues no-match-head-commit"
  grep -q "github.repository == '$path'" "$am" || issues="$issues no-repo-guard"
  [ -z "$issues" ] && row automerge ok "$am" || row automerge drift "$am:$issues"
elif [ -n "$ren" ]; then
  row automerge verify "Renovate: check automerge only for security patch/minor and only after CI"
elif [ "$platform" = github ] && [ -n "$eco" ]; then
  row automerge missing "no Dependabot auto-merge workflow"
else
  row automerge n/a "no package ecosystem or not on GitHub"
fi

# publish.oidc
publish_wfs=$(grep -lE 'npm publish|pypa/gh-action-pypi-publish|twine upload|uv publish|cargo publish|crates-io-auth-action|gem push|mvn deploy|gradle publish|docker push|goreleaser' $wfs .gitlab-ci.yml 2>/dev/null || true)
publishable=""
for e in $eco; do
  case $e in
    node) [ -f package.json ] && [ "$(jq -r '.private // false' package.json)" != true ] && publishable="$publishable node" ;;
    python) [ -f pyproject.toml ] && grep -qE '^\[project\]' pyproject.toml && publishable="$publishable python?" ;;
    rust) [ -f Cargo.toml ] && ! grep -qE '^\s*publish\s*=\s*false' Cargo.toml && publishable="$publishable rust?" ;;
  esac
done
publishable=${publishable# }
env_name=""
if [ -n "$publish_wfs" ]; then
  for pub in $publish_wfs; do
    issues=""
    grep -qE 'id-token: *write|id_tokens:' "$pub" || issues="$issues no-oidc"
    grep -qE 'secrets\.(NPM_TOKEN|NODE_AUTH_TOKEN|PYPI[A-Z_]*|CARGO_REGISTRY_TOKEN|CRATES_IO[A-Z_]*|RUBYGEMS[A-Z_]*)' "$pub" && issues="$issues uses-long-lived-token"
    grep -q 'npm publish' "$pub" && ! grep -q -- '--provenance' "$pub" && issues="$issues npm-no-provenance"
    grep -qE 'merge-base --is-ancestor' "$pub" || issues="$issues no-tag-history-check"
    e=$(grep -E '^\s+environment:' "$pub" | head -1 | sed -E 's/.*environment:\s*//; s/["'\'']//g; s/\s*#.*//')
    [ -z "$e" ] && issues="$issues no-environment" || env_name="$env_name $e"
    [ -z "$issues" ] && row "publish.oidc:$pub" ok "env=$e" || row "publish.oidc:$pub" drift "$issues"
  done
elif [ -n "$publishable" ]; then
  row publish.oidc missing "no publish workflow; candidates: [$publishable] (? = published by default unless the user declines)"
else
  row publish.oidc n/a "nothing publishable detected"
fi
if [[ " $eco " == *" node "* ]] && [[ " $publishable " == *" node "* ]]; then
  rurl=$(jq -r '.repository.url // .repository // ""' package.json)
  case "$rurl" in *"$host/$path"*) row publish.npm-repository ok "$rurl";; *) row publish.npm-repository drift "repository.url='$rurl' (provenance needs git+https://$host/$path.git)";; esac
fi
for p in $publishable; do
  case $p in
    node) n=$(jq -r .name package.json); v=$(npm view "$n" version 2>/dev/null); row publish.registry:npm manual "$n on npm: ${v:-NOT published}; trusted publisher needs user 2FA (references/ecosystems.md)";;
    python?) row publish.registry:pypi manual "if it is published: register the trusted (or pending) publisher on pypi.org (user 2FA)";;
    rust?) row publish.registry:crates manual "if it is published: configure Trusted Publishing on crates.io (first version needs a manual publish)";;
  esac
done

# ---------- GitHub server-side settings ----------
if [ "$platform" != github ] || [ -z "$meta" ]; then
  for i in merge.squash protect.branch protect.tags secrets.scanning publish.env; do
    row "$i" verify "$platform: needs admin + platform API; if out of scope, write a maintainer recommendation"
  done
  exit 0
fi
api() { gh api "$@" 2>/dev/null; }

chk() { # id field expected
  v=$(jq -r ".$2" <<<"$meta")
  [ "$v" = "$3" ] && row "$1" ok "$2=$v" || row "$1" drift "$2=$v (expected $3)"
}
chk merge.squash/allow_squash_merge allow_squash_merge true
chk merge.squash/allow_merge_commit allow_merge_commit false
chk merge.squash/allow_rebase_merge allow_rebase_merge false
chk merge.squash/title squash_merge_commit_title PR_TITLE
chk merge.squash/message squash_merge_commit_message PR_BODY
chk merge.squash/delete_branch delete_branch_on_merge true
chk merge.squash/update_branch allow_update_branch true
chk merge.squash/auto_merge allow_auto_merge true

branch_rs=""; tag_rs=""; rulesets_ok=1
rs_list=$(gh api "repos/$path/rulesets?includes_parents=false" 2>/dev/null)
if ! jq -e 'type=="array"' <<<"$rs_list" >/dev/null 2>&1; then
  rulesets_ok=0
  rs_err=$(jq -r '.message // "unknown error"' <<<"$rs_list" 2>/dev/null)
  row protect.branch n/a "rulesets unavailable: $rs_err (fallback: classic branch protection if the plan allows, else hooks.protect-branch only)"
  row protect.tags n/a "rulesets unavailable: $rs_err"
fi
for id in $(jq -r 'if type=="array" then .[].id else empty end' <<<"$rs_list" 2>/dev/null); do
  rs=$(api "repos/$path/rulesets/$id")
  tgt=$(jq -r .target <<<"$rs")
  inc=$(jq -r '.conditions.ref_name.include | join(",")' <<<"$rs")
  if [ "$tgt" = branch ] && grep -qE "~DEFAULT_BRANCH|refs/heads/$default_branch" <<<"$inc"; then branch_rs=$rs; fi
  if [ "$tgt" = tag ] && grep -qE 'refs/tags/v\*|~ALL' <<<"$inc"; then tag_rs=$rs; fi
done

# secrets.scanning: native settings, or the fallback (secret scanner in a PR workflow, required on the default branch)
if [ "$(api "repos/$path/automated-security-fixes" | jq -r '.enabled // false')" = true ]; then
  row secrets.scanning/dependabot_security_updates ok enabled
else
  row secrets.scanning/dependabot_security_updates missing disabled
fi
# jobs (check-run names) of PR workflows that run a secret scanner
fb_jobs=$(for f in $ci_files; do awk '
  /^jobs:/ { inj=1; next }
  inj && /^[^ #]/ { inj=0 }
  inj && /^  [A-Za-z0-9_-]+:/ { if (job != "" && hit) print (name != "" ? name : job); job=$1; sub(/:.*/, "", job); name=""; hit=0; next }
  inj && /^    name:/ { n=$0; sub(/^    name:[ ]*/, "", n); gsub(/^["\047]|["\047]$/, "", n); name=n }
  inj && /gitleaks|trufflehog|detect-secrets|ggshield/ { hit=1 }
  END { if (job != "" && hit) print (name != "" ? name : job) }' "$f"; done | sort -u)
fb_list=$(paste -sd',' - <<<"$fb_jobs")
fb_ok=0
if [ -z "$fb_jobs" ]; then
  fb="fallback missing: no pull_request workflow runs a secret scanner (gitleaks, trufflehog…)"
elif [ $rulesets_ok = 0 ]; then
  fb_ok=1; fb="fallback covered: job [$fb_list] present (rulesets unavailable, cannot be required)"
else
  req=""; hit=""
  [ -n "$branch_rs" ] && req=$(jq -r '.rules[] | select(.type=="required_status_checks") | .parameters.required_status_checks[].context' <<<"$branch_rs")
  while IFS= read -r j; do grep -qxF -- "$j" <<<"$req" && hit="$j"; done <<<"$fb_jobs"
  if [ -n "$hit" ]; then fb_ok=1; fb="fallback covered: job '$hit' is a required check"
  else fb="fallback missing: job [$fb_list] present, not required on $default_branch"; fi
fi
owner_type=$(jq -r '.owner.type' <<<"$meta")
sa=$(jq '.security_and_analysis // {}' <<<"$meta")
for k in secret_scanning secret_scanning_non_provider_patterns secret_scanning_push_protection; do
  v=$(jq -r ".$k.status // \"unavailable\"" <<<"$sa")
  why=""
  [ "$v" = unavailable ] && why="unavailable for this visibility/plan (private repos need GitHub Secret Protection)"
  # GitHub reports generic patterns as "disabled" on user-owned repos and a PATCH is a silent refusal:
  # they exist only on organization-owned repos (docs.github.com/en/code-security/secret-scanning/using-advanced-secret-scanning-and-push-protection-features/non-provider-patterns)
  [ "$k" = secret_scanning_non_provider_patterns ] && [ "$v" != enabled ] && [ "$owner_type" = User ] && why="unavailable on user-owned repos (organization-only)"
  if [ "$v" = enabled ]; then row "secrets.scanning/$k" ok enabled
  elif [ -z "$why" ]; then row "secrets.scanning/$k" missing "$v"
  elif [ $fb_ok = 1 ]; then row "secrets.scanning/$k" n/a "$why; $fb"
  else row "secrets.scanning/$k" missing "$why; $fb"; fi
done

if [ $rulesets_ok = 0 ]; then :
elif [ -n "$branch_rs" ]; then
  id=$(jq -r .id <<<"$branch_rs"); issues=""
  [ "$(jq -r .enforcement <<<"$branch_rs")" = active ] || issues="$issues enforcement!=active"
  for t in deletion non_fast_forward pull_request required_status_checks; do
    jq -e --arg t "$t" '.rules | any(.type==$t)' <<<"$branch_rs" >/dev/null || issues="$issues no-$t"
  done
  jq -e '.rules[] | select(.type=="pull_request") | .parameters.allowed_merge_methods == ["squash"]' <<<"$branch_rs" >/dev/null || issues="$issues merge-methods!=squash"
  jq -e '.rules[] | select(.type=="required_status_checks") | .parameters.strict_required_status_checks_policy == true' <<<"$branch_rs" >/dev/null || issues="$issues strict=false"
  checks=$(jq -r '[.rules[] | select(.type=="required_status_checks") | .parameters.required_status_checks[] | "\(.context)#\(.integration_id // "-")"] | join(",")' <<<"$branch_rs")
  jq -e '.bypass_actors | any(.actor_id==5 and .actor_type=="RepositoryRole" and .bypass_mode=="pull_request")' <<<"$branch_rs" >/dev/null || issues="$issues admin-bypass!=pull_request"
  [ -z "$issues" ] && row protect.branch ok "ruleset=$id checks=[$checks]" || row protect.branch drift "ruleset=$id checks=[$checks]:$issues"
else
  row protect.branch missing "no ruleset on ~DEFAULT_BRANCH"
fi

if [ $rulesets_ok = 0 ]; then :
elif [ -n "$tag_rs" ]; then
  id=$(jq -r .id <<<"$tag_rs"); issues=""
  [ "$(jq -r .enforcement <<<"$tag_rs")" = active ] || issues="$issues enforcement!=active"
  for t in deletion non_fast_forward update; do
    jq -e --arg t "$t" '.rules | any(.type==$t)' <<<"$tag_rs" >/dev/null || issues="$issues no-$t"
  done
  jq -e '.bypass_actors | any(.actor_id==5 and .actor_type=="RepositoryRole" and .bypass_mode=="always")' <<<"$tag_rs" >/dev/null || issues="$issues admin-bypass!=always"
  [ -z "$issues" ] && row protect.tags ok "ruleset=$id" || row protect.tags drift "ruleset=$id:$issues"
else
  row protect.tags missing "no tag ruleset covering refs/tags/v*"
fi

cp_json=$(gh api "repos/$path/branches/$default_branch/protection" 2>/dev/null)
cp_msg=$(jq -r '.message // empty' <<<"$cp_json" 2>/dev/null)
if [ -z "$cp_msg" ] && [ -n "$cp_json" ]; then
  row classic-protection drift "classic branch protection active on $default_branch (overlaps the ruleset)"
elif [ "$cp_msg" = "Branch not protected" ]; then
  row classic-protection ok none
else
  row classic-protection n/a "${cp_msg:-unknown}"
fi

if [ -z "$publish_wfs" ]; then
  row publish.env n/a "no publish workflow"
else
  for e in $env_name; do
    envj=$(api "repos/$path/environments/$e")
    if [ -z "$envj" ] || jq -e '.status == "404"' <<<"$envj" >/dev/null 2>&1; then
      row "publish.env:$e" missing "environment '$e' does not exist"; continue
    fi
    custom=$(jq -r '.deployment_branch_policy.custom_branch_policies // false' <<<"$envj")
    pols=$(api "repos/$path/environments/$e/deployment-branch-policies" | jq -r '[(.branch_policies // [])[] | "\(.type):\(.name)"] | join(",")')
    if [ "$custom" = true ] && [ -n "$pols" ] && ! grep -q 'branch:' <<<"$pols"; then
      row "publish.env:$e" ok "$pols"
    else
      row "publish.env:$e" missing "custom=$custom policies=[$pols] (expected only tag:v*)"
    fi
  done
fi
