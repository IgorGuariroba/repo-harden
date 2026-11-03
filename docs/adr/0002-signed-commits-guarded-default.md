# 0002 — `protect.signed` is on by default, behind preconditions

Status: accepted (v3.4.0)

## Context
ADR 0001 makes every Default the recommended option. Requiring signed commits on the default branch is recommended, but GitHub checks every commit a PR brings in: unsigned commits on the head branch block the merge, squash included, even though GitHub signs the squash commit. Turned on blindly, the rule would block this run's own PR, the user (if they do not sign yet) and every bot that pushes with `git`.

## Decision
- `protect.signed` is a Decision with Default **on**, like the rest; the user may decline it in the go-ahead.
- It lives in its own ruleset (`default-branch: signed commits`), so removing it never touches `protect.branch`.
- It is applied only in §6, after this run's PR is merged, and only once the user's own commits show as verified. If they do not, the item stays pending and the report gives the signing setup; the run never configures keys itself.
- The report warns that every other contributor must sign before opening PRs.

## Alternatives considered
- **Off by default (opt-in)**: no surprise for contributors, but it leaves repos under-hardened, against ADR 0001.
- **On without preconditions**: blocks the run's own PR and can lock the user out of merging.
- **Add the rule to the `protect.branch` ruleset**: one ruleset fewer, but turning signatures off would mean editing the main protection.

## Consequences
- Contributors without signing are blocked from merging until they configure it; the report says so.
- Release tools that push commits with `git` must sign them or be added to the ruleset's bypass list.
