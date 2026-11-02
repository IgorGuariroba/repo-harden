#!/usr/bin/env bash
# Resolves the latest release of an action and prints a SHA-pinned reference.
# Usage: pin-action.sh actions/checkout [actions/setup-node ...]
# Output: actions/checkout@<sha40> # v7.0.1
set -euo pipefail
for a in "$@"; do
  tag=$(gh api "repos/$a/releases/latest" --jq .tag_name)
  ref=$(gh api "repos/$a/git/ref/tags/$tag")
  sha=$(jq -r .object.sha <<<"$ref")
  if [ "$(jq -r .object.type <<<"$ref")" = tag ]; then   # annotated tag: dereference
    sha=$(gh api "repos/$a/git/tags/$sha" --jq .object.sha)
  fi
  echo "$a@$sha # $tag"
done
