# Glossary

Minimal by design: terms are recorded here only once they have crystallized
through use. Architecture records stay lazy — written only for hard-to-reverse
or surprising trade-offs.

- **slice**: one audit-scoped, independently-revertible refactor unit
  (locked order in #46, executed in #49). A slice moves code without changing
  behavior, carries its own verification gate, and reverts as one commit.
- **archive entry**: one file or directory listed inside an archive.
- **archive entry preview**: a preview of an archive entry without extracting
  the whole archive.
- **menu-bar-only**: an app reachable only through its status item, with no
  Dock icon or main window.
- **spreadsheet preview**: a values-only rendering of a workbook’s worksheets.
