# Draw.io runtime

Glance bundles the official Draw.io 32.6.10 viewer for offline `.drawio` previews. The minified
runtime (`js/viewer.min.js` from `draw.war`) comes from the
[v32.6.10 release](https://github.com/jgraph/drawio/releases/tag/v32.6.10) and has SHA-256 digest
`c5ca831069b3a2cb4129f8581f807cb1c7d6a6b0c541b89976cc91c32df5a067`.
`DRAWIO_LICENSE.txt` is included beside the runtime under the Apache License, Version 2.0, and has
SHA-256 digest `43070e2d4e532684de521b885f385d0841030efa2b1a20bafb76133a5e1379c1`.

Glance accepts UTF-8, uncompressed `mxfile` and `mxGraphModel` documents up to 10 MB. Parsing and
validation run away from the main actor. Documents containing DTD or entity declarations are
rejected, XML external-entity resolution is disabled, and compressed Draw.io payloads return a
clear unsupported-format error.

The original XML is base64-encoded before it enters the generated HTML. A trusted nonce-bearing
bootstrap script decodes the bytes and creates the viewer configuration with `JSON.stringify`, so
file content is never interpolated into executable JavaScript or live HTML. The WebKit content
security policy uses `default-src 'none'` and `connect-src 'none'`; the viewer's optional network
paths are also redirected to `about:blank`. Rendering therefore uses only the bundled runtime and
the selected file.

## Release-size impact

Measured from Release builds on Apple silicon before and after the 32.6.10 bump. The totals also
include the same-commit Rust dependency and Pele/KaTeX runtime changes; the viewer line isolates
the runtime.

| Artifact | 32.6.1 | 32.6.10 | Change |
| --- | ---: | ---: | ---: |
| `Glance.app` | 20,776,424 bytes | 21,298,757 bytes | +522,333 bytes (+2.51%) |
| `QLPlugin.appex` | 16,468,742 bytes | 16,990,461 bytes | +521,719 bytes (+3.17%) |
| `QLPlugin` executable | 8,043,920 bytes | 8,272,512 bytes | +228,592 bytes (+2.84%) |
| `drawio-viewer` runtime | 6,986,813 bytes | 7,312,492 bytes | +325,679 bytes |

The 7,312,492-byte viewer accounts for most of the runtime growth. It is loaded only for
`.drawio` previews.
