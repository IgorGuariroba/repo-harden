#!/usr/bin/env bash
# hooks.quality rows of audit.sh in throwaway repos (no remote, no network).
# Covers: plain .githooks, husky, lint-staged in package.json, lefthook, pre-commit framework,
# partial setups (drift), nothing (missing) and no stack (n/a).
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
  if [ "$got" = "$want" ]; then echo "ok   $name"
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

exit $fail
