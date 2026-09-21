# Draw.io runtime

Glance bundles the official Draw.io 31.4.6 viewer for offline `.drawio` previews. The minified
runtime comes from the [v31.4.6 release](https://github.com/jgraph/drawio/releases/tag/v31.4.6)
and has SHA-256 digest
`2d0fef32815c79f1bb51f225effddfc57e111461bccf8386eed29c7cce3ab088`.
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

Measured from clean Release builds on Apple silicon. The baseline is merge commit
`56b3b62f54bc065ae717de2d9ad86d41db247567`.

| Artifact | Before | With Draw.io | Change |
| --- | ---: | ---: | ---: |
| `Glance.app` | 13,205,504 bytes | 15,945,728 bytes | +2,740,224 bytes (+20.75%) |
| `QLPlugin.appex` | 11,423,744 bytes | 14,163,968 bytes | +2,740,224 bytes (+23.99%) |
| `QLPlugin` executable | 7,066,080 bytes | 7,099,312 bytes | +33,232 bytes (+0.47%) |

The viewer is 2,690,195 bytes and accounts for nearly all bundle growth. It is loaded only for
`.drawio` previews.
