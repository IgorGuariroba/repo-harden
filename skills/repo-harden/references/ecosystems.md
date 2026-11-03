# Ecosystem profiles

`audit.sh` prints `ecosystems: ...` from marker files. For each detected ecosystem use its profile below. For an ecosystem **not listed** (Ruby, Java, PHP, .NET, Elixir, Dart, Docker…), build the profile yourself from the registry's and Dependabot/Renovate's current docs, filling the same columns. Registry facts drift, so re-check the docs before writing a publish job.

| Field | Node | Python | Go | Rust |
|---|---|---|---|---|
| Markers | `package.json` | `pyproject.toml`, `setup.py`, `requirements*.txt`, `Pipfile`, `uv.lock` | `go.mod` | `Cargo.toml` |
| Dependabot `package-ecosystem` | `npm` | `uv` if `uv.lock`, else `pip` | `gomod` | `cargo` |
| Vulnerability audit (exit ≠ 0 on findings) | `npm audit` / `npm audit fix`; no installable deps (only `peerDependencies`) → `n/a`; deps without a lockfile → `audit.sh` audits a lockfile generated in a temp copy (fix by raising ranges in `package.json`) | `pip-audit` (or `uvx pip-audit`) | `govulncheck ./...` | `cargo audit` (or `cargo deny check advisories`) |
| Secret scanner (`hooks.secrets` default) | `gitleaks` (`gitleaks git --staged`); via the hook manager when there is one, else the system package manager | `detect-secrets` as a dev dependency or a `pre-commit` framework hook (`detect-secrets-hook --baseline .secrets.baseline`) | `gitleaks` (`gitleaks git --staged`); system package manager or `go install github.com/zricethezav/gitleaks/v8@v<X.Y.Z>` (latest release tag, never `@latest`) | `gitleaks` (`gitleaks git --staged`); system package manager |
| Quality hooks (`hooks.quality`) | `pre-commit`: `lint-staged`/`nano-staged` if configured, else the project's own linter/formatter on staged files (`npx --no-install eslint`, `biome check --staged`, `prettier --check`); `pre-push`: `npm run typecheck` / `npm test` when those scripts exist | `pre-commit`: `ruff check` + `ruff format --check` (or `black --check`/`flake8`) on staged `*.py`, via the `pre-commit` framework when the repo uses it; `pre-push`: `pytest`, `mypy`/`pyright` if configured | `pre-commit`: `gofmt -l` on staged `*.go` (fail if output), `golangci-lint run --new-from-rev=HEAD` if configured; `pre-push`: `go vet ./...` + `go test ./...` | `pre-commit`: `cargo fmt --check`; `pre-push`: `cargo clippy -- -D warnings` + `cargo test` |
| Ignore baseline (`ignore.git`; build outputs come from running the build) | `node_modules/`, `dist/`, `build/`, `coverage/`, `*.tsbuildinfo`, `.npm/`, `*.log` | `__pycache__/`, `*.py[cod]`, `.venv/`, `.pytest_cache/`, `.ruff_cache/`, `.mypy_cache/`, `dist/`, `build/`, `*.egg-info/`, `.coverage` | the `go build` binary, `coverage.out`, `*.test`; `vendor/` only when the repo does not vendor | `/target` (keep `Cargo.lock` versioned) |
| `.dockerignore` extras (`ignore.docker`) | `node_modules`, `npm-debug.log` | `.venv`, `__pycache__` | built binaries | `target` |
| Package contents (`ignore.publish`) | `files` allowlist in `package.json`; check with `npm pack --dry-run` | `[tool.hatch.build]`/`MANIFEST.in`/`[tool.setuptools]` includes; check the sdist with `tar tzf dist/*.tar.gz` | n/a | `include`/`exclude` in `Cargo.toml`; check with `cargo package --list` |
| CI setup action | `actions/setup-node` (`cache: npm`) | `actions/setup-python` or `astral-sh/setup-uv` | `actions/setup-go` (`go-version-file: go.mod`) | `rustup` is preinstalled on GitHub runners; cache optional |
| Install + validation | `npm ci` + scripts `typecheck`/`lint`/`test`/`build` | `uv sync` / `pip install -e .[dev]` + `pytest`, `ruff`, `mypy` if configured | `go vet ./...`, `go test ./...` | `cargo fmt --check`, `cargo clippy -- -D warnings`, `cargo test` |
| Publishable when | `private` is not `true` | `[project]` table in `pyproject.toml` + PyPI name exists or is intended | never (Go modules are fetched from VCS; skip `publish.*`) | `publish` is not `false` in `Cargo.toml` |
| Trusted Publishing | npm: GitHub Actions, GitLab.com CI, CircleCI cloud (no self-hosted runners); needs npm ≥ 11.5.1; provenance automatic | PyPI: GitHub, GitLab, Google Cloud, ActiveState; `pypa/gh-action-pypi-publish` (attestations on by default) | n/a | crates.io: GitHub Actions; `rust-lang/crates-io-auth-action` → output `token` → `CARGO_REGISTRY_TOKEN` |
| Publish environment | `npm` | `pypi` | n/a | `crates-io` |
| Registry-side registration (user 2FA) | `npm trust github <name> --file <wf> --repo <R> --env npm --allow-publish --yes --otp=<code>` or npmjs.com → Settings → Trusted Publisher | pypi.org → project → Publishing → add GitHub publisher (owner, repo, workflow, environment); a "pending publisher" works before the first release | n/a | crates.io → crate → Settings → Trusted Publishing; the first version has to be published manually with a token |
| Version source for tag check | `package.json` `.version` | `pyproject.toml` `[project].version` (dynamic versions: read from the build backend) | git tag itself | `Cargo.toml` `[package].version` |

