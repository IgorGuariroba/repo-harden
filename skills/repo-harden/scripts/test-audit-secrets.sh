#!/usr/bin/env bash
# secrets.scanning rows of audit.sh against a stubbed `gh` (no network).
# Covers: user-owned repos report generic patterns as "disabled" (organization-only feature),
# and an unavailable setting is n/a only when the fallback (required secret-scanner job) is in place.
# Usage: test-audit-secrets.sh   (exits 0 when every case passes)
set -u
audit="$(cd "$(dirname "$0")" && pwd)/audit.sh"
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
fail=0

# gh stub: answers from $FX/*.json; anything else is a 404
mkdir -p "$tmp/bin"
cat >"$tmp/bin/gh" <<'EOF'
#!/usr/bin/env bash
[ "$1" = api ] || exit 1
case $2 in
  repos/o/r) f=meta ;;
  repos/o/r/automated-security-fixes) echo '{"enabled":true}'; exit 0 ;;
  repos/o/r/rulesets\?*) f=rulesets ;;
  repos/o/r/rulesets/*) f=ruleset ;;
  repos/o/r/branches/*) echo '{"message":"Branch not protected"}'; exit 1 ;;
  *) echo '{"message":"Not Found","status":"404"}'; exit 1 ;;
esac
cat "$FX/$f.json"
EOF
chmod +x "$tmp/bin/gh"

scan_wf='name: Secret scan
on:
  pull_request:
jobs:
  gitleaks:
    name: Secret scan (gitleaks)
    runs-on: ubuntu-latest
    steps:
      - uses: gitleaks/gitleaks-action@ff98106e4c7b2bc287b24eaf42907196329070c7'

# case <name> <owner_type> <sa-json> <scanner-workflow?> <required-checks-json|unavailable> <key> <status> [detail-regex]
case_() {
  local name=$1 owner=$2 sa=$3 wf=$4 req=$5 key=$6 want=$7 rx=${8:-}
  local repo="$tmp/$name" FX="$tmp/$name.fx"
  mkdir -p "$repo/.github/workflows" "$FX"
  git -C "$repo" init -q -b main && git -C "$repo" remote add origin https://github.com/o/r.git
  [ "$wf" = yes ] && printf '%s\n' "$scan_wf" >"$repo/.github/workflows/secrets.yml"
  jq -n --arg o "$owner" --argjson sa "$sa" '{default_branch:"main",visibility:"public",owner:{type:$o},permissions:{admin:true},security_and_analysis:$sa}' >"$FX/meta.json"
  if [ "$req" = unavailable ]; then
    echo '{"message":"Upgrade to GitHub Pro or make this repository public to enable this feature."}' >"$FX/rulesets.json"
  else
    echo '[{"id":1}]' >"$FX/rulesets.json"
    jq -n --argjson r "$req" '{id:1,target:"branch",enforcement:"active",conditions:{ref_name:{include:["~DEFAULT_BRANCH"]}},bypass_actors:[],
      rules:[{type:"required_status_checks",parameters:{strict_required_status_checks_policy:true,required_status_checks:[$r[]|{context:.}]}}]}' >"$FX/ruleset.json"
  fi
  local line
  line=$(cd "$repo" && PATH="$tmp/bin:$PATH" FX="$FX" "$audit" 2>/dev/null | grep -P "^secrets\.scanning/$key\t")
  local got; got=$(cut -f2 <<<"$line")
  if [ "$got" = "$want" ] && { [ -z "$rx" ] || grep -qE "$rx" <<<"$line"; }; then
    echo "ok   $name"
  else
    echo "FAIL $name: expected $want${rx:+ /$rx/}, got: ${line:-<no row>}"; fail=1
  fi
}

np=secret_scanning_non_provider_patterns
all_on='{"secret_scanning":{"status":"enabled"},"secret_scanning_non_provider_patterns":{"status":"disabled"},"secret_scanning_push_protection":{"status":"enabled"}}'

case_ user-no-fallback        User         "$all_on" no  '[]'                         $np missing 'organization-only.*fallback missing'
case_ user-fallback-required  User         "$all_on" yes '["Secret scan (gitleaks)"]' $np n/a     'fallback covered'
case_ user-fallback-optional  User         "$all_on" yes '["Lint"]'                   $np missing 'not required'
case_ org-disabled            Organization "$all_on" yes '["Secret scan (gitleaks)"]' $np missing '	disabled$'
case_ org-enabled             Organization '{"secret_scanning_non_provider_patterns":{"status":"enabled"}}' no '[]' $np ok
case_ private-no-rulesets     User         '{}'      yes unavailable                  secret_scanning n/a 'cannot be required'
case_ private-no-fallback     User         '{}'      no  unavailable                  secret_scanning_push_protection missing 'fallback missing'

exit $fail
