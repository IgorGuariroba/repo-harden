#!/usr/bin/env bash
# deps.vulns:node rows of audit.sh against a stubbed `npm` (no network).
# Covers: a package without installable deps is n/a; a package with deps but no lockfile
# is audited from a lockfile generated in a temp copy, leaving the repository untouched.
# Usage: test-audit-deps.sh   (exits 0 when every case passes)
set -u
audit="$(cd "$(dirname "$0")" && pwd)/audit.sh"
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
fail=0

# npm stub: `i --package-lock-only` writes package-lock.json (fails when $NPM_LOCK_FAIL is set);
# `audit --json` reports $NPM_VULNS vulnerabilities, or fails without a package-lock.json.
# Each call appends "<subcommand> <cwd>" to $NPM_LOG.
mkdir -p "$tmp/bin"
cat >"$tmp/bin/npm" <<'EOF'
#!/usr/bin/env bash
echo "$1 $PWD" >>"$NPM_LOG"
case $1 in
  i|install) [ -n "${NPM_LOCK_FAIL:-}" ] && exit 1; echo '{"lockfileVersion":3}' >package-lock.json ;;
  audit) [ -f package-lock.json ] || { echo '{"error":{"code":"ENOLOCK"}}'; exit 1; }
         echo "{\"metadata\":{\"vulnerabilities\":{\"total\":${NPM_VULNS:-0}}}}"; [ "${NPM_VULNS:-0}" = 0 ] ;;
  *) exit 0 ;;
esac
EOF
chmod +x "$tmp/bin/npm"

# case <name> <package.json> <extra-file|-> <status> <detail-regex> [VAR=value...]
case_() {
  local name=$1 pkg=$2 extra=$3 want=$4 rx=$5; shift 5
  local repo="$tmp/$name" log="$tmp/$name.log"
  mkdir -p "$repo" && : >"$log"
  git -C "$repo" init -q -b main
  printf '%s\n' "$pkg" >"$repo/package.json"
  [ "$extra" != - ] && echo '{}' >"$repo/$extra"
  git -C "$repo" add -A && git -C "$repo" -c user.name=t -c user.email=t@t commit -qm fixture
  local line
  line=$(cd "$repo" && env PATH="$tmp/bin:$PATH" NPM_LOG="$log" "$@" "$audit" 2>/dev/null | grep -P '^deps\.vulns:node\t')
  local got; got=$(cut -f2 <<<"$line")
  local dirty; dirty=$(git -C "$repo" status --porcelain)
  if [ "$got" = "$want" ] && grep -qE "$rx" <<<"$line" && [ -z "$dirty" ]; then
    echo "ok   $name"
  else
    echo "FAIL $name: expected $want /$rx/, got: ${line:-<no row>}${dirty:+; repo changed: $dirty}"; fail=1
  fi
}

peers='{"name":"p","peerDependencies":{"react":"^19"}}'
deps='{"name":"p","dependencies":{"left-pad":"^1"}}'

case_ peer-only        "$peers"                                   -                 n/a     'no installable deps'
case_ empty            '{"name":"p"}'                             -                 n/a     'no installable deps'
case_ dev-only-nolock  '{"name":"p","devDependencies":{"x":"1"}}' -                 ok      'npm audit: 0.*generated'
case_ workspaces       '{"name":"p","workspaces":["packages/*"]}' -                 ok      'npm audit: 0.*generated'
case_ deps-nolock      "$deps"                                    -                 ok      'npm audit: 0.*generated'
case_ deps-nolock-vuln "$deps"                                    -                 missing 'npm audit: 3 vulnerabilities.*generated' NPM_VULNS=3
case_ deps-lock-fails  "$deps"                                    -                 verify  'could not generate'                    NPM_LOCK_FAIL=1
case_ deps-lock        "$deps"                                    package-lock.json ok      '	npm audit: 0$'
case_ deps-yarn        "$deps"                                    yarn.lock         verify  'yarn\.lock'
case_ deps-pnpm        "$deps"                                    pnpm-lock.yaml    verify  'pnpm-lock\.yaml'

# the generated lockfile never reaches the repository: npm ran outside it
if grep -qE "^(install|audit) $tmp/deps-nolock\$" "$tmp/deps-nolock.log" || ! grep -q '^audit ' "$tmp/deps-nolock.log"; then
  echo "FAIL deps-nolock: npm ran inside the repository"; fail=1
fi

exit $fail
