#!/usr/bin/env bash
# hooks.quality rows of audit.sh in throwaway repos (no remote, no network).
# Covers: plain .githooks, husky, lint-staged in package.json, lefthook, pre-commit framework,
# partial setups (drift), nothing (missing), no stack (n/a), and the drift heuristics: whole-repo lint at commit,
# tests/typecheck at commit, hand-rolled staged lists, pre-commit framework lint hooks with pass_filenames: false.
# Usage: test-audit-quality.sh   (exits 0 when every case passes)
set -u
audit="$(cd "$(dirname "$0")" && pwd)/audit.sh"
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
fail=0

# case <name> <expected-status> <setup-commands>
case_() {
  local name=$1 want=$2 setup=$3 repo="$tmp/$1" line got
  git init -q -b main "$repo"
  (cd "$repo" && eval "$setup" && git add -A) >/dev/null 2>&1
  line=$(cd "$repo" && "$audit" 2>/dev/null | grep -P '^hooks\.quality\t')
  got=$(cut -f2 <<<"$line")
  if [ "$got" = "$want" ]; then echo "ok   $name${VERBOSE:+  ${line#*	}}"
  else echo "FAIL $name: expected $want, got: ${line:-<no row>}"; fail=1; fi
}
node='echo "{\"name\":\"x\",\"private\":true}" >package.json'
hook() { printf 'mkdir -p %s && printf "#!/bin/sh\\n%s\\n" >%s/%s && chmod +x %s/%s' "$1" "$3" "$1" "$2" "$1" "$2"; }

case_ no-stack        n/a     "$(hook .githooks pre-commit 'npx eslint .'); git config core.hooksPath .githooks"
case_ nothing         missing "$node"
case_ githooks-both   ok      "$node; $(hook .githooks pre-commit 'npx --no-install eslint \$files'); $(hook .githooks pre-push 'npm test'); git config core.hooksPath .githooks"
case_ only-lint       drift   "$node; $(hook .githooks pre-commit 'npx prettier --check .'); git config core.hooksPath .githooks"
case_ only-tests      drift   "$node; $(hook .githooks pre-push 'npm run typecheck'); git config core.hooksPath .githooks"
case_ husky-staged    ok      "echo '{\"name\":\"x\",\"private\":true,\"lint-staged\":{\"*.ts\":\"eslint\"}}' >package.json; $(hook .husky pre-commit 'npx lint-staged'); $(hook .husky pre-push 'npm test')"
case_ lefthook        ok      "echo 'module x' >go.mod; printf 'pre-commit:\n  commands:\n    fmt:\n      run: gofmt -l {staged_files}\npre-push:\n  commands:\n    test:\n      run: go test ./...\n' >lefthook.yml"
case_ pre-commit-fw   ok      "echo '[project]' >pyproject.toml; printf 'repos:\n- repo: local\n  hooks:\n  - id: ruff\n    entry: ruff check\n  - id: pytest\n    entry: pytest\n    stages: [pre-push]\n' >.pre-commit-config.yaml"

push='npm test'
case_ whole-repo-dot  drift   "$node; $(hook .githooks pre-commit 'npx eslint .'); $(hook .githooks pre-push "$push"); git config core.hooksPath .githooks"
case_ whole-repo-npm  drift   "$node; $(hook .githooks pre-commit 'npm run lint'); $(hook .githooks pre-push "$push"); git config core.hooksPath .githooks"
case_ npm-lint-staged ok      "$node; $(hook .githooks pre-commit 'npm run lint:staged'); $(hook .githooks pre-push "$push"); git config core.hooksPath .githooks"
case_ tests-at-commit drift   "$node; $(hook .githooks pre-commit 'npx lint-staged \&\& npm test'); $(hook .githooks pre-push "$push"); git config core.hooksPath .githooks"
case_ raw-staged-list drift   "$node; $(hook .githooks pre-commit 'npx eslint \$(git diff --cached --name-only)'); $(hook .githooks pre-push "$push"); git config core.hooksPath .githooks"
case_ safe-staged-list ok     "$node; $(hook .githooks pre-commit 'git diff --cached --name-only -z --diff-filter=ACMR | xargs -0 npx eslint'); $(hook .githooks pre-push "$push"); git config core.hooksPath .githooks"
case_ run-staged      ok      "$node; $(hook .githooks pre-commit ". .githooks/staged.sh; run_staged 'npx eslint' '*.js'"); $(hook .githooks pre-push "$push"); git config core.hooksPath .githooks"
case_ lefthook-all    drift   "echo 'module x' >go.mod; printf 'pre-commit:\n  commands:\n    fmt:\n      run: gofmt -l {all_files}\npre-push:\n  commands:\n    test:\n      run: go test ./...\n' >lefthook.yml"
case_ fw-no-filenames drift   "echo '[project]' >pyproject.toml; printf 'repos:\n- repo: local\n  hooks:\n  - id: ruff\n    entry: ruff check\n    pass_filenames: false\n  - id: pytest\n    entry: pytest\n    stages: [pre-push]\n' >.pre-commit-config.yaml"
case_ fw-pytest-commit drift  "echo '[project]' >pyproject.toml; printf 'repos:\n- repo: local\n  hooks:\n  - id: ruff\n    entry: ruff check\n  - id: pytest\n    entry: pytest\n' >.pre-commit-config.yaml"
case_ fw-default-push ok      "echo '[project]' >pyproject.toml; printf 'default_stages: [pre-commit]\nrepos:\n- repo: local\n  hooks:\n  - id: ruff\n    entry: ruff check\n  - id: pytest\n    entry: pytest\n    stages: [pre-push]\n' >.pre-commit-config.yaml"

exit $fail
