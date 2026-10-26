# Draw.io runtime

Glance bundles the official Draw.io 32.6.1 viewer for offline `.drawio` previews. The minified
runtime (`js/viewer.min.js` from `draw.war`) comes from the
[v32.6.1 release](https://github.com/jgraph/drawio/releases/tag/v32.6.1) and has SHA-256 digest
`9dafdfb2b62172aa78f91feae0b25af71c5a1d322764ce3794dd2899e8ea0f2e`.
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

Measured from Release builds on Apple silicon before and after the 32.6.1 bump. The totals also
include the same-commit Sparkle and Rust dependency bumps; the viewer line isolates the runtime.

| Artifact | 31.4.6 | 32.6.1 | Change |
| --- | ---: | ---: | ---: |
| `Glance.app` | 16,371,183 bytes | 20,735,403 bytes | +4,364,220 bytes (+26.66%) |
| `QLPlugin.appex` | 12,165,798 bytes | 16,522,369 bytes | +4,356,571 bytes (+35.81%) |
| `QLPlugin` executable | 8,041,264 bytes | 8,098,016 bytes | +56,752 bytes (+0.71%) |
| `drawio-viewer` runtime | 2,690,195 bytes | 6,986,813 bytes | +4,296,618 bytes |

The 6,986,813-byte viewer accounts for nearly all of the bundle growth. It is loaded only for
`.drawio` previews.
