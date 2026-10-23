# Pele runtime

Glance bundles Pele 1.9.0 for offline Mermaid-diagram rendering in Markdown.
The source asset is the npm package's `dist/pele.global.js`; its SHA-256 digest
is `323c16de7844d4b609743f70449ebce041a531e4f48f23b1e9e7ec9d3b917287`.
`PELE_LICENSE.txt` is included beside the runtime in the Quick Look extension;
its SHA-256 digest is
`311bccc30de6f7b9cbfb64232bb0c911ccb2191abe316550813ae25b2c7925b9`.

Pele replaces Mermaid.js 11.17.2. The bundled runtime is 706,153 bytes versus
3,572,661 bytes for Mermaid, a reduction of 2,866,508 bytes in the Quick Look
extension resources. Pele supports every diagram type built into Mermaid
12.1.0. It uses its own layout engine, so node positions, spacing, and edge
paths differ from Mermaid, and Mermaid themes or `themeVariables` do not apply.
Arbitrary HTML labels are unsupported. Math labels show their TeX source
unless a math resolver is supplied; Glance does not supply one.

PreviewCore emits `<!--glance-renderer-mermaid-v1-->` only for parsed Mermaid
fences. Swift loads the runtime only when that trusted marker is present. The
render script calls `pele.render` with `links: false`, `images: false`, a
unique `idPrefix`, and the preview width as `maxWidth`. Colors and fonts come
from `--pele-*` CSS variables in `markdown-main.css`. The preview content
security policy sets `connect-src 'none'`. If rendering fails, the escaped
source block remains visible.

## Release-size impact

Measured locally at this branch's release build (macOS 27.2, Xcode 27.0,
arm64): `Glance.app` is 16,042,603 bytes and `QLPlugin.appex` is 12,415,638
bytes. The runtime swap's direct contribution is the 2,866,508-byte resource
reduction above; the rest of the bundle includes the XLSX and archive-entry
preview code on this branch.
