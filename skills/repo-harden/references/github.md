# GitHub adapter: `gh api` recipes per checklist item

`R=<owner/repo>`, `B=<default branch>`. Every ruleset PUT sends the **whole** ruleset: GET it, change only what is needed with `jq`, and strip the read-only fields.

```bash
strip='del(.id,.node_id,.source,.source_type,.created_at,.updated_at,._links,.current_user_can_bypass)'
```

## merge.squash
```bash
gh api -X PATCH repos/$R \
  -F allow_squash_merge=true -F allow_merge_commit=false -F allow_rebase_merge=false \
  -f squash_merge_commit_title=PR_TITLE -f squash_merge_commit_message=PR_BODY \
  -F delete_branch_on_merge=true -F allow_auto_merge=true -F allow_update_branch=true
```

## secrets.scanning
Send only the keys that are `missing` with a plain status (e.g. `disabled`). A key whose detail starts with `unavailable` cannot be enabled: it needs the fallback instead (a secret-scanner job in a `pull_request` workflow, such as gitleaks, made a required check on the default branch, plus `hooks.secrets`); once that is in place the audit reports it `n/a` (fallback covered). On private/internal repos, secret scanning requires GitHub Secret Protection. Generic (non-provider) patterns exist only on organization-owned repos: on a user-owned repo GitHub reports them `disabled` and a PATCH returns 200 without enabling them (silent refusal). If the API refuses, report the exact error and point to Settings → Code security.
```bash
jq -n '{security_and_analysis:{
  secret_scanning:{status:"enabled"},
  secret_scanning_non_provider_patterns:{status:"enabled"},
  secret_scanning_push_protection:{status:"enabled"}}}' \
| gh api -X PATCH repos/$R --input -
gh api -X PUT repos/$R/automated-security-fixes      # dependabot_security_updates
```

## protect.branch — ruleset `default-branch: protection`
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

## review.bot — ruleset `default-branch: copilot review`
A separate ruleset, so that a refusal (no Copilot plan) never touches `protect.branch`. Copilot code review needs a Copilot plan (Pro, Pro+, Business or Enterprise) for the ruleset creator, and each automatic review needs the PR author to have Copilot code review access and credits left; otherwise the review is skipped, not failed. Re-read the ruleset after the POST: a missing rule is a silent refusal.
```json
{
  "name": "default-branch: copilot review",
  "target": "branch",
  "enforcement": "active",
  "conditions": {"ref_name": {"include": ["~DEFAULT_BRANCH"], "exclude": []}},
  "rules": [{"type": "copilot_code_review", "parameters": {"review_on_push": true, "review_draft_pull_requests": false}}],
  "bypass_actors": []
}
```
Alternative chosen in the go-ahead (or the fallback when Copilot is refused): CodeRabbit. The user installs the GitHub App (https://github.com/apps/coderabbitai) on the repo, which the agent cannot do; the PR adds a `.coderabbit.yaml` with `reviews.auto_review.enabled: true`. The audit then reports `verify` until you confirm the App is installed (`gh api repos/$R/installation` returns 404 for user tokens, so check that a CodeRabbit review shows up on this run's PR).

## protect.tags — ruleset `tags: release`
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
Add the `creation` rule (`{"type": "creation"}`, so only Admin creates release tags) unless the user declined it in the go-ahead. If a workflow or App creates the tags (release-please, semantic-release, changesets), add it to `bypass_actors` (an App as `Integration` with its app id; `GITHUB_TOKEN` workflows cannot bypass, so they need an App or a deploy key) before enabling the rule. Otherwise the next release fails.

## protect.signed — ruleset `default-branch: signed commits`
On by default, unless the user declined it. A separate ruleset, so turning it off never touches `protect.branch`. GitHub checks **every commit a PR brings in**: unsigned commits on the head branch block the merge, squash included, even though the squash commit itself is signed by GitHub. Commits created by GitHub (web UI, API, Dependabot, `GITHUB_TOKEN` API calls) are signed; commits a bot makes with `git commit` + `git push` (e.g. semantic-release with `@semantic-release/git`) are not.

Preconditions, in order:
1. The user signs their own commits. Check `git config --get commit.gpgsign` (`true`) and `git config --get user.signingkey`, then that the latest own commit shows as verified:
   ```bash
   gh api repos/$R/commits/<sha> --jq '.commit.verification | {verified, reason}'
   ```
   If not, do not create the ruleset: mark the item pending, and give the user the setup to run (never done by you; adding the key needs the `admin:ssh_signing_key` scope):
   ```bash
   git config --global gpg.format ssh
   git config --global user.signingkey ~/.ssh/id_ed25519.pub
   git config --global commit.gpgsign true
   git config --global tag.gpgsign true
   gh ssh-key add ~/.ssh/id_ed25519.pub --type signing --title "$(hostname) signing"
   ```
2. This run's PR is already merged (§6), so its own commits cannot block it.
3. Every release tool or App in the `protect.branch` bypass list that pushes commits signs them, or is copied to this ruleset's `bypass_actors`.

```json
{
  "name": "default-branch: signed commits",
  "target": "branch",
  "enforcement": "active",
  "conditions": {"ref_name": {"include": ["~DEFAULT_BRANCH"], "exclude": []}},
  "rules": [{"type": "required_signatures"}],
  "bypass_actors": []
}
```
Re-read the ruleset after the POST: a missing rule is a silent refusal. In the report, tell the user that other contributors must sign before opening PRs, with the setup above.

## publish.env — publish environment restricted to release tags
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

## Plan limits (private repos on GitHub Free)
Rulesets, classic branch protection, tag protection and environment branch policies return `403 Upgrade to GitHub Pro or make this repository public`. The audit marks them `n/a`. Report the limit, keep `hooks.protect-branch` as the only branch guard, and offer the options (make public, upgrade, accept the gap). Dependabot, CI and pinned actions still work. **Skip `automerge`**: auto-merge is unavailable there, and its checklist condition (required CI checks) cannot be met.

## classic-protection
If classic branch protection exists, show its content and carry every rule the ruleset lacks into it (required checks, approvals, linear history). Then delete it with `gh api -X DELETE repos/$R/branches/$B/protection`, unless the user chose "keep" or "leave alone" in the go-ahead. Delete only after the ruleset GET shows the migrated rules.

## Final validation
```bash
gh api repos/$R/rules/branches/$B --jq '.[] | {type, parameters}'
gh api repos/$R/dependabot/alerts --jq '[.[] | select(.state=="open")] | length'
gh api repos/$R/secret-scanning/alerts --jq '.[] | {number, secret_type_display_name, state, created_at}'
```
Non-provider pattern alerts only appear after the next scan, so an empty list is not a problem.
