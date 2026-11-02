---
name: repo-harden
description: Audit a repository against a security hardening checklist and apply only what is missing, within the user's permissions — branch and tag protection, squash-only merges, required CI with actions pinned by SHA, Dependabot/Renovate with CI-gated auto-merge of security fixes, Trusted Publishing (OIDC) to npm/PyPI/crates.io, secret scanning, and local git hooks that block direct commits to main. Stack-agnostic (Node, Python, Go, Rust built in; others researched). Full automation on GitHub; on GitLab and other hosts, or without admin rights, applies local protections and writes maintainer recommendations. Use when the user asks to harden, secure, protect or audit a repo, set up branch protection, rulesets, Dependabot auto-merge or OIDC publishing. Pass "check" to audit only.
license: MIT
compatibility: Requires git, bash and jq. GitHub automation needs gh authenticated with repo admin; other hosts use their CLI/API when available.
metadata:
  author: IgorGuariroba
  version: "2.0.0"
---

# repo-harden

The checklist in `references/checklist.md` defines each item as a **goal plus acceptance criterion**. Mechanisms vary by platform and stack; the criterion does not. Every run goes **audit → plan → apply only the diff, within scope → re-audit**. It is idempotent: on a compliant repository it changes nothing.

Paths are relative to this skill's directory. Talk to the user in their language.

| Reference | Read when |
|---|---|
| `references/checklist.md` | always, before planning |
| `references/ecosystems.md` | the audit reports any ecosystem |
| `references/github.md` | platform is `github` |
| `references/other-platforms.md` | platform is anything else |

## 1. Audit
1. Confirm a git repository with a clean working tree (`git status --porcelain` empty). If it is dirty, ask before continuing.
2. Run `scripts/audit.sh` from the repository root and show its output as a table (item, status, detail).
   - Statuses: `ok`, `missing`, `drift`, `n/a`, `manual`, `verify`, `info`.
   - The `platform` row gives the **scope**: `local`, `repo-write` or `admin`.
   - The `ecosystems` row lists the detected stacks.
3. Resolve every `verify` row yourself: the ecosystem's audit tool, the CI config of another platform, the Renovate config, and the scope on a non-GitHub host (`references/other-platforms.md` §1). Each row ends as a concrete status.

If the argument is `check`, report and **stop here**.

## 2. Plan and confirmation
Place every non-`ok` item in one of three buckets, using the scope column in the checklist:
- **apply locally**: `hooks.*`, `deps.vulns`;
- **apply via PR**: files, when scope ≥ `repo-write`;
- **apply via API**: settings, when scope is `admin`;
- **recommend to maintainers**: everything beyond scope or unavailable on the plan.

Show the buckets and ask for a **single go-ahead**. Include these decisions in the same question:
- publishing candidates marked `?`: is the project meant to be published, and to which registry?
- `hooks.secrets`: which scanner, if any is installed;
- legacy branch protection: migrate it into the ruleset and remove it?
- the `creation` rule on the tag ruleset;
- an existing hook manager (husky, lefthook, pre-commit, simple-git-hooks): integrate into it;
- on a repo the user does not own: commit the hooks, or keep them local-only?

## 3. Apply locally
- **Hooks:** with a hook manager, add the check from `assets/githooks/` to that manager's hook. Without one, copy `assets/githooks/*` to `.githooks/`, run `chmod +x` and `git config core.hooksPath .githooks`, and document the activation command in the `prepare` script or the README. An existing hook keeps its content, with the check added at its top. Validate with `scripts/test-hooks.sh <hooks-dir>`; all 6 cases must pass.
- **`hooks.secrets`:** a `pre-commit` step running the chosen scanner on staged changes, and only if the scanner is installed. Do not install system tools without asking.
- **`deps.vulns`:** use the ecosystem's audit/fix tool (`references/ecosystems.md`), staying within semver-compatible fixes. Report leftovers with their advisory IDs.

## 4. Apply via PR (scope ≥ repo-write)
Create the branch `chore/repo-harden` from the up-to-date default branch.

**Writing files:**
- For each detected ecosystem, apply its profile from `references/ecosystems.md`. An unlisted ecosystem gets a profile you research and fill in with the same columns.
- Templates in `assets/` are Node/GitHub examples. Keep their invariants and swap only the stack-specific steps:
  - **CI:** read-only token, `persist-credentials: false`, a fixed job `name:` (the ruleset requires that literal name), the project's real validation commands.
  - **Publish:** release-triggered, `environment:`, `id-token: write`, tag ∈ default-branch history, tag == `v` + version, no registry token secrets.
  - **Auto-merge:** `pull_request_target`, no checkout, `security-patch-minor` + patch/minor only, `--match-head-commit`. Install it only when `protect.branch` will require the CI checks.
- Pin actions with `scripts/pin-action.sh <owner/action>...`.
- Fill every `{{PLACEHOLDER}}`. Done when `grep -r '{{' .github` is empty.
- A file in `drift` gets a **targeted fix** and keeps the rest of its content.

**Validating, then opening the PR:**
1. Run the validation commands locally.
2. Commit (`chore: harden repository`) and push the branch.
3. Open the PR with the platform CLI.

Skip this step when no file item is pending.

## 5. Apply via API (scope = admin)
- **GitHub:** `references/github.md`, in this order: `merge.squash`, `secrets.scanning`, `publish.env`, `protect.tags`, `protect.branch`.
- **Other platforms:** `references/other-platforms.md` §2. Show each call before running it.

Add required checks only after CI has run on the PR, and take the exact check names from the real check-runs. Wait with `gh pr checks <n> --watch --fail-fast`, the platform equivalent, or your harness's background watch.

An API refusal (plan, license, visibility) does not abort the run: record the exact error, mark the item `n/a`, apply the documented fallback, and continue.

## 6. Merge and re-audit
1. With checks green, squash-merge the PR and wait for CI on the default branch.
2. Update the local default branch.
3. Re-run `scripts/audit.sh`.

**Done** when every item is `ok`, `n/a`, `manual`, or a maintainer recommendation with its reason recorded.

## 7. Report
1. Table of item × before × after × how (local / PR / API / recommendation / n/a reason).
2. Files changed and the PR link.
3. What merges on its own: only bot PRs in `security-patch-minor` with semver patch/minor, after green CI. Everything else waits for review.
4. **Manual steps that need the user's 2FA** (never run them yourself): register the trusted publisher on each registry (`references/ecosystems.md`), make the first manual publish where the registry requires it, and afterwards disallow token publishing and revoke old tokens.
5. **Maintainer recommendations**, as one block ready to paste into an issue or MR.
6. Release flow (bump version, tag `v<version>`, create release) and how to undo the hooks (`git config --unset core.hooksPath`; one-off bypass with `ALLOW_MAIN=1` or `--no-verify`).

## Guardrails
- Touch only this run's own `chore/repo-harden` branch and PR. Leave publishing, tags and other PRs alone. Hook tests run only in `/tmp`, via `scripts/test-hooks.sh`.
- Server-side changes stay within the scope the audit measured. Anything beyond it becomes a recommendation.
- Workflows triggered by bots or `pull_request_target` never check out or execute PR code.
- Changes reach the default branch **only through a PR**.
