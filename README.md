# repo-harden

An [Agent Skill](https://agentskills.io) that audits a repository against a security hardening checklist and **applies only what is missing, within your permissions**. Run it again on a compliant repo and nothing changes.

```bash
npx skills add IgorGuariroba/repo-harden
```

Then ask your agent: *"harden this repo"*, or *"repo-harden check"* to audit only.

## Agnostic by design

The checklist is a set of **goals with acceptance criteria** ([`checklist.md`](skills/repo-harden/references/checklist.md)), not a fixed recipe. The agent picks the mechanism that fits the repo:

| Axis | Coverage |
|---|---|
| **Agent** | any agent that supports Agent Skills and can run shell commands (Claude Code, Codex, Cursor, Gemini CLI, OpenCode, Pi…) |
| **Stack** | built-in profiles for Node, Python, Go and Rust; other ecosystems are detected and the agent researches their tooling |
| **Platform** | full automation on **GitHub**; on GitLab, Bitbucket, Azure DevOps or self-hosted Git, it uses the platform CLI when you have admin rights |
| **Permissions** | as admin, everything is applied; with write access, changes go through a PR; with clone-only access, it applies local hooks and writes a **maintainer recommendation** block for the rest |

## Checklist

| Item | Goal |
|---|---|
| `hooks.protect-branch` | `pre-commit`/`pre-push` block direct commits and pushes to `main`/`master` |
| `hooks.secrets` | pre-commit secret scan (gitleaks, detect-secrets…), on by default |
| `hooks.hygiene` | pre-commit blocks unresolved conflict markers and new files above 500 KB (Git LFS skipped) |
| `hooks.quality` | fast pre-commit lint/format on staged files only (partial staging handled), pre-push typecheck/tests, with the project's own tools |
| `hooks.installed` | declared hooks are really active (`pre-commit install`, `default_install_hook_types`, husky/lefthook) and a fresh clone can activate them |
| `deps.vulns` | 0 known vulnerabilities (`npm audit`, `pip-audit`, `govulncheck`, `cargo audit`…) |
| `deps.bot` | Dependabot/Renovate for every ecosystem + CI actions + `pre-commit` hooks, security fixes grouped |
| `ignore.git` | `.gitignore` covers secrets, dependencies and the outputs the build really produces |
| `ignore.docker` | `.dockerignore` keeps `.git`, `.env` and local dependencies out of every build context |
| `ignore.publish` | published packages ship only what they need (`files` allowlist, `npm pack --dry-run`) |
| `ci.pipeline` | CI on every PR with a fixed job name and read-only token |
| `ci.pinned` | third-party actions and `pre-commit` hooks pinned by full commit SHA, no `@latest` installs |
| `ci.pr-title` | with a commit convention, CI validates the PR title (the squash commit message) instead of a `commit-msg` hook |
| `automerge` | security patch/minor bot PRs auto-merge **only after CI is green**, never running PR code |
| `publish.oidc` | Trusted Publishing (npm, PyPI, crates.io) with provenance, no long-lived tokens |
| `publish.env` | publish credentials reachable only from `v*` tags |
| `merge.squash` | squash-only merges with PR title/body |
| `protect.branch` | no deletion or force push, PR required, required checks with strict policy |
| `protect.tags` | release tags cannot be deleted, moved or force-pushed |
| `protect.signed` | verified signatures required on the default branch (on by default, after the user's own commits are verified) |
| `review.bot` | Copilot code review (ruleset) or CodeRabbit on every PR, advisory only |
| `secrets.scanning` | secret scanning, generic patterns and push protection (CI fallback where unavailable) |

Plan limits are detected and reported. For example, a private repo on GitHub Free has no rulesets, so it gets hooks plus a recommendation.

## Run the audit without an agent

```bash
bash ~/.agents/skills/repo-harden/scripts/audit.sh | column -t -s $'\t'
```

Requirements: `git`, `bash`, `jq`; `gh` for GitHub automation.

---

## 🇧🇷 Português

Skill para agentes de código que audita um repositório contra um checklist de segurança e **aplica só o que falta, dentro das suas permissões**. O checklist é definido por objetivos e critérios de aceite, então funciona com qualquer agent, qualquer stack (Node, Python, Go e Rust prontos; outras são pesquisadas pelo agent) e qualquer plataforma. No GitHub, a automação é completa. Sem acesso de admin (por exemplo, num GitLab da empresa), ela aplica os hooks locais e gera recomendações prontas para os mantenedores.

```bash
npx skills add IgorGuariroba/repo-harden
```

## License

MIT
