---
name: repo-harden
description: Harden a repository's security setup — audit it against a checklist and apply only what is missing, within the user's permissions. Use when asked to harden, secure or audit a repo, or to set up git hooks (branch guard, secret scan, lint/test), branch/tag protection, automated PR review (Copilot, CodeRabbit), Dependabot auto-merge or Trusted Publishing (OIDC). Pass "check" to audit only.
license: MIT
compatibility: Requires git, bash and jq. GitHub automation needs gh authenticated with repo admin; other hosts use their CLI/API when available.
metadata:
  author: IgorGuariroba
  version: "3.3.0"
---

# repo-harden

The checklist in `references/checklist.md` defines each item as a **goal plus acceptance criterion**. Mechanisms vary by platform and stack; the criterion does not. Every run goes **audit → plan → apply only the diff, within scope → re-audit**. It is idempotent: on a compliant repository it changes nothing.

Paths are relative to this skill's directory.

| Reference | Read when |
|---|---|
| `references/checklist.md` | always, before planning |
| `references/ecosystems.md` | the audit reports any ecosystem |
| `references/github.md` | platform is `github` |
| `references/other-platforms.md` | platform is anything else |

## 1. Audit
1. Confirm a git repository with a clean working tree (`git status --porcelain` empty). If it is dirty, ask before continuing.
2. Run `scripts/audit.sh` from the repository root and show its output as a table (item, status, detail).
   - Statuses: `ok`, `missing`, `drift`, `n/a`, `verify` (you resolve it), `manual` (needs the user, e.g. 2FA on a registry), `info` (context only).
   - The `platform` row gives the **scope**: `local`, `repo-write` or `admin`.
   - The `ecosystems` row lists the detected stacks.
3. Resolve every `verify` row yourself: the ecosystem's audit tool, the CI config of another platform, the Renovate config, and the scope on a non-GitHub host (`references/other-platforms.md` §1). Each row ends as a concrete status.

If the argument is `check`, report and **stop here**.

## 2. Plan and confirmation
Place every non-`ok` item in one of four buckets, using the scope column in the checklist:
- **apply locally**: `hooks.*`, `deps.vulns`;
- **apply via PR**: files, when scope ≥ `repo-write`;
- **apply via API**: settings, when scope is `admin`;
- **recommend to maintainers**: everything beyond scope or unavailable on the plan.

Items with scope `registry` go to the report's manual 2FA steps (§7).

Show the buckets and ask for a **single go-ahead** that also lists every **decision** below, each with its default shown as `[default: …]`. Ask only the decisions that apply to this run.

A reply that does not choose ("ok", "go", "sim") applies **every default**. "ok, but X=Y" overrides only X. Defaults are the recommended choice, so the user has to turn an option off explicitly.

| Decision | Default | Alternatives |
|---|---|---|
| publish: candidates marked `?` | publish to the registry of each publishable ecosystem of the target repo; if none exists, skip `publish.*` (`n/a`) | do not publish |
| publish trigger | `release: published`, prereleases skipped | `push: tags ['v*']` |
| `hooks.quality` | `pre-commit` lint/format on staged files + `pre-push` typecheck/tests, with the project's own tools | `pre-commit` only; none |
| `hooks.secrets` scanner | the ecosystem's recommended scanner (`references/ecosystems.md`), installed project-locally, wired into `pre-commit` | another scanner; none |
| legacy branch protection | migrate it into the ruleset, then remove it | migrate and keep it; leave it alone |
| `creation` rule on the tag ruleset | on; the release tool the audit detected (release-please, semantic-release, changesets) goes to the bypass list | off |
| hooks on a repo the user does not own | commit them, and give the reason in the PR body | local-only |
| `review.bot` reviewer | Copilot code review (ruleset rule); if refused, recommend CodeRabbit | CodeRabbit (user installs the App); none |
| `automerge` scope | `security-patch-minor` with semver patch/minor | + any patch; + any patch/minor (major never) |

## 3. Apply locally
First create the branch `chore/repo-harden` from the up-to-date default branch; every file this run writes lands there.

