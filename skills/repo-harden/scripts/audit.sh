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

# What runs at commit time and at push time, per hook source (comments stripped).
hook_names='pre-commit|pre-push|commit-msg|prepare-commit-msg|post-checkout|post-merge|pre-rebase'
lh=$(ls lefthook.y*ml .lefthook.y*ml 2>/dev/null | head -1)
yaml_section() { awk -v k="$2" '$0 ~ "^"k":" { on=1; next } on && /^[^ #]/ { on=0 } on' "$1" 2>/dev/null; }
plain_text() { for f in "$@"; do [ -f "$f" ] && sed -E 's/(^|[[:space:]])#.*$//' "$f"; done; }
# pre-commit framework: one line per hook, "<C|-><P|->\t<hook block>" (C = runs at commit, P = runs at push)
fw_hooks() {
  [ -f .pre-commit-config.yaml ] || return 0
  awk '
    function flush(  s, c, p) {
      if (blk == "") return
      s = (blk ~ /stages:/) ? blk : dflt
      c = (s !~ /stages:/) || (s ~ /stages:[^]]*(pre-commit|[[ ,]commit[] ,])/)
      p = (s !~ /stages:/) || (s ~ /stages:[^]]*(pre-push|[[ ,]push[] ,])/)
      print (c ? "C" : "-") (p ? "P" : "-") "\t" blk; blk = ""
    }
    /^default_stages:/ { dflt = $0; next }
    /^[[:space:]]*- id:/ { flush(); blk = $0; next }
    /^[[:space:]]*-[[:space:]]*repo:/ || /^[^[:space:]#]/ { flush(); next }
    blk != "" { sub(/[[:space:]]#.*/, ""); blk = blk " " $0 }
    END { flush() }' .pre-commit-config.yaml
}
# pre-commit framework remote repos: "<repo>\t<rev>"
fw_remote=""
[ -f .pre-commit-config.yaml ] && fw_remote=$(awk '
  /^[[:space:]]*-?[[:space:]]*repo:/ { r = $0; sub(/.*repo:[[:space:]]*/, "", r); sub(/[[:space:]]+#.*/, "", r); next }
  /^[[:space:]]*rev:/ && r != "" && r != "local" && r != "meta" { v = $0; sub(/.*rev:[[:space:]]*/, "", v); print r "\t" v; r = "" }' .pre-commit-config.yaml)
fw=$(fw_hooks)
pc_sh=$(plain_text "$hookdir/pre-commit" .husky/pre-commit; [ -n "$lh" ] && yaml_section "$lh" pre-commit)
pp_sh=$(plain_text "$hookdir/pre-push" .husky/pre-push; [ -n "$lh" ] && yaml_section "$lh" pre-push)
pc_fw=$(grep -E '^C' <<<"$fw" | cut -f2-)
pp_fw=$(grep -E '^.P' <<<"$fw" | cut -f2-)
all_pc="$pc_sh"$'\n'"$pc_fw"

# hooks.hygiene: pre-commit blocks conflict markers and large new files
h_miss=""
grep -qE 'check[-_]merge[-_]conflict' <<<"$all_pc" || h_miss="$h_miss check-merge-conflict"
grep -qE 'check[-_]added[-_]large[-_]files' <<<"$all_pc" || h_miss="$h_miss check-added-large-files"
if [ -z "$h_miss" ]; then row hooks.hygiene ok "conflict markers + large files checked at commit"
elif [ "$h_miss" = " check-merge-conflict check-added-large-files" ]; then row hooks.hygiene missing "pre-commit checks neither conflict markers nor large files"
else row hooks.hygiene drift "pre-commit lacks:$h_miss"; fi

# hooks.quality: pre-commit runs lint/format on staged files, fast; pre-push runs typecheck/tests (the project's own commands)
lint_rx='lint-staged|nano-staged|eslint|biome|oxlint|prettier|ruff|black|flake8|pylint|isort|gofmt|goimports|golangci-lint|cargo fmt|clippy|rubocop|(npm|pnpm|yarn|bun)( run)? (lint|format|fmt|check)|make (lint|fmt|format)'
test_rx='(npm|pnpm|yarn|bun)( run)? (test|typecheck|type-check)|npm t\b|\btsc\b|vitest|jest|pytest|mypy|pyright|tox|nox|go test|go vet|cargo test|cargo clippy|rspec|make (test|check)'
# heuristic: a linter given "."/"./...", lefthook {all_files}, or a package/make lint script works on the whole repo
whole_rx='\b(eslint|prettier|biome|oxlint|ruff|black|flake8|pylint|isort|gofmt|goimports|rubocop)\b[^|;&]*[[:space:]](\.|\./|\./\.\.\.)([[:space:]]|$|[;&|])|\{all_files\}|(npm|pnpm|yarn|bun)( run)? (lint|format)([[:space:]]|$|[;&|])|make (lint|fmt|format)([[:space:]]|$|[;&|])'
q_lint=no; q_test=no
grep -qE "$lint_rx" <<<"$all_pc" && q_lint=yes
grep -qE "$test_rx" <<<"$pp_sh"$'\n'"$pp_fw" && q_test=yes
whole=$(grep -oE "$whole_rx" <<<"$pc_sh" | sed -E 's/[[:space:];&|]+$//' | sort -u | head -3 | paste -sd',' -)
fw_whole=$(grep -E "$lint_rx" <<<"$pc_fw" | grep -E 'pass_filenames: *false' | grep -oE 'id: *[^ ]+' | sed 's/id: *//' | paste -sd',' -)
slow=$(grep -oE "$test_rx" <<<"$all_pc" | sort -u | head -3 | paste -sd',' -)
rawlist=$(grep -E 'git diff (--cached|--staged)[^|;]*--name-only|git diff --name-only[^|;]*(--cached|--staged)' <<<"$pc_sh" | grep -vE -- '-z\b' ; grep -E 'git diff (--cached|--staged)[^|;]*--name-only|git diff --name-only[^|;]*(--cached|--staged)' <<<"$pc_sh" | grep -v -- '--diff-filter')
q_iss=""
[ -n "$whole" ] && q_iss="$q_iss; pre-commit lints the whole repo, not the staged files: $whole"
[ -n "$fw_whole" ] && q_iss="$q_iss; pre-commit framework lint hooks with pass_filenames: false: $fw_whole"
[ -n "$slow" ] && q_iss="$q_iss; pre-commit runs typecheck/tests (slow: move them to pre-push): $slow"
[ -n "$rawlist" ] && q_iss="$q_iss; staged file list without -z or --diff-filter=ACMR (use run_staged from assets/githooks/staged.sh)"
if [ -z "$eco$other" ]; then
  row hooks.quality n/a "no stack detected: nothing to lint or test"
elif [ $q_lint = yes ] && [ $q_test = yes ] && [ -z "$q_iss" ]; then
  row hooks.quality ok "pre-commit lint/format on staged files + pre-push typecheck/tests"
elif [ $q_lint = no ] && [ $q_test = no ] && [ -z "$q_iss" ]; then
  row hooks.quality missing "no lint/format in pre-commit and no typecheck/tests in pre-push (stack: ${eco:-$other})"
else
  [ $q_lint = no ] && q_iss="; missing pre-commit lint/format$q_iss"
  [ $q_test = no ] && q_iss="; missing pre-push typecheck/tests$q_iss"
  row hooks.quality drift "${q_iss#; }"
fi

# hooks.installed: every hook type the repo declares is active in this clone, and a fresh clone can activate it
declared=""; i_iss=""; sig=""; install=""; act_rx=""
case $mgr in
  pre-commit)
    cfg=$(sed -E 's/(^|[[:space:]])#.*$//' .pre-commit-config.yaml)
    declared="pre-commit $(grep -oE '\b(pre-push|commit-msg|prepare-commit-msg|post-checkout|post-merge)\b' <<<"$cfg" | sort -u | tr '\n' ' ')"
    grep -qE 'stages:[^]]*[[ ,]push[] ,]' <<<"$cfg" && declared="$declared pre-push"
    declared=$(tr ' ' '\n' <<<"$declared" | grep . | sort -u | tr '\n' ' ')
    dit=$(grep -E '^default_install_hook_types:' <<<"$cfg")
    for h in $declared; do
      [ "$h" = pre-commit ] && [ -z "$dit" ] && continue
      grep -qE "[[ ,]${h}[] ,]" <<<"$dit" || i_iss="$i_iss; default_install_hook_types lacks $h (a plain 'pre-commit install' skips it)"
    done
    [ -n "$hp" ] && i_iss="$i_iss; core.hooksPath=$hp is set: 'pre-commit install' refuses to run (git config --unset core.hooksPath)"
    sig='hook-impl|File generated by pre-commit'; install="pre-commit install"; act_rx='pre-commit install' ;;
  husky)
    declared=$(for f in .husky/*; do [ -f "$f" ] && basename "$f"; done | grep -xE "$hook_names" | tr '\n' ' ')
    case "$hp" in .husky|.husky/_) ;; *) i_iss="$i_iss; core.hooksPath=${hp:-unset} (husky expects .husky/_)" ;; esac
    install="npm install (runs husky through the prepare script)"; act_rx='husky' ;;
  lefthook)
    declared=$(grep -oE "^($hook_names):" "$lh" | tr -d ':' | tr '\n' ' ')
    sig='lefthook'; install="lefthook install"; act_rx='lefthook install' ;;
  simple-git-hooks)
    declared=$(jq -r '.["simple-git-hooks"] | keys[]' package.json 2>/dev/null | grep -xE "$hook_names" | tr '\n' ' ')
    install="npx simple-git-hooks"; act_rx='simple-git-hooks' ;;
  *)
    decl_dir=$(git ls-files 2>/dev/null | grep -E "^(\.githooks|githooks|\.hooks|hooks|\.git-hooks|git-hooks|scripts/(git-)?hooks|tools/(git-)?hooks)/($hook_names)$" | head -1 | xargs -r dirname)
    if [ -n "$decl_dir" ]; then
      declared=$(git ls-files -- "$decl_dir" | sed "s#^$decl_dir/##" | grep -xE "$hook_names" | tr '\n' ' ')
      [ "${hp%/}" = "$decl_dir" ] || i_iss="$i_iss; core.hooksPath=${hp:-unset} (expected $decl_dir)"
      install="git config core.hooksPath $decl_dir"; act_rx='core\.?hooksPath'
    fi ;;
esac
not_inst=""; foreign=""
for h in $declared; do
  if [ ! -x "$hookdir/$h" ]; then not_inst="$not_inst $h"
  elif [ -n "$sig" ] && ! grep -qE "$sig" "$hookdir/$h"; then foreign="$foreign $h"; fi
done
[ -n "$not_inst" ] && i_iss="$i_iss; not installed in $hookdir:$not_inst (run: $install)"
[ -n "$foreign" ] && i_iss="$i_iss; $hookdir has hooks that do not call $mgr:$foreign (run: $install)"
if [ -n "$act_rx" ]; then
  prep=$([ -f package.json ] && jq -r '[.scripts.prepare, .scripts.postinstall, (.devDependencies // {} | keys | join(" "))] | map(. // "") | join(" ")' package.json 2>/dev/null)
  [ "$mgr" = lefthook ] && act_rx="$act_rx|lefthook"  # the lefthook npm package installs itself on postinstall
  act_docs=$(git ls-files -- 'README*' 'CONTRIBUTING*' '.github/CONTRIBUTING*' 'docs/*.md' 2>/dev/null)
  documented=no
  grep -qE "$act_rx" <<<"$prep" && documented=yes
  while IFS= read -r f; do [ -n "$f" ] && grep -qE "$act_rx" -- "$f" 2>/dev/null && documented=yes; done <<<"$act_docs"
  [ $documented = yes ] ||
    i_iss="$i_iss; activation for a fresh clone is neither automatic (prepare/postinstall) nor documented in README/CONTRIBUTING: $install"
fi
if [ -z "${declared// /}" ]; then
  if [ -x "$hookdir/pre-commit" ] || [ -x "$hookdir/pre-push" ]; then row hooks.installed ok "local-only hooks in $hookdir (not versioned)"
  else row hooks.installed n/a "no hooks declared"; fi
elif [ -z "$i_iss" ]; then row hooks.installed ok "[${declared% }] active in $hookdir (manager=${mgr:-none})"
else row hooks.installed drift "${i_iss#; }"; fi

# ---------- local: dependency vulnerabilities ----------
npm_audit_row() { # dir detail-suffix
  local v
  v=$(cd "$1" && npm audit --json 2>/dev/null | jq -r '.metadata.vulnerabilities.total // "?"')
  [ "$v" = 0 ] && row deps.vulns:node ok "npm audit: 0$2" || row deps.vulns:node missing "npm audit: $v vulnerabilities$2"
}
for e in $eco; do
  case $e in
    node)
      other_lock=$(ls yarn.lock pnpm-lock.yaml bun.lock bun.lockb 2>/dev/null | head -1)
      if [ ! -f package.json ]; then
        row deps.vulns:node verify "no package.json at the root: audit each package"
      elif ! jq -e '[.dependencies, .devDependencies, .optionalDependencies, .workspaces] | map(. // {} | length) | add > 0' package.json >/dev/null 2>&1; then
        row deps.vulns:node n/a "no installable deps (only peerDependencies or none)"
      elif ! has npm; then
        row deps.vulns:node verify "npm not installed"
      elif [ -f package-lock.json ]; then
        npm_audit_row "$PWD" ""
      elif [ -n "$other_lock" ]; then
        row deps.vulns:node verify "$other_lock: use its package manager's audit"
      else
        # no lockfile: generate one in a temp copy of the manifests, never in the repository
        lockdir=$(mktemp -d)
        git ls-files -z -- package.json '*/package.json' .npmrc | grep -zvE '(^|/)node_modules/' |
          while IFS= read -r -d '' f; do mkdir -p "$lockdir/$(dirname "$f")" && cp "$f" "$lockdir/$f"; done
        if (cd "$lockdir" && npm install --package-lock-only --ignore-scripts --no-audit --no-fund >/dev/null 2>&1); then
          npm_audit_row "$lockdir" " (no lockfile; generated with npm install --package-lock-only in a temp copy)"
        else
          row deps.vulns:node verify "no lockfile and could not generate one (npm install --package-lock-only failed)"
        fi
        rm -rf "$lockdir"
      fi ;;
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
  row deps.bot verify "Renovate ($ren): confirm it covers [$eco $other] + CI actions$([ -n "$fw_remote" ] && echo ' + pre-commit hooks (opt-in: "pre-commit": {"enabled": true})') and groups security patch/minor"
elif [ -n "$dep" ]; then
  miss=""
  want=""
  for e in $eco; do case $e in node) want="$want npm";; python) if grep -qE '(^|/)uv\.lock$' <<<"$manifests"; then want="$want uv"; else want="$want pip"; fi;; go) want="$want gomod";; rust) want="$want cargo";; esac; done
  [ -n "$wfs" ] && want="$want github-actions"
  [ -n "$fw_remote" ] && want="$want pre-commit"
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
# ci.pinned:pre-commit: remote hooks frozen to a SHA with the version in a comment (pre-commit autoupdate --freeze)
if [ -n "$fw_remote" ]; then
  unfrozen=$(grep -vE $'\t''["'\'']?[0-9a-f]{40}["'\'']?[[:space:]]+#[[:space:]]*frozen:' <<<"$fw_remote" | sed -E $'s/\t/@/; s/[[:space:]]+#.*//' | paste -sd' ' -)
  [ -z "$unfrozen" ] && row ci.pinned:pre-commit ok "every remote hook frozen to a SHA" || row ci.pinned:pre-commit drift "not frozen (pre-commit autoupdate --freeze): $unfrozen"
fi

# ci.pr-title: with a commit convention, CI validates the PR title (it becomes the squash commit message)
conv_rx='^[a-z]+(\([^)]+\))?!?: .+'
conv=$(ls commitlint.config.* .commitlintrc* .czrc .cz.json .cz.toml cz.toml cz.json release-please-config.json .releaserc* release.config.* 2>/dev/null | paste -sd' ' -)
[ -f package.json ] && jq -e '.commitlint or .config.commitizen or .release' package.json >/dev/null 2>&1 && conv="$conv package.json"
[ -f pyproject.toml ] && grep -qE '^\[tool\.commitizen\]' pyproject.toml && conv="$conv pyproject.toml"
subjects=$(git log --no-merges -n 20 --format=%s 2>/dev/null)
n_subj=$(grep -c . <<<"$subjects"); n_conv=$(grep -cE "$conv_rx" <<<"$subjects")
[ "$n_subj" -ge 5 ] && [ $((n_conv * 5)) -ge $((n_subj * 4)) ] && conv="$conv history($n_conv/$n_subj)"
conv=${conv# }
if [ -z "$conv" ]; then
  row ci.pr-title n/a "no commit convention (commitlint/commitizen/release tool config, or >=80% conventional subjects)"
elif [ -n "$wfs" ]; then
  # shellcheck disable=SC2086
  tw=$(grep -lE 'pull_request\.title|action-semantic-pull-request' $wfs 2>/dev/null)
  if [ -z "$tw" ]; then
    row ci.pr-title missing "convention [$conv], no workflow validates the PR title (assets/workflows/pr-title.yml)"
  else
    t_iss=""
    for f in $tw; do
      grep -qE '^\s*types:.*\bedited\b' "$f" || t_iss="$t_iss $f:not-rerun-when-title-edited"
      grep -E 'pull_request\.title' "$f" | grep -qvE '^\s*[A-Za-z_][A-Za-z0-9_]*:\s*\$\{\{\s*github\.event\.pull_request\.title\s*\}\}\s*$' && t_iss="$t_iss $f:title-interpolated-in-script(injection)"
    done
    # shellcheck disable=SC2086
    [ -z "$t_iss" ] && row ci.pr-title ok "$(echo $tw) (convention [$conv])" || row ci.pr-title drift "${t_iss# }"
  fi
elif [ -n "$ci_cfg" ]; then
  row ci.pr-title verify "convention [$conv]: check that $ci_cfg validates the MR/PR title"
else
  row ci.pr-title missing "convention [$conv], no CI to validate the PR title"
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

# ---------- ignore files ----------
# Only the repository's own ignore files count: a global excludesFile or .git/info/exclude protects one machine.
repo_ignored() { # path -> 0 when a versionable ignore file ignores it
  local m src pat
  m=$(git -c core.excludesFile=/dev/null check-ignore -v --no-index -- "$1" 2>/dev/null) || return 1
  src=${m%%:*}; pat=$(cut -f1 <<<"$m"); pat=${pat#*:}; pat=${pat#*:}
  case "$src" in /*|.git/*) return 1 ;; esac
  [[ $pat != '!'* ]]
}
secret_rx='(^|/)\.env(\.[^/]+)?$|\.(pem|key|p12|pfx|jks|keystore)$|(^|/)id_(rsa|dsa|ecdsa|ed25519)$'
example_rx='(^|/)\.env\.(example|sample|template|dist|defaults?)$'

# ignore.git: secret probes + the ecosystems' dependency/cache dirs; build outputs are verified by running the build
if [ ! -f .gitignore ]; then
  row ignore.git missing "no .gitignore (start from the ecosystem baseline in references/ecosystems.md)"
else
  miss=""
  probes=".env .env.local .env.production config/.env key.pem certs/server.key"
  for e in $eco; do case $e in
    node) probes="$probes node_modules/x" ;;
    python) probes="$probes __pycache__/x.pyc .venv/x" ;;
    rust) probes="$probes target/x" ;;
  esac; done
  for p in $probes; do repo_ignored "$p" || miss="$miss ${p%/x}"; done
  repo_ignored .env.example && miss="$miss !.env.example(ignored)"
  [ -z "$miss" ] && row ignore.git ok "secrets and ecosystem dirs ignored" || row ignore.git drift "not ignored:$miss"
fi
tracked_secrets=$(git ls-files 2>/dev/null | grep -E "$secret_rx" | grep -vE "$example_rx" | head -10 | paste -sd' ' -)
[ -n "$tracked_secrets" ] && row ignore.git:tracked verify "tracked: $tracked_secrets (real secret: git rm --cached in the PR + the user rotates it, history keeps it; fixture: keep and record why)"
[ -n "$eco$other" ] && row ignore.git:build verify "run install+build+test in a /tmp copy: every new untracked file (git status --porcelain --untracked-files=all) must be ignored"

# ignore.docker: every Dockerfile's build context excludes .git, secrets and dependencies
dockerfiles=$(git ls-files 2>/dev/null | grep -E '(^|/)(Dockerfile|Containerfile)(\.[^/]+)?$|\.(Dockerfile|Containerfile)$' | grep -vE '\.dockerignore$' || true)
if [ -z "$dockerfiles" ]; then
  row ignore.docker n/a "no Dockerfile"
else
  nodi=""; issues=""
  for f in $dockerfiles; do
    di=""; for c in "$f.dockerignore" "$(dirname "$f")/.dockerignore" .dockerignore; do [ -f "$c" ] && { di=${c#./}; break; }; done
    if [ -z "$di" ]; then nodi="$nodi $f"; continue; fi
    grep -qxE '\*|\*\*|/\*' "$di" && continue   # allowlist: ignore everything, re-include with !
    need="git env"; [[ " $eco " == *" node "* ]] && need="$need node_modules"
    for n in $need; do
      case $n in
        git) rx='^/?(\*\*/)?\.git/?$' ;;
        env) rx='^/?(\*\*/)?\.env' ;;
        node_modules) rx='^/?(\*\*/)?node_modules/?$' ;;
      esac
      grep -qE "$rx" "$di" || issues="$issues $di:no-$n"
    done
  done
  # shellcheck disable=SC2086
  if [ -z "$nodi$issues" ]; then row ignore.docker ok "$(echo $dockerfiles)"
  elif [ -z "$issues" ]; then row ignore.docker missing "no .dockerignore for:$nodi"
  else row ignore.docker drift "${issues# }${nodi:+; no .dockerignore for:$nodi}"; fi
fi

# ignore.publish: what each publishable package ships
if [ -z "$publishable" ]; then
  row ignore.publish n/a "nothing publishable detected"
else
  for p in $publishable; do
    case $p in
      node)
        if ! has npm; then row ignore.publish:npm verify "npm not installed: list the package with npm pack --dry-run"; continue; fi
        packed=$(npm pack --dry-run --json --ignore-scripts 2>/dev/null | jq -r '.[0].files[].path' 2>/dev/null)
        if [ -z "$packed" ]; then row ignore.publish:npm verify "npm pack --dry-run failed: list the package contents by hand"; continue; fi
        issues=""
        leaked=$(grep -E "$secret_rx" <<<"$packed" | grep -vE "$example_rx" | paste -sd' ' -)
        [ -n "$leaked" ] && issues="$issues packs:[$leaked]"
        jq -e '.files | type=="array" and length>0' package.json >/dev/null 2>&1 || issues="$issues no-files-allowlist$([ -f .npmignore ] && echo '(.npmignore replaces .gitignore)')"
        [ -z "$issues" ] && row ignore.publish:npm ok "$(wc -l <<<"$packed") files, files allowlist" || row ignore.publish:npm drift "${issues# }" ;;
      python?) row ignore.publish:python verify "if published: build (uv build / python -m build) and list the sdist (tar tzf dist/*.tar.gz)" ;;
      rust?) row ignore.publish:rust verify "if published: cargo package --list --allow-dirty" ;;
    esac
  done
