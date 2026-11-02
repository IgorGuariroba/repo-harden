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
