# 0001 — A bare go-ahead applies the recommended default of every Decision

Status: accepted (v3.0.0)

## Context
In §2 (plan), the skill asked for a single go-ahead and bundled several Decisions into it, with no default for any of them. A bare "ok" left the agent choosing alone. In one real run it picked the publish trigger, the environment, the `creation` rule, the scanner and the auto-merge scope by itself, and the user later reversed two of those choices. Some of those choices were not even listed as Decisions: they were frozen in templates as Invariants.

## Decision
- Every Decision has a Default, and the go-ahead question shows it as `[default: …]`.
- A reply that does not choose applies every Default. "ok, but X=Y" overrides only X.
- A Default is the **recommended** option, not the most conservative one. Publishing, the `creation` rule, removal of legacy protection, committing hooks on third-party repos and installing the secret scanner are **on** by default, and the user has to turn them off explicitly.
- The publish trigger and the auto-merge scope became Decisions. The tag validation, the per-ecosystem environment name and "never auto-merge major" remain Invariants.

## Alternatives considered
- **Conservative defaults** (off unless confirmed): safer when the user answers without reading, but they leave repos under-hardened and turn every run into a negotiation.
- **Bare "ok" approves only the buckets** and keeps Decisions pending: one more round-trip, and that is exactly the friction the single go-ahead exists to avoid.

## Consequences
- This is a breaking change for users who relied on "ok" being harmless: hence the major version bump.
- The guardrail "ask before installing any system tool" now has one exception, the `hooks.secrets` scanner.
- The `creation` rule depends on the audit detecting the release tool, otherwise the next release breaks.
