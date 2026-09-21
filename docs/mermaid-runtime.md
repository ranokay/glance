# Mermaid runtime

Glance bundles Mermaid 11.17.2 for offline Markdown diagram rendering. The source asset is the
official npm package's `dist/mermaid.min.js`; its SHA-256 digest is
`581ed7d74bd9048d0e3a91363927d72ef22942d7722546b27f7cc29e35390eb8`.
`MERMAID_LICENSE.txt` is included beside the runtime in the Quick Look extension.

PreviewCore emits `<!--glance-renderer-mermaid-v1-->` only for parsed Mermaid fences. Swift loads
the runtime only when that trusted marker is present. Mermaid runs with `securityLevel: 'strict'`,
and the preview content security policy sets `connect-src 'none'`. If rendering fails, the escaped
source block remains visible.

## Release-size impact

Measured from clean Release builds at `97c3feb2ec9c0deb22ca3bf5fabd007a76d66caf` on Apple silicon:

| Artifact | Before | With Mermaid | Change |
| --- | ---: | ---: | ---: |
| `Glance.app` | 9,605,120 bytes | 13,205,504 bytes | +3,600,384 bytes (+37.48%) |
| `QLPlugin.appex` | 7,823,360 bytes | 11,423,744 bytes | +3,600,384 bytes (+46.02%) |
| `QLPlugin` executable | 7,047,904 bytes | 7,065,648 bytes | +17,744 bytes (+0.25%) |

The bundled minified runtime is 3,572,661 bytes and accounts for nearly all of the bundle growth.
It is present on disk for offline use but is not injected or executed for Markdown without a
Mermaid fence.