fi

# ---------- GitHub server-side settings ----------
if [ "$platform" != github ] || [ -z "$meta" ]; then
  for i in merge.squash protect.branch protect.tags protect.signed secrets.scanning publish.env review.bot; do
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

branch_rs=""; tag_rs=""; review_rs=""; signed_rs=""; rulesets_ok=1
rs_list=$(gh api "repos/$path/rulesets?includes_parents=false" 2>/dev/null)
if ! jq -e 'type=="array"' <<<"$rs_list" >/dev/null 2>&1; then
  rulesets_ok=0
  rs_err=$(jq -r '.message // "unknown error"' <<<"$rs_list" 2>/dev/null)
  row protect.branch n/a "rulesets unavailable: $rs_err (fallback: classic branch protection if the plan allows, else hooks.protect-branch only)"
  row protect.tags n/a "rulesets unavailable: $rs_err"
  row protect.signed n/a "rulesets unavailable: $rs_err"
fi
for id in $(jq -r 'if type=="array" then .[].id else empty end' <<<"$rs_list" 2>/dev/null); do
  rs=$(api "repos/$path/rulesets/$id")
  tgt=$(jq -r .target <<<"$rs")
  inc=$(jq -r '.conditions.ref_name.include | join(",")' <<<"$rs")
  if [ "$tgt" = branch ] && grep -qE "~DEFAULT_BRANCH|refs/heads/$default_branch|~ALL" <<<"$inc"; then
    jq -e '.rules | any(.type=="copilot_code_review")' <<<"$rs" >/dev/null 2>&1 && review_rs=$rs
    jq -e '.enforcement=="active" and (.rules | any(.type=="required_signatures"))' <<<"$rs" >/dev/null 2>&1 && signed_rs=$rs
    # protection ruleset = targets the default branch and has rules beyond the review and signature ones
    if ! grep -q '~ALL' <<<"$inc" && jq -e '.rules | any(.type!="copilot_code_review" and .type!="required_signatures")' <<<"$rs" >/dev/null 2>&1; then branch_rs=$rs; fi
  fi
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

