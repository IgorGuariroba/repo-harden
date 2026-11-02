# repo-harden

Vocabulary of the repo-harden skill: how a run audits a repository and agrees with the user on what to change.

## Language

**Decision**:
A choice the skill puts to the user in the plan's single go-ahead question; every Decision has a Default.
_Avoid_: option, question, setting

**Default**:
The recommended answer to a Decision, applied whenever the user does not choose another one (a bare "ok" applies every Default).
_Avoid_: fallback, assumption

**Invariant**:
A property declared in a template's `# INVARIANTS` header or a checklist criterion; it is never asked and never changed per run.
_Avoid_: rule, constraint, default

**Fallback**:
The substitute mechanism that satisfies a checklist item's acceptance criterion when the platform's native feature is unavailable.
_Avoid_: workaround, alternative, default

**Covered**:
An unavailable setting whose Fallback is in place, so the item needs no further action and reports `n/a`.
_Avoid_: compliant, satisfied

**Silent refusal**:
A platform call that reports success but leaves the setting unchanged, because the feature is unavailable for that repository.
_Avoid_: silent failure, no-op, ignored PATCH
