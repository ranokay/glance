# KaTeX runtime

Glance bundles KaTeX 0.19.1 for offline TeX rendering in Markdown and Jupyter
previews. The source is the npm package tarball
<https://registry.npmjs.org/katex/-/katex-0.19.1.tgz>, SHA-256
`24da5a599eb2fcede2e270b99a6ff48bca816beecc95feeb84e8cccbd1bb34fd`.

The bundled files are copied from the package's `dist` directory:

| File | SHA-256 |
| --- | --- |
| `katex.min.js` | `fa140498b8cfc8302cbe5e7cb1bdbc1f952bc38b3fa258ede09e73edbf9a74bc` |
| `katex.min.css` | `8969f808bd9791393e8174f2022ea08664273ffa93c3338f27cac69eb634ebec` |
| `contrib/auto-render.min.js` | `e5372d199bcdae8b4de71d0f7ceba72a4ba12774a27c60a6f1f77d03b3228ee4` |

The 20 `KaTeX_*.woff2` font files come from the same tarball. The stylesheet
references them by name and the smoke tests check that every reference resolves
inside the Quick Look resource bundle. The Xcode resource phase flattens the
font files beside the stylesheet, so the CSS uses the bare font names. The
upstream stylesheet also lists WOFF and TTF fallbacks; those sources are removed
so the app ships only the WOFF2 fonts it uses.

The complete upstream MIT license is included as `KATEX_LICENSE.txt` beside the
runtime. Its SHA-256 is
`766ccc1f306c885aa45542a9846bbd0a505b27a0374f146778171c2254ce18e3`.

Markdown math uses KaTeX only when PreviewCore emits its trusted
`data-math-style` marker. Jupyter uses `renderMathInElement` for Markdown cells
and `katex.render` for `text/latex` outputs. Both paths set `throwOnError:
false`, `trust: false`, and `strict: 'warn'`, and the preview content security
policy sets `connect-src 'none'`.

## Release-size impact

The KaTeX 0.19.1 file set is 560,005 bytes. The 0.11.1 set was 617,117 bytes,
so the update removes 57,112 bytes from the Quick Look extension resources. The
smaller 0.19.1 WOFF2 fonts account for most of the difference.
