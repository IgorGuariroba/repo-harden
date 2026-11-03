# Hardening checklist (platform- and stack-neutral)

Each item is a **goal** plus an **acceptance criterion**. The criterion is what counts; the mechanism is whatever the platform and stack offer. `audit.sh` uses these IDs; a row `<id>:<ecosystem>` or `<id>/<setting>` is a sub-item of `<id>` and shares its criterion (`scripts/test-checklist-ids.sh` keeps the two in sync). When a platform or stack has no native mechanism, look up its current docs, pick the closest equivalent, and record the gap in the report.

Scope column: **local** = works with plain clone access; **repo-write** = needs push/PR rights; **admin** = needs repository admin; **registry** = needs the user's own registry account and 2FA (never done by the agent).

| ID | Goal | Acceptance criterion | Scope |
|---|---|---|---|
| `hooks.protect-branch` | Nobody commits or pushes straight to the default branch by accident | `pre-commit` and `pre-push` block `main`/`master` (and `feat:main`, deletes); `ALLOW_MAIN=1` bypasses; `scripts/test-hooks.sh` exits 0 | local |
| `hooks.secrets` | Secrets are caught before they leave the machine | `pre-commit` runs a secret scanner (gitleaks, trufflehog, detect-secrets…) on staged changes; on by default (installed if missing), the user may decline in the go-ahead | local |
| `deps.vulns` | No known vulnerable dependency ships | the ecosystem's audit tool reports 0 (fix without forced major bumps; report leftovers) | local |
| `deps.bot` | Dependencies and CI actions get update PRs | Dependabot or Renovate config covers **every** detected ecosystem plus the CI actions ecosystem; security updates grouped as `security-patch-minor` (patch/minor) | repo-write |
| `ci.pipeline` | Every change is validated before merge | a pipeline on PR/MR and on the default branch runs install + the project's validation (test, typecheck, lint, build); read-only token; job has a **fixed name** | repo-write |
| `ci.pinned` | CI cannot be hijacked through a moved tag | every third-party action/image/component is pinned to a full commit SHA/digest with the version in a comment | repo-write |
| `automerge` | Security fixes land without waiting, but only when CI is green | bot PRs in the scope chosen in the go-ahead (default: `security-patch-minor` with semver patch/minor; never major) get auto-merge; the job never checks out or runs PR code; guarded by repo name and same-repo head; **install only when `protect.branch` requires the CI checks** (otherwise auto-merge merges before CI) | repo-write |
| `publish.oidc` | Releases are published without long-lived tokens | publish job uses the registry's Trusted Publishing / OIDC (`id-token`), no registry token secrets, provenance/attestations when the registry supports it, tag validated against the version and the default branch history | repo-write |
| `publish.npm-repository` | npm provenance links the package to this repository | `package.json` `repository.url` is `git+https://<host>/<owner>/<repo>.git` for this repo (npm only) | repo-write |
| `publish.registry` | The registry trusts only this repo's publish workflow | a trusted publisher (workflow + environment) is registered for the package on each target registry; afterwards token publishing is disallowed and old tokens revoked | registry |
| `publish.env` | Only release tags can reach the publish credentials | publish job uses a deployment environment restricted to the release tag pattern (`v*`) | admin |
| `merge.squash` | Linear, readable history | squash is the only merge method; squash commit = PR title + body; branches deleted after merge; "update branch" enabled; auto-merge allowed | admin |
| `protect.branch` | The default branch only changes through validated PRs | no deletion, no force push, PR required (0 approvals for solo devs), squash only, required checks = CI job name(s), strict/up-to-date policy; admin bypass only through PR | admin |
| `protect.tags` | Published releases cannot be rewritten | release tags cannot be deleted, moved or force-pushed; admin bypass; tag creation restricted to admin and the detected release tool, unless the user declined | admin |
| `secrets.scanning` | Leaked secrets are detected and blocked server-side | secret scanning + generic (non-provider) patterns + push protection + automatic security updates enabled; where the platform lacks it, a required CI job running a secret scanner is the fallback | admin |
| `review.bot` | Every PR gets an automated code review before merge | the default branch requests an automated reviewer on every PR and push: Copilot code review through a `copilot_code_review` ruleset rule with `review_on_push`, or a review App (CodeRabbit…) installed and configured in the repo; advisory only, never counted as an approval; reviewer chosen in the go-ahead | admin |
| `classic-protection` | One source of truth for branch rules | no legacy branch protection overlapping the ruleset (migrated and removed by default, unless the user declined) | admin |

## Out-of-reach items
When an item exceeds the user's scope, leave it unapplied and add a **maintainer recommendation** to the report: what to enable, where, and why, in a form the user can forward (issue/MR description).