## Hook managers
Use the manager the repo already has; without one, plain hooks in `.githooks/` (`assets/githooks/`). Hook versions are pinned like actions (`ci.pinned`) and kept fresh by `deps.bot`.

| Manager | Staged files at `pre-commit` (`hooks.quality`) | Hygiene (`hooks.hygiene`) | Activation (`hooks.installed`) | Pinning |
|---|---|---|---|---|
| none (`.githooks/`) | `run_staged '<cmd>' '<pathspec>'...` from `assets/githooks/staged.sh` (copied next to the hooks, sourced by `pre-commit`) | built into `assets/githooks/pre-commit` | `git config core.hooksPath .githooks`, in the `prepare` script (Node) or the README | tools come from the project's own dependencies |
| `pre-commit` framework | filenames are passed by default: never `pass_filenames: false` on a lint hook; `stages: [pre-push]` for tests | `check-merge-conflict` + `check-added-large-files` (`args: [--maxkb=500]`) from `pre-commit/pre-commit-hooks`; the branch guard as a `repo: local` hook with `always_run: true` | `default_install_hook_types: [pre-commit, pre-push]` in the config, `pre-commit install` in the README; refuses to install while `core.hooksPath` is set | `pre-commit autoupdate --freeze` (`rev: <sha>  # frozen: vX.Y.Z`); Dependabot `package-ecosystem: pre-commit` updates SHA and comment; Renovate's `pre-commit` manager is opt-in and does not rewrite the `# frozen:` comment, so report that gap |
| husky + lint-staged | `npx lint-staged` in `.husky/pre-commit` (stashes unstaged changes itself) | add the two checks from `assets/githooks/pre-commit` to `.husky/pre-commit` | `"prepare": "husky"` in `package.json` | npm devDependencies (`deps.bot` npm) |
| lefthook | `run: <cmd> {staged_files}` (never `{all_files}`) with `glob:`; `stage_fixed: true` only for fixers | a `pre-commit` command running the two checks from `assets/githooks/pre-commit` | npm package installs on `postinstall`; otherwise `lefthook install` in the README | the npm/Go dependency; remote configs pinned by `ref` |
| simple-git-hooks | `npx lint-staged` | the two checks in the `pre-commit` command | `"prepare": "simple-git-hooks"` (or `postinstall`) | npm devDependencies |

## Publish job skeleton (any registry)
Start from `assets/workflows/publish-npm.yml`, keep its `# INVARIANTS` header, and swap only the setup/build/publish steps. The trigger is a go-ahead decision: with `push: tags ['v*']`, take the tag from `github.ref_name` and drop the `prerelease` guard. If the repo already has a publish workflow with an `environment:`, reuse that environment name and do not use the one from the table.

- **Unlisted ecosystem:** the secret scanner defaults to `gitleaks`; the ignore baseline starts from its template in [github/gitignore](https://github.com/github/gitignore), and the build in a `/tmp` copy decides the rest.

- **Python**: build with `uv build` or `python -m build`, then `pypa/gh-action-pypi-publish` (pinned SHA).
- **Rust**: `cargo publish --dry-run`, then the auth action `id: auth` and `cargo publish` with `CARGO_REGISTRY_TOKEN: ${{ steps.auth.outputs.token }}`.

## Monorepos
One Dependabot `updates` entry per ecosystem **per directory** containing a manifest (`directories:` with globs is allowed). Validation runs per package or via the workspace tool.
