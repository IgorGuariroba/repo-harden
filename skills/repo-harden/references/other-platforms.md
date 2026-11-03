# Platforms without a built-in adapter

Only GitHub has tested recipes (`references/github.md`). On GitLab, Bitbucket, Azure DevOps, Gitea/Forgejo or an unknown host, work from the goals and acceptance criteria in `references/checklist.md`.

## 1. Establish scope before planning
Find out what the user can actually change. Use the platform CLI (`glab`, `bb`, `az repos`, `tea`) or its REST API with the user's existing auth, and read only:
- GitLab: `glab api projects/<url-encoded path>` → `permissions.project_access.access_level` / `group_access` (50 = Owner, 40 = Maintainer, 30 = Developer).
- Others: the equivalent "my permission on this repo" endpoint.

When the CLI is missing, unauthenticated, or the user is below maintainer/admin, treat the scope as **local** and skip to step 3.

## 2. With maintainer/admin scope
For each server-side item, look up the platform's **current** docs for the mechanism that meets the acceptance criterion, then show the user the exact calls before running them. Known starting points (verify, they drift):

| Item | GitLab | Bitbucket Cloud | Azure DevOps |
|---|---|---|---|
| `protect.branch` | protected branches + "Pipelines must succeed" + squash setting | branch restrictions + merge checks | branch policies (build validation, merge types) |
| `protect.tags` | protected tags | — (recommend instead) | — |
| `protect.signed` | push rule "Reject unsigned commits" (Premium) | — (recommend instead) | — (recommend instead) |
| `merge.squash` | project merge method + squash option "Require" | default merge strategy | branch policy "limit merge types" |
| `deps.bot` | Renovate (or GitLab dependency scanning on paid tiers) | Renovate | Renovate or Dependabot via extension |
| `secrets.scanning` | Secret Detection CI template; push protection on Ultimate | CI job with gitleaks | GHAS for Azure DevOps or CI job |
| `publish.oidc` | `id_tokens` with registry audience (npm, PyPI support GitLab.com shared runners, not self-hosted) | OIDC exists; check each registry | check each registry |

Pin CI images by digest and `include:`/components by SHA to satisfy `ci.pinned`.

## 3. Local scope: apply local, recommend the rest
- Apply `hooks.protect-branch` (and `hooks.secrets` if the user agrees). Both are local and need no permission. They live in the user's clone; commit them only if the user owns the repo conventions, otherwise keep them untracked (e.g. `core.hooksPath` pointing to a directory listed in `.git/info/exclude`).
- Run `deps.vulns` locally and report the findings; fixing dependencies is a normal code change that goes through the team's MR flow.
- For every other item, write a **maintainer recommendation**: goal, concrete setting on that platform (with doc link), and the risk it closes. Group them into one block the user can paste into an issue or MR description.
