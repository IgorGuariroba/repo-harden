#!/usr/bin/env bash
# review.bot rows of audit.sh against a stubbed `gh` (no network).
# Covers: Copilot rule in its own ruleset or inside the protection ruleset, review_on_push drift,
# a CodeRabbit config (verify), nothing configured (missing), and that a review-only ruleset
# is not mistaken for the branch protection ruleset.
# Usage: test-audit-review.sh   (exits 0 when every case passes)
set -u
audit="$(cd "$(dirname "$0")" && pwd)/audit.sh"
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
fail=0

# gh stub: answers from $FX/*.json; anything else is a 404
mkdir -p "$tmp/bin"
cat >"$tmp/bin/gh" <<'STUB'
#!/usr/bin/env bash
[ "$1" = api ] || exit 1
case $2 in
  repos/o/r) f=meta ;;
  repos/o/r/rulesets\?*) f=rulesets ;;
  repos/o/r/rulesets/*) f="ruleset-${2##*/}" ;;
  repos/o/r/branches/*) echo '{"message":"Branch not protected"}'; exit 1 ;;
  *) echo '{"message":"Not Found","status":"404"}'; exit 1 ;;
esac
cat "$FX/$f.json"
STUB
chmod +x "$tmp/bin/gh"

protect='[{"type":"deletion"},{"type":"non_fast_forward"},{"type":"pull_request","parameters":{"allowed_merge_methods":["squash"]}},{"type":"required_status_checks","parameters":{"strict_required_status_checks_policy":true,"required_status_checks":[{"context":"CI"}]}}]'
copilot() { printf '[{"type":"copilot_code_review","parameters":{"review_on_push":%s,"review_draft_pull_requests":false}}]' "$1"; }

# case <name> <coderabbit?> <id> <expected-status> <detail-regex> <rules-json>...  (one ruleset per rules-json)
case_() {
  local name=$1 cr=$2 key=$3 want=$4 rx=$5; shift 5
  local repo="$tmp/$name" FX="$tmp/$name.fx" i=0 ids="[]"
  mkdir -p "$repo" "$FX"
  git -C "$repo" init -q -b main && git -C "$repo" remote add origin https://github.com/o/r.git
  [ "$cr" = yes ] && echo 'reviews: {}' >"$repo/.coderabbit.yaml" && git -C "$repo" add .coderabbit.yaml
  for rules in "$@"; do
    i=$((i + 1)); ids=$(jq -c --argjson i $i '. + [{id:$i}]' <<<"$ids")
    jq -n --argjson i $i --argjson r "$rules" '{id:$i,target:"branch",enforcement:"active",conditions:{ref_name:{include:["~DEFAULT_BRANCH"]}},
      bypass_actors:[{actor_id:5,actor_type:"RepositoryRole",bypass_mode:"pull_request"}],rules:$r}' >"$FX/ruleset-$i.json"
  done
  echo "$ids" >"$FX/rulesets.json"
  jq -n '{default_branch:"main",visibility:"public",owner:{type:"User"},permissions:{admin:true},security_and_analysis:{}}' >"$FX/meta.json"
  local line got
  line=$(cd "$repo" && PATH="$tmp/bin:$PATH" FX="$FX" "$audit" 2>/dev/null | grep -P "^$key\t")
  got=$(cut -f2 <<<"$line")
  if [ "$got" = "$want" ] && grep -qE "$rx" <<<"$line"; then echo "ok   $name"
  else echo "FAIL $name: expected $want /$rx/, got: ${line:-<no row>}"; fail=1; fi
}

case_ separate-ruleset   no  review.bot     ok      'ruleset=2'          "$protect" "$(copilot true)"
case_ same-ruleset       no  review.bot     ok      'ruleset=1'          "$(jq -c --argjson c "$(copilot true)" '. + $c' <<<"$protect")"
case_ no-review-on-push  no  review.bot     drift   'review_on_push'     "$protect" "$(copilot false)"
case_ coderabbit         yes review.bot     verify  'CodeRabbit'         "$protect"
case_ nothing            no  review.bot     missing 'no copilot'         "$protect"
case_ protect-not-copied no  protect.branch ok      'ruleset=1'          "$protect" "$(copilot true)"

exit $fail
