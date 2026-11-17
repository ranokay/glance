# Pele runtime

Glance bundles Pele 1.13.0 for offline Mermaid-diagram rendering in Markdown.
The source asset is the npm package's `dist/pele.global.js`, downloaded from
<https://registry.npmjs.org/pele/-/pele-1.13.0.tgz>; its SHA-256 digest
is `0b0a46c57a5a6971670c09f5ec4066705bd78505f90fd11adf6260325efa0910`.
`PELE_LICENSE.txt` is included beside the runtime in the Quick Look extension;
its SHA-256 digest is
`311bccc30de6f7b9cbfb64232bb0c911ccb2191abe316550813ae25b2c7925b9`.

Pele replaces Mermaid.js 11.17.2. The bundled runtime is 733,670 bytes versus
3,572,661 bytes for Mermaid, a reduction of 2,838,991 bytes in the Quick Look
extension resources (Pele 1.10.0 was 709,352 bytes). Pele supports every diagram type built into Mermaid
12.1.0. It uses its own layout engine, so node positions, spacing, and edge
paths differ from Mermaid, and Mermaid themes or `themeVariables` do not apply.
Arbitrary HTML labels are unsupported. Math labels show their TeX source
unless a math resolver is supplied; Glance does not supply one.

PreviewCore emits `<!--glance-renderer-mermaid-v1-->` only for parsed Mermaid
fences. Swift loads the runtime only when that trusted marker is present. The
render script calls `pele.render` with `links: false`, `images: false`, a
unique `idPrefix`, and the preview width as `maxWidth`. Colors and fonts come
from `--pele-*` CSS variables in `markdown-main.css`. The preview content
security policy sets `connect-src 'none'`; this bump did not change it. If
rendering fails, the escaped source block remains visible.

## Release-size impact

Measured Release bundles on Apple silicon. The historical Mermaid 11.17.2
measurement was `Glance.app` 13,205,504 bytes and `QLPlugin.appex` 11,423,744
bytes. The 1.9.1 Release build, which also includes the Draw.io, KaTeX, and Rust
dependency updates, measures `Glance.app` 21,298,757 bytes and `QLPlugin.appex`
16,990,461 bytes.
The runtime swap's direct contribution is the 2,838,991-byte resource reduction
above, isolated from those other branch changes. The 1.13.0 bump adds 24,318
bytes to the bundled runtime (733,670 vs 709,352).