- **Hooks:** with a hook manager (husky, lefthook, pre-commit, simple-git-hooks), add the check from `assets/githooks/` to that manager's hook. Without one, copy `assets/githooks/*` to `.githooks/`, run `chmod +x` and `git config core.hooksPath .githooks`, and document the activation command in the `prepare` script or the README. An existing hook keeps its content, with the check added at its top. Validate with `scripts/test-hooks.sh <hooks-dir>`; done when it exits 0.
- **`hooks.quality`:** take the commands from the project's own config (package scripts, `lint-staged`, `pyproject.toml`, `Makefile`, CI validation steps) and the ecosystem's profile in `references/ecosystems.md`. `pre-commit` gets the fast checks on staged files only; `pre-push` gets typecheck and tests. Skip a tool the project does not configure, and ask before adding a new one. Place the steps after the branch check. Done when a commit with a lint error is blocked in a `/tmp` copy of the repo, and the audit row is `ok`.
- **`hooks.secrets`:** a `pre-commit` step running the chosen scanner on staged changes. Unless the user declined, install the scanner first, project-locally when the ecosystem allows it (`references/ecosystems.md`). This is the only tool the run installs without asking separately.
- **`deps.vulns`:** use the ecosystem's audit/fix tool (`references/ecosystems.md`), staying within semver-compatible fixes. Report leftovers with their advisory IDs.

## 4. Apply via PR (scope ≥ repo-write)
**Writing files:**
- For each detected ecosystem, apply its profile from `references/ecosystems.md`. An unlisted ecosystem gets a profile you research and fill in with the same columns.
- Templates in `assets/` are Node/GitHub examples. Each workflow opens with an `# INVARIANTS` header: keep every invariant and swap only the stack-specific steps. Add `automerge` only under its checklist condition.
- Pin actions with `scripts/pin-action.sh <owner/action>...`.
- Fill every `{{PLACEHOLDER}}`. Done when `grep -r '{{' .github` is empty.
- A file in `drift` gets a **targeted fix** and keeps the rest of its content.

Done when every file item marked `missing` or `drift` has a change on the branch, and `deps.bot` covers every ecosystem in the `ecosystems` row.

**Validating, then opening the PR:**
1. Run the validation commands locally.
2. Commit (`chore: harden repository`) and push the branch.
3. Open the PR with the platform CLI.

Skip this step when no file item is pending.

## 5. Apply via API (scope = admin)
- **GitHub:** `references/github.md`, in this order: `merge.squash`, `secrets.scanning`, `publish.env`, `protect.tags`, `protect.branch`, `review.bot`, then `classic-protection` (only once the ruleset exists).
- **Other platforms:** `references/other-platforms.md` §2. Show each call before running it.

Add required checks only after CI has run on the PR, and take the exact check names from the real check-runs. Wait with `gh pr checks <n> --watch --fail-fast`, the platform equivalent, or your harness's background watch.

After each call, re-read the setting. A success response whose re-read value is unchanged is a **silent refusal**: treat it as a refusal and record `accepted but not applied: <key>=<value read>` as its error.

An API refusal (plan, license, visibility) does not abort the run: record the exact error, mark the item `n/a`, apply the documented fallback, and continue.

Done when every admin item is applied, or `n/a` with its exact error recorded.

## 6. Merge and re-audit
1. With checks green, squash-merge the PR and wait for CI on the default branch.
2. Update the local default branch.
3. Re-run `scripts/audit.sh`.

**Done** when every item is `ok`, `n/a`, `manual`, or a maintainer recommendation with its reason recorded.

## 7. Report
1. Table of item × before × after × how (local / PR / API / recommendation / n/a reason).
2. Files changed and the PR link.
3. What merges on its own: only bot PRs in the chosen `automerge` scope (never major), after green CI. Everything else waits for review.
4. **Manual steps that need the user's 2FA**, listed for the user to run (they are never run by you): register the trusted publisher on each registry (`references/ecosystems.md`), make the first manual publish where the registry requires it, and afterwards disallow token publishing and revoke old tokens.
5. **Maintainer recommendations**, as one block ready to paste into an issue or MR.
6. When `publish.oidc` was applied: the release flow (bump version, tag `v<version>`, create release).
7. How to undo the hooks (`git config --unset core.hooksPath`; one-off bypass with `ALLOW_MAIN=1` or `--no-verify`).

## Guardrails
- Touch only this run's own `chore/repo-harden` branch and PR. Leave publishing, tags and other PRs alone. Hook tests run only in `/tmp`, via `scripts/test-hooks.sh`.
- Ask before installing any system tool other than the `hooks.secrets` scanner covered by the go-ahead.
- Server-side changes stay within the scope the audit measured. Anything beyond it becomes a recommendation.
- Workflows triggered by bots or `pull_request_target` never check out or execute PR code.
- Changes reach the default branch **only through a PR**.
