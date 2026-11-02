# repo-harden

An [Agent Skill](https://agentskills.io) that audits a GitHub repository against a security hardening checklist and **applies only what is missing**. Run it again on a compliant repo and nothing changes.

```bash
npx skills add IgorGuariroba/repo-harden
```

Then ask your agent: *"harden this repo"*, or *"repo-harden check"* to audit only.

## What it checks and applies

| Area | Items |
|---|---|
| Dependencies | `npm audit` at 0, `dependabot.yml` (npm + github-actions, `security-patch-minor` group) |
| CI | workflow on `pull_request`/`push`, fixed job name, actions pinned by full commit SHA |
| Auto-merge | `pull_request_target` workflow that **never checks out PR code**, merges only Dependabot npm security patch/minor after green CI |
| Publishing | npm Trusted Publishing (OIDC) with provenance, no `NPM_TOKEN`, tag validated against `package.json` and the default branch |
| Environment | publish environment deployable only from `v*` tags |
| Branch ruleset | no deletion, no force push, PR required (0 approvals), squash only, required checks with strict up-to-date policy, admin bypass via PR |
| Tag ruleset | `refs/tags/v*` cannot be deleted, moved or force-pushed |
| Repo settings | squash-only merges with PR title/body, delete branch on merge, auto-merge, "Update branch" button |
| Secret scanning | secret scanning, non-provider patterns, push protection, Dependabot security updates |
| Local hooks | `pre-commit`/`pre-push` blocking direct commits and pushes to `main`/`master` (integrates with husky/lefthook if present) |

## How it works

1. **Audit:** `scripts/audit.sh` is a deterministic, read-only check that prints `ok` / `missing` / `drift` per item.
2. **Plan:** the agent lists what will change and asks once for confirmation (and for ambiguous cases, like existing classic branch protection).
3. **Files go through a PR** on `chore/repo-harden`, using templates whose actions get pinned to the latest release SHA.
4. **Settings** are applied via `gh api`, patching only the diff and preserving existing rulesets and environments.
5. **Merge and re-audit**, then a before/after report plus the manual steps that need your 2FA (`npm trust`).

Requirements: `git`, `gh` (authenticated, repo admin), `jq`, `bash`.

You can run the audit without an agent:

```bash
bash ~/.agents/skills/repo-harden/scripts/audit.sh | column -t -s $'\t'
```

---

## 🇧🇷 Português

Skill para agentes de código que audita um repositório do GitHub contra um checklist de segurança e **aplica só o que falta**: Dependabot com auto-merge protegido por CI, actions fixadas por SHA, publicação no npm via OIDC, rulesets de branch e de tag, merge só por squash, secret scanning e hooks locais que bloqueiam commit e push direto na `main`.

```bash
npx skills add IgorGuariroba/repo-harden
```

Depois peça ao agente: *"faça o hardening deste repo"*, ou *"repo-harden check"* para só auditar. Mudanças de arquivo vão por PR; passos que exigem 2FA (`npm trust`) ficam para você.

## License

MIT
