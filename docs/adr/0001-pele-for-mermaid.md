# Render Mermaid diagrams with Pele

**Status:** accepted

Glance renders Mermaid syntax in Markdown fences, and previously bundled
Mermaid.js 11.17.2 (3.57 MB). We replaced it with Pele 1.9.0 (706 KB), which
supports every diagram type built into Mermaid 12.1.0 and renders synchronously
to SVG with no dependencies. The trade-off is that Pele uses its own layout
engine: node spacing, edge paths, and visual style differ from Mermaid, Mermaid
themes do not apply, and arbitrary HTML labels are unsupported. We accepted
those differences for the smaller, faster runtime and kept the existing
`mermaid` fence syntax and trusted sentinel so document authors do not change
anything.

## Considered options

- Keep Mermaid.js: exact Mermaid layout, but a 3.57 MB runtime and slower
  rendering.
- Switch to Pele: about 80% smaller, faster, and still covers every built-in
  Mermaid 12.1.0 diagram type, with visual differences.

## Consequences

The diagram tests and runtime documentation pin Pele rather than Mermaid.
Math labels show TeX unless a resolver is added later. Reverting to Mermaid is
possible but would undo the bundle-size reduction and require restoring the
old runtime and tests.
