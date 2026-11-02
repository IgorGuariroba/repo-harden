#!/usr/bin/env bash
# Validates pre-commit/pre-push in a throwaway repo under /tmp with a bare remote.
# Usage: test-hooks.sh <dir-with-pre-commit-and-pre-push>
# Exits 0 only if all 6 cases behave as expected.
set -u
src=$(cd "$1" && pwd)
t=$(mktemp -d /tmp/repo-harden-hooks.XXXXXX)
trap 'rm -rf "$t"' EXIT
git init -q --bare -b main "$t/remote.git"
git init -q -b main "$t/w" && cd "$t/w" || exit 2
git config user.email t@t; git config user.name t
git remote add origin "$t/remote.git"
git commit -q --allow-empty -m init                # before hooks
git push -q origin main 2>/dev/null
mkdir .hk && cp "$src/pre-commit" "$src/pre-push" .hk/ && chmod +x .hk/*
git config core.hooksPath .hk

fail=0
case_() { # description expected(blocked|allowed) command...
  desc=$1 exp=$2; shift 2
  out=$("$@" 2>&1); rc=$?
  got=$([ $rc -eq 0 ] && echo allowed || echo blocked)
  mark=$([ "$got" = "$exp" ] && echo "✅" || { fail=1; echo "❌"; })
  printf '%s %-32s expected=%-10s got=%s\n' "$mark" "$desc" "$exp" "$got"
  [ "$got" = blocked ] && printf '%s\n' "$out" | sed 's/^/      /'
}
case_ "commit on main"            blocked git commit -q --allow-empty -m x
git switch -q -c feat/x
case_ "commit on feat/x"          allowed git commit -q --allow-empty -m y
git switch -q main
case_ "ALLOW_MAIN=1 commit main"  allowed env ALLOW_MAIN=1 git commit -q --allow-empty -m z
case_ "push to main"              blocked git push -q origin main
case_ "push feat/x:main"          blocked git push -q origin feat/x:main
case_ "push feat/x"               allowed git push -q origin feat/x
exit $fail
