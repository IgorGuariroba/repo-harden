#!/usr/bin/env bash
# ignore.* rows of audit.sh in throwaway repos (no remote, no network).
# Covers: .gitignore secret/ecosystem probes (global and .git/info/exclude excludes do not count),
# tracked secrets, .dockerignore per Dockerfile, npm package contents (npm pack --dry-run).
# Usage: test-audit-ignore.sh   (exits 0 when every case passes)
set -u
audit="$(cd "$(dirname "$0")" && pwd)/audit.sh"
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
fail=0
# a user's global excludes must never make a repo look compliant
mkdir -p "$tmp/home"; printf '.env*\n*.pem\n*.key\nnode_modules/\n' >"$tmp/home/gitignore"
export HOME="$tmp/home" GIT_CONFIG_GLOBAL="$tmp/home/gitconfig"
git config --global core.excludesFile "$tmp/home/gitignore"

# case <row-id> <name> <expected-status|none> <setup-commands>
case_() {
  local id=$1 name=$2 want=$3 setup=$4 repo="$tmp/$2" line got
  git init -q -b main "$repo"
  (cd "$repo" && eval "$setup" && git add -A) >/dev/null 2>&1
  line=$(cd "$repo" && "$audit" 2>/dev/null | grep -P "^${id//./\\.}\t")
  got=$(cut -f2 <<<"$line"); got=${got:-none}
  if [ "$got" = "$want" ]; then echo "ok   $id $name"
  else echo "FAIL $id $name: expected $want, got: ${line:-<no row>}"; fail=1; fi
}
gi() { printf "printf '%s' >.gitignore" "$1"; }
secrets='.env\n.env.*\n!.env.example\n*.pem\n*.key\n'
priv='echo "{\"name\":\"x\",\"private\":true}" >package.json'
pub() { printf "echo '{\"name\":\"x\",\"version\":\"1.0.0\"%s}' >package.json" "$1"; }

case_ ignore.git no-gitignore      missing "echo x >README.md"
case_ ignore.git secrets-ok        ok      "$(gi "$secrets")"
case_ ignore.git env-only          drift   "$(gi '.env\n.env.*\n!.env.example\n')"
case_ ignore.git env-star-example  drift   "$(gi '.env*\n*.pem\n*.key\n')"
case_ ignore.git info-exclude-only drift   "$(gi 'dist/\n'); printf '.env*\n*.pem\n*.key\n' >.git/info/exclude"
case_ ignore.git node-no-modules   drift   "$priv; $(gi "$secrets")"
case_ ignore.git node-full         ok      "$priv; $(gi "${secrets}node_modules/\n")"
case_ ignore.git python-full       ok      "echo '[project]' >pyproject.toml; $(gi "${secrets}__pycache__/\n.venv/\n")"
case_ ignore.git rust-no-target    drift   "echo '[package]' >Cargo.toml; $(gi "$secrets")"

case_ ignore.git:tracked clean        none   "$(gi "$secrets"); echo A=1 >.env.example"
case_ ignore.git:tracked env-tracked  verify "echo A=1 >.env; git add -f .env; $(gi "$secrets")"
case_ ignore.git:tracked key-tracked  verify "mkdir certs; echo k >certs/server.key; git add -f certs"
case_ ignore.git:build   with-stack   verify "$priv"
case_ ignore.git:build   no-stack     none   "echo x >README.md"

case_ ignore.docker no-dockerfile   n/a     "echo x >README.md"
case_ ignore.docker no-dockerignore missing "echo 'FROM scratch' >Dockerfile"
case_ ignore.docker complete        ok      "$priv; echo 'FROM scratch' >Dockerfile; printf '.git\n.env*\nnode_modules\n' >.dockerignore"
case_ ignore.docker no-env          drift   "echo 'FROM scratch' >Dockerfile; printf '.git\n' >.dockerignore"
case_ ignore.docker no-node-modules drift   "$priv; echo 'FROM scratch' >Dockerfile; printf '.git\n.env\n' >.dockerignore"
case_ ignore.docker allowlist       ok      "echo 'FROM scratch' >Dockerfile; printf '*\n!src\n' >.dockerignore"
case_ ignore.docker per-dockerfile  ok      "echo 'FROM scratch' >Dockerfile.prod; printf '**/.git\n**/.env\n' >Dockerfile.prod.dockerignore"
case_ ignore.docker subdir-context  ok      "mkdir api; echo 'FROM scratch' >api/Dockerfile; printf '.git\n.env\n' >api/.dockerignore"

case_ ignore.publish private      n/a     "$priv"
case_ ignore.publish:python python       verify  "printf '[project]\nname = \"x\"\n' >pyproject.toml"
if command -v npm >/dev/null 2>&1; then
  case_ ignore.publish:npm files-list   ok    "$(pub ',"files":["index.js"]'); echo 1 >index.js; echo S=1 >.env; $(gi "$secrets")"
  case_ ignore.publish:npm no-files     drift "$(pub ''); echo 1 >index.js; $(gi "$secrets")"
  case_ ignore.publish:npm npmignore    drift "$(pub ''); echo 1 >index.js; echo S=1 >.env; $(gi "$secrets"); printf 'test/\n' >.npmignore"
else
  echo "skip ignore.publish npm cases (npm not installed)"
fi

exit $fail
