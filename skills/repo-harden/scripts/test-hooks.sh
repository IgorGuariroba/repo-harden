#!/usr/bin/env bash
# Validates pre-commit/pre-push in a throwaway repo under /tmp with a bare remote.
# Usage: test-hooks.sh <dir-with-pre-commit-and-pre-push>
# Exits 0 only if every case behaves as expected.
# Covers: branch guard (commit + push), hygiene (conflict markers, large files, LFS skip) and,
# when <dir>/staged.sh exists, run_staged (staged-only, NUL-safe, deleted files skipped, partial staging refused).
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
  printf '%s %-36s expected=%-10s got=%s\n' "$mark" "$desc" "$exp" "$got"
  [ "$got" = blocked ] && printf '%s\n' "$out" | sed 's/^/      /'
}
commit_file() { # path content-command
  printf '%s\n' "$2" >"$1" && git add -- "$1" && git commit -q -m "$1"
}
lt='<<<<<<<' gt='>>>>>>>'

case_ "commit on main"                blocked git commit -q --allow-empty -m x
git switch -q -c feat/x
case_ "commit on feat/x"              allowed git commit -q --allow-empty -m y
git switch -q main
case_ "ALLOW_MAIN=1 commit main"      allowed env ALLOW_MAIN=1 git commit -q --allow-empty -m z
case_ "push to main"                  blocked git push -q origin main
case_ "push feat/x:main"              blocked git push -q origin feat/x:main
case_ "push feat/x"                   allowed git push -q origin feat/x

git switch -q feat/x
case_ "conflict markers"              blocked commit_file c.txt "$(printf 'a\n%s HEAD\nb\n=======\nc\n%s feat\n' "$lt" "$gt")"
git reset -q --hard
case_ "markdown ======= underline"    allowed commit_file d.md "$(printf 'Title\n=======\n')"
case_ "new file of 600 KB"            blocked sh -c 'head -c 614400 /dev/zero >big.bin && git add big.bin && git commit -q -m big'
git rm -q --cached big.bin; rm -f big.bin
case_ "hooks.maxFileKB=1000 raises"   allowed sh -c 'head -c 614400 /dev/zero >big.bin && git add big.bin && git -c hooks.maxFileKB=1000 commit -q -m big'
case_ "Git LFS file skipped"          allowed sh -c 'echo "*.psd filter=lfs" >.gitattributes && head -c 614400 /dev/zero >x.psd && git -c filter.lfs.clean=cat -c filter.lfs.smudge=cat add .gitattributes x.psd && git commit -q -m lfs'

if [ -f "$src/staged.sh" ]; then
  cp "$src/staged.sh" .hk/
  # the linter fails on any file containing BAD; it logs the arguments it received
  printf '#!/bin/sh\nfor f; do echo "$f" >>"%s/args"; grep -q BAD -- "$f" && exit 1; done; exit 0\n' "$t" >"$t/lint"
  chmod +x "$t/lint"
  printf '#!/bin/sh\n. "$(dirname "$0")/staged.sh"\nrun_staged "%s/lint" "*.js" || exit 1\n' "$t" >.hk/pre-commit-quality
  chmod +x .hk/pre-commit-quality
  q() { rm -f "$t/args"; .hk/pre-commit-quality; }
  echo ok >"a b.js"; echo BAD >skip.txt; git add "a b.js" skip.txt
  case_ "staged: filename with spaces"  allowed q
  grep -qx 'a b.js' "$t/args" 2>/dev/null && ! grep -q skip.txt "$t/args" || { fail=1; echo "❌ run_staged did not pass exactly 'a b.js'"; }
  git commit -q --no-verify -m s
  echo BAD >"a b.js"; git add "a b.js"
  case_ "staged: lint error blocks"     blocked q
  echo ok >"a b.js"
  case_ "staged: partially staged"      blocked q
  git add "a b.js"; git rm -q "a b.js"
  case_ "staged: deleted file skipped"  allowed q
  [ ! -f "$t/args" ] || { fail=1; echo "❌ run_staged passed a deleted file"; }
fi
exit $fail
