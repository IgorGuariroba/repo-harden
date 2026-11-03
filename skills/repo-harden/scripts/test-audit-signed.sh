#!/usr/bin/env bash
# protect.signed rows of audit.sh against a stubbed `gh` (no network).
# Covers: the rule in its own ruleset or inside the protection ruleset, an evaluate-only ruleset,
# no rule (missing), rulesets unavailable (n/a), and that a signatures-only ruleset
# is not mistaken for the branch protection ruleset.
# Usage: test-audit-signed.sh   (exits 0 when every case passes)
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
signed='[{"type":"required_signatures"}]'

# case <name> <id> <expected-status> <detail-regex> <rulesets-json|upgrade> [<enforcement>:<rules-json>]...
case_() {
  local name=$1 key=$2 want=$3 rx=$4 list=$5; shift 5
  local repo="$tmp/$name" FX="$tmp/$name.fx" i=0 ids="[]" spec enf rules
  mkdir -p "$repo" "$FX"
  git -C "$repo" init -q -b main && git -C "$repo" remote add origin https://github.com/o/r.git
  for spec in "$@"; do
    enf=${spec%%:*}; rules=${spec#*:}
    i=$((i + 1)); ids=$(jq -c --argjson i $i '. + [{id:$i}]' <<<"$ids")
    jq -n --argjson i $i --arg e "$enf" --argjson r "$rules" '{id:$i,target:"branch",enforcement:$e,conditions:{ref_name:{include:["~DEFAULT_BRANCH"]}},
      bypass_actors:[{actor_id:5,actor_type:"RepositoryRole",bypass_mode:"pull_request"}],rules:$r}' >"$FX/ruleset-$i.json"
  done
  if [ "$list" = upgrade ]; then echo '{"message":"Upgrade to GitHub Pro or make this repository public to enable this feature."}' >"$FX/rulesets.json"
  else echo "$ids" >"$FX/rulesets.json"; fi
  jq -n '{default_branch:"main",visibility:"public",owner:{type:"User"},permissions:{admin:true},security_and_analysis:{}}' >"$FX/meta.json"
  local line got
  line=$(cd "$repo" && PATH="$tmp/bin:$PATH" FX="$FX" "$audit" 2>/dev/null | grep -P "^$key\t")
  got=$(cut -f2 <<<"$line")
  if [ "$got" = "$want" ] && grep -qE "$rx" <<<"$line"; then echo "ok   $name"
  else echo "FAIL $name: expected $want /$rx/, got: ${line:-<no row>}"; fail=1; fi
}

both=$(jq -c --argjson s "$signed" '. + $s' <<<"$protect")
case_ separate-ruleset   protect.signed ok      'ruleset=2'            list "active:$protect" "active:$signed"
case_ same-ruleset       protect.signed ok      'ruleset=1'            list "active:$both"
case_ evaluate-only      protect.signed missing 'no active'            list "active:$protect" "evaluate:$signed"
case_ nothing            protect.signed missing 'commit.gpgsign='      list "active:$protect"
case_ no-rulesets        protect.signed n/a     'rulesets unavailable' upgrade
case_ protect-not-copied protect.branch ok      'ruleset=1'            list "active:$protect" "active:$signed"
case_ only-signed        protect.branch missing 'no ruleset'           list "active:$signed"

exit $fail
