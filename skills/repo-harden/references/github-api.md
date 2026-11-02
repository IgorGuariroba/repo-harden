# `gh api` recipes per item

`R=<owner/repo>`, `B=<default branch>`. Every ruleset PUT sends the **whole** ruleset: GET it, change only what is needed with `jq`, and strip the read-only fields.

```bash
strip='del(.id,.node_id,.source,.source_type,.created_at,.updated_at,._links,.current_user_can_bypass)'
```

## repo.* — squash-only merges, auto-merge, update branch
```bash
gh api -X PATCH repos/$R \
  -F allow_squash_merge=true -F allow_merge_commit=false -F allow_rebase_merge=false \
  -f squash_merge_commit_title=PR_TITLE -f squash_merge_commit_message=PR_BODY \
  -F delete_branch_on_merge=true -F allow_auto_merge=true -F allow_update_branch=true
```

## sec.* — Dependabot security updates and secret scanning
Send only the keys that are `missing`. On private/internal repos, secret scanning requires GitHub Secret Protection. If the API refuses, report the exact error and point to Settings → Code security.
```bash
jq -n '{security_and_analysis:{
  secret_scanning:{status:"enabled"},
  secret_scanning_non_provider_patterns:{status:"enabled"},
  secret_scanning_push_protection:{status:"enabled"}}}' \
| gh api -X PATCH repos/$R --input -
gh api -X PUT repos/$R/automated-security-fixes      # dependabot_security_updates
```

## ruleset.branch — `default-branch: protection`
Check `context` and `integration_id`: take them from the check-runs of the latest green commit on the default branch, or of this run's PR.
```bash
gh api repos/$R/commits/<sha>/check-runs --jq '.check_runs[] | {name, app_id: .app.id, conclusion}'
# GitHub Actions = 15368
```
Full ruleset (create with POST to `repos/$R/rulesets`; update with PUT to `repos/$R/rulesets/<id>`, keeping any extra rules that already exist):
```json
{
  "name": "default-branch: protection",
  "target": "branch",
  "enforcement": "active",
  "conditions": {"ref_name": {"include": ["~DEFAULT_BRANCH"], "exclude": []}},
  "rules": [
    {"type": "deletion"},
    {"type": "non_fast_forward"},
    {"type": "pull_request", "parameters": {
      "required_approving_review_count": 0,
      "dismiss_stale_reviews_on_push": false,
      "require_code_owner_review": false,
      "require_last_push_approval": false,
      "required_review_thread_resolution": false,
      "allowed_merge_methods": ["squash"]}},
    {"type": "required_status_checks", "parameters": {
      "strict_required_status_checks_policy": true,
      "do_not_enforce_on_create": false,
      "required_status_checks": [{"context": "Tests (Node 24)", "integration_id": 15368}]}}
  ],
  "bypass_actors": [{"actor_id": 5, "actor_type": "RepositoryRole", "bypass_mode": "pull_request"}]
}
```
Fixing an existing ruleset without losing anything:
```bash
gh api repos/$R/rulesets/$ID | jq "$strip"' |
  (.rules[] | select(.type=="pull_request") | .parameters.allowed_merge_methods) = ["squash"] |
  (.rules[] | select(.type=="required_status_checks") | .parameters.strict_required_status_checks_policy) = true' \
| gh api -X PUT repos/$R/rulesets/$ID --input -
```
No CI: omit `required_status_checks` and tell the user. The check name must be **identical** to the job's `name:`.

## ruleset.tags — `tags: release`
```json
{
  "name": "tags: release",
  "target": "tag",
  "enforcement": "active",
  "conditions": {"ref_name": {"include": ["refs/tags/v*"], "exclude": []}},
  "rules": [{"type": "deletion"}, {"type": "non_fast_forward"}, {"type": "update"}],
  "bypass_actors": [{"actor_id": 5, "actor_type": "RepositoryRole", "bypass_mode": "always"}]
}
```
The `creation` rule (only Admin creates release tags) is **optional**. Propose it and apply only after confirmation. If a workflow or App creates the tags (release-please, semantic-release, changesets), it must be added to the bypass list.

## env.* — publish environment restricted to release tags
```bash
# 1) PUT keeping existing reviewers and wait_timer
gh api repos/$R/environments/$ENV 2>/dev/null | jq '{
  wait_timer: ((.protection_rules // [])[] | select(.type=="wait_timer") | .wait_timer) // 0,
  reviewers: [((.protection_rules // [])[] | select(.type=="required_reviewers") | .reviewers[] | {type, id: .reviewer.id})],
  deployment_branch_policy: {protected_branches:false, custom_branch_policies:true}}' \
| gh api -X PUT repos/$R/environments/$ENV --input -
# if the environment does not exist yet, the GET fails: use only
#   jq -n '{deployment_branch_policy:{protected_branches:false,custom_branch_policies:true}}' | gh api -X PUT ... --input -
# 2) tag policy
gh api -X POST repos/$R/environments/$ENV/deployment-branch-policies -f name='v*' -f type=tag
# 3) remove branch policies
gh api repos/$R/environments/$ENV/deployment-branch-policies --jq '.branch_policies[] | select(.type=="branch") | .id' \
| xargs -r -I{} gh api -X DELETE repos/$R/environments/$ENV/deployment-branch-policies/{}
```
On a **private** repo on the Free plan, environments with policies may be unavailable. In that case, report it and move on.

## classic-protection
If classic branch protection exists, show its content and ask whether to migrate it into the ruleset and delete it (`gh api -X DELETE repos/$R/branches/$B/protection`). Delete only after confirmation.

## Final validation
```bash
gh api repos/$R/rules/branches/$B --jq '.[] | {type, parameters}'
gh api repos/$R/dependabot/alerts --jq '[.[] | select(.state=="open")] | length'
gh api repos/$R/secret-scanning/alerts --jq '.[] | {number, secret_type_display_name, state, created_at}'
```
Non-provider pattern alerts only appear after the next scan, so an empty list is not a problem.
