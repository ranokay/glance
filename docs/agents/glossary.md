# Glossary

Minimal by design: terms are recorded here only once they have crystallized
through use. Architecture records stay lazy — written only for hard-to-reverse
or surprising trade-offs.

- **slice**: one audit-scoped, independently-revertible refactor unit
  (locked order in #46, executed in #49). A slice moves code without changing
  behavior, carries its own verification gate, and reverts as one commit.
