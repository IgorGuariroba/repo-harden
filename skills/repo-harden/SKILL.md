---
name: repo-harden
description: Audit a GitHub repository against a security hardening checklist and apply whatever is missing — Dependabot with CI-gated auto-merge of security fixes, pinned-SHA CI, npm Trusted Publishing (OIDC + provenance), branch and tag rulesets, squash-only merges, secret scanning with push protection, and local git hooks blocking direct commits to main. Use when the user asks to harden, secure, protect or audit a GitHub repo, set up branch protection/rulesets, Dependabot auto-merge, or npm OIDC publishing. Pass "check" to audit only.
license: MIT
compatibility: Requires git, gh (authenticated, repo admin), jq and bash. Node/npm items apply only when package.json exists.
metadata:
  author: IgorGuariroba
  version: "1.0.0"
---

# repo-harden

Every checklist item goes **audit → apply only the diff → re-audit**. The run is idempotent: on a compliant repository it ends without changing anything.

Paths are relative to this skill's directory: `scripts/`, `assets/`, `references/github-api.md`. Talk to the user in their language.

## 1. Preconditions
Check each one before continuing. If any fails, stop and explain:
- git repository whose `origin` remote is on GitHub, and `gh auth status` succeeds;
- `gh api repos/<R> --jq .permissions.admin` is `true`;
- clean working tree (`git status --porcelain` is empty).

## 2. Audit
Run `scripts/audit.sh` from the repository root and show the result as a table (item, status, detail). Statuses: `ok`, `missing`, `drift`, `n/a`, `manual`, `info`.

If the argument is `check`, **stop here**.

## 3. Plan and confirmation
List every item that will change, grouped into **files (via PR)** and **GitHub settings**, and ask for a single go-ahead before applying anything. Raise these decisions in the same question:
- classic branch protection is active (migrate it to the ruleset and remove it?);
- `creation` rule on the tag ruleset (see `references/github-api.md`);
- existing publish workflow without `environment:`, more than one publish workflow, or a release tag pattern other than `v*`;
- a hook manager is already present (husky, lefthook, pre-commit, simple-git-hooks): confirm integrating into it;
- non-Node project: confirm the stack so the CI can be adapted.

## 4. File changes (on a branch, via PR)
Run `git switch -c chore/repo-harden` from an up-to-date default branch. For each `missing`/`drift` item:

| Item | Action |
|---|---|
| `npm.audit` | `npm audit fix` (never `--force`). Target is 0; report whatever remains. |
| `package.repository` | set `repository.url` to `git+https://github.com/<R>.git` (provenance fails otherwise) |
| `dependabot.yml` | `assets/dependabot.yml`; without `package.json`, keep only the `github-actions` block |
| `ci.workflow` | `assets/workflows/ci.yml` |
| `automerge.workflow` | `assets/workflows/dependabot-auto-merge.yml` |
| `publish.workflow` | `assets/workflows/publish.yml` (publishable packages only) |
| `actions.pinned` | replace each `uses:` with the output of `scripts/pin-action.sh <owner/action>` |
| `hooks.local` | see **Hooks** below |

**Template placeholders:**
- `{{REPO}}`, `{{DEFAULT_BRANCH}}`: from the audited repository.
- `{{CHECKOUT}}`, `{{SETUP_NODE}}`, `{{FETCH_METADATA}}`: output of `scripts/pin-action.sh actions/checkout actions/setup-node dependabot/fetch-metadata`.
- `{{NPM_VERSION}}`: `npm view npm version`, which must be ≥ 11.5.1.
- `{{VALIDATION_STEPS}}`: one `- run: npm run <s>` for each existing script among typecheck, lint, test and build (`npm test` for test).
- `npm pack --dry-run` stays only for publishable packages.

Done when `grep -r '{{' .github` is empty.

A file that already exists with status `drift` gets a **targeted fix**; never overwrite it with the template. The CI job keeps a fixed `name:` because the ruleset will require that literal name.

### Hooks
- With a hook manager: add the check from `assets/githooks/` to that manager's hook.
- Without one: copy `assets/githooks/*` to `.githooks/`, run `chmod +x` and `git config core.hooksPath .githooks`, and add `git config core.hooksPath .githooks` to the `prepare` script (if `package.json` exists) or to the README.
- Existing hook: put the check at its top and keep the rest intact.

Validate with `scripts/test-hooks.sh <hooks-dir>`. All 6 cases must pass.

Run the validation scripts locally (`npm ci` plus the validation scripts). Then commit (`chore: harden repository`), push the branch and run `gh pr create --fill`. The hooks allow pushes of work branches.

Skip this step if no file item was pending.

## 5. GitHub settings
Apply the recipes in `references/github-api.md` in this order:
1. `repo.*`
2. `sec.*`
3. `env.*`
4. `ruleset.tags`
5. `ruleset.branch`

For `ruleset.branch`, add `required_status_checks` only after CI has run on the PR (or already exists on the default branch). Take `context` and `integration_id` from the real check-runs. Wait for the PR checks with `gh pr checks <n> --watch --fail-fast`, or with your harness's background watch if it has one.

An API error (plan or license) does not abort the run: record the exact error and move to the next item.

## 6. Merge and close
- With the PR checks green: `gh pr merge <n> --squash --delete-branch`.
- Wait for the default-branch CI (`gh run watch <run-id> --exit-status`).
- `git switch <default> && git pull`.
- Re-run `scripts/audit.sh`.

**Done** when every item is `ok`, `n/a` or `manual`, or the remaining ones have a recorded reason (for example, a feature unavailable on the plan).

## 7. Report
1. Table of item × before × after.
2. Files created or changed, and the PR link.
3. **Auto-merge:** only Dependabot PRs in the `security-patch-minor` group (npm, semver patch/minor) merge on their own, after green CI. Major bumps, version updates and github-actions updates wait for review.
4. **Manual steps** (they need the user's 2FA, so never run them yourself):
   - package not published yet: first publish by hand with `npm publish --access public`;
   - register the trusted publisher: `npm trust github <name> --file publish.yml --repo <R> --env npm --allow-publish --yes --otp=<code>`, then verify with `npm trust list <name>`;
   - after the first OIDC publish: npmjs.com → package → Settings → Publishing access → "Require 2FA and disallow tokens", and revoke old tokens.
5. Release flow: `npm version patch && git push --follow-tags && gh release create v<version> --generate-notes`.
6. Undo hooks: `git config --unset core.hooksPath`. One-off bypass: `ALLOW_MAIN=1` or `--no-verify`.

## Guardrails
- Leave the publish workflow, tags, PRs and pushes untouched except for this run's own `chore/repo-harden` PR. Hook tests run only in `/tmp`, via `scripts/test-hooks.sh`.
- The auto-merge workflow never checks out or executes PR code.
- Changes reach the default branch **only through a PR**.
