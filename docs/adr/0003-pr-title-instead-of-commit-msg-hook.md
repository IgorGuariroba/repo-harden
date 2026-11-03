# 0003 — The commit convention is enforced on the PR title, not with a `commit-msg` hook

Status: accepted (v3.6.0)

## Context
A common pre-commit setup adds a `commit-msg` hook (commitlint, commitizen) to enforce Conventional Commits. With `merge.squash`, every PR lands as one commit whose message is the PR title plus the PR body, so the messages of the commits inside the PR branch never reach the default branch. A `commit-msg` hook would check messages that get thrown away, could be skipped with `--no-verify`, and does not see commits made in the web UI or by bots.

## Decision
- When the repo has a convention (commitlint/commitizen/release tool config, or ≥ 80 % of the last 20 subjects are Conventional Commits), `ci.pr-title` adds a `pull_request` workflow that validates the PR title, and its check joins the required checks.
- The skill never installs a `commit-msg` hook. An existing one is kept.
- The workflow runs with no checkout and no token, and receives the title through `env:`, because the title is untrusted input.

## Alternatives considered
- **`commit-msg` hook**: catches the problem earlier on the dev's machine, but it checks the wrong message under squash merges and can be bypassed.
- **Both**: twice the configuration for no extra guarantee on the default branch.
- **A third-party action** (`amannn/action-semantic-pull-request`): more features, but one more pinned dependency to review. A shell `grep` against the repo's own types is enough for the invariant.

## Consequences
- Repos without squash-only merges (where `merge.squash` was declined or is out of scope) get the title check anyway. Their merge commits still carry branch commit messages, so the report should note the gap.
- The allowed types must follow the repo's commitlint/commitizen config when there is one, not the template's default list.