# protect.signed: verified signatures required on the default branch (on by default; applied after this run's PR merges)
if [ $rulesets_ok = 0 ]; then :
elif [ -n "$signed_rs" ]; then
  row protect.signed ok "required_signatures ruleset=$(jq -r .id <<<"$signed_rs")"
else
  sig="commit.gpgsign=$(git config --get commit.gpgsign || echo unset) signingkey=$(git config --get user.signingkey >/dev/null && echo set || echo unset)"
  row protect.signed missing "no active required_signatures rule on ~DEFAULT_BRANCH (local $sig)"
fi

# review.bot: automated review on every PR (Copilot ruleset rule, or a review App configured in the repo)
review_cfg=$(ls .coderabbit.yaml .coderabbit.yml 2>/dev/null | head -1)
if [ -n "$review_rs" ]; then
  id=$(jq -r .id <<<"$review_rs"); issues=""
  [ "$(jq -r .enforcement <<<"$review_rs")" = active ] || issues="$issues enforcement!=active"
  jq -e '.rules[] | select(.type=="copilot_code_review") | .parameters.review_on_push == true' <<<"$review_rs" >/dev/null || issues="$issues review_on_push!=true"
  [ -z "$issues" ] && row review.bot ok "copilot_code_review ruleset=$id" || row review.bot drift "copilot_code_review ruleset=$id:$issues"
elif [ -n "$review_cfg" ]; then
  row review.bot verify "$review_cfg present: confirm the CodeRabbit App is installed on $path"
elif [ $rulesets_ok = 0 ]; then
  row review.bot missing "rulesets unavailable: $rs_err (fallback: a review App such as CodeRabbit)"
else
  row review.bot missing "no copilot_code_review rule on ~DEFAULT_BRANCH and no review App config"
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
