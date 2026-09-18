# Domain docs

This repository uses a single-context domain-documentation layout.

## Before exploring

Read these files when they exist:

- `CONTEXT.md` at the repository root
- ADRs under `docs/adr/` that affect the area being changed

If these files do not exist, proceed silently. Do not suggest creating them upfront. The `/domain-modeling` skill creates them when the project resolves terms or architectural decisions.

## File structure

```text
/
├── CONTEXT.md
├── docs/
│   └── adr/
│       ├── 0001-example-decision.md
│       └── 0002-another-decision.md
└── project sources
```

## Use the glossary's vocabulary

When an issue, proposal, hypothesis, or test names a domain concept, use the term defined in `CONTEXT.md`. Do not substitute terms the glossary explicitly avoids.

If a needed concept is missing, reconsider whether the term belongs to the project. If it does, note the gap for `/domain-modeling`.

## Flag ADR conflicts

Call out any proposal that contradicts an existing ADR instead of silently overriding the decision:

> Contradicts ADR-0007, but worth reopening because...
