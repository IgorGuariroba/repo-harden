# Ecosystem profiles

`audit.sh` prints `ecosystems: ...` from marker files. For each detected ecosystem use its profile below. For an ecosystem **not listed** (Ruby, Java, PHP, .NET, Elixir, Dart, Docker…), build the profile yourself from the registry's and Dependabot/Renovate's current docs, filling the same columns. Registry facts drift, so re-check the docs before writing a publish job.

| Field | Node | Python | Go | Rust |
|---|---|---|---|---|
| Markers | `package.json` | `pyproject.toml`, `setup.py`, `requirements*.txt`, `Pipfile`, `uv.lock` | `go.mod` | `Cargo.toml` |
| Dependabot `package-ecosystem` | `npm` | `uv` if `uv.lock`, else `pip` | `gomod` | `cargo` |
| Vulnerability audit (exit ≠ 0 on findings) | `npm audit` / `npm audit fix` (never `--force`) | `pip-audit` (or `uvx pip-audit`) | `govulncheck ./...` | `cargo audit` (or `cargo deny check advisories`) |
| CI setup action | `actions/setup-node` (`cache: npm`) | `actions/setup-python` or `astral-sh/setup-uv` | `actions/setup-go` (`go-version-file: go.mod`) | `rustup` is preinstalled on GitHub runners; cache optional |
| Install + validation | `npm ci` + scripts `typecheck`/`lint`/`test`/`build` | `uv sync` / `pip install -e .[dev]` + `pytest`, `ruff`, `mypy` if configured | `go vet ./...`, `go test ./...` | `cargo fmt --check`, `cargo clippy -- -D warnings`, `cargo test` |
| Publishable when | `private` is not `true` | `[project]` table in `pyproject.toml` + PyPI name exists or is intended | never (Go modules are fetched from VCS; skip `publish.*`) | `publish` is not `false` in `Cargo.toml` |
| Trusted Publishing | npm: GitHub Actions, GitLab.com CI, CircleCI cloud (no self-hosted runners); needs npm ≥ 11.5.1; provenance automatic | PyPI: GitHub, GitLab, Google Cloud, ActiveState; `pypa/gh-action-pypi-publish` (attestations on by default) | n/a | crates.io: GitHub Actions; `rust-lang/crates-io-auth-action` → output `token` → `CARGO_REGISTRY_TOKEN` |
| Publish environment | `npm` | `pypi` | n/a | `crates-io` |
| Registry-side registration (user 2FA) | `npm trust github <name> --file <wf> --repo <R> --env npm --allow-publish --yes --otp=<code>` or npmjs.com → Settings → Trusted Publisher | pypi.org → project → Publishing → add GitHub publisher (owner, repo, workflow, environment); a "pending publisher" works before the first release | n/a | crates.io → crate → Settings → Trusted Publishing; the first version has to be published manually with a token |
| Version source for tag check | `package.json` `.version` | `pyproject.toml` `[project].version` (dynamic versions: read from the build backend) | git tag itself | `Cargo.toml` `[package].version` |

## Publish job skeleton (any registry)
Start from `assets/workflows/publish-npm.yml` and keep its invariants: trigger `release: published`, skip prereleases, `environment: <publish env>`, `permissions: {contents: read, id-token: write}`, checkout of the release tag with `persist-credentials: false`, tag ∈ default-branch history, tag == `v` + version, validation before publish, no registry token secrets. Swap only the setup/build/publish steps:

- **Python**: build with `uv build` or `python -m build`, then `pypa/gh-action-pypi-publish` (pinned SHA).
- **Rust**: `cargo publish --dry-run`, then the auth action `id: auth` and `cargo publish` with `CARGO_REGISTRY_TOKEN: ${{ steps.auth.outputs.token }}`.

## Monorepos
One Dependabot `updates` entry per ecosystem **per directory** containing a manifest (`directories:` with globs is allowed). Validation runs per package or via the workspace tool.
