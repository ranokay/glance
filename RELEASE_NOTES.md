# Glance 1.6.0

Glance 1.6.0 replaces its HTML renderer and untrusted file-format parsers with a bounded Rust
preview core while preserving the native Swift/AppKit Quick Look experience.

- Source, Markdown, and Jupyter rendering now use the Rust preview core with the existing visual
  styles and stricter handling of unsafe HTML and URLs.
- TSV, ZIP/JAR/EAR/WAR, TAR/tgz, and 7z metadata parsing now runs in Rust with explicit input,
  entry-count, metadata, and scan limits; Swift retains the bounded archive-tree construction.
- Preview rendering, parser work, JSON decoding, and directory enumeration run outside the main
  thread and discard cancelled results.
- The Go runtime and the SwiftCSV, ZIPFoundation, SWCompression, and BitByteData packages have been
  removed from the shipping app.

This release remains Apple-silicon-only for macOS 26 or later. Its DMG is unsigned and
unnotarized; verify the published SHA-256 checksum before installation.
