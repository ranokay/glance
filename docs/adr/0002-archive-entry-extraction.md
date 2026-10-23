# Extract one archive entry on demand

**Status:** accepted

Archive previews used to show only a tree. To preview a file inside an archive,
Glance now extracts that single entry from PreviewCore into a private temporary
directory with a generated filename, then reuses the existing nested-preview
navigation. Extraction is bounded to 25 MB per entry, rejects directories,
links, and oversized entries, and deletes the temporary directory when the
nested preview is popped or the archive preview is torn down. Nested archives
are allowed to a depth of 3.

## Considered options

- Extract the whole archive: simpler navigation, but unbounded disk use and a
  much larger attack surface.
- Extract one entry at a time: bounded disk use and a small, testable boundary,
  at the cost of keeping per-format extraction code in PreviewCore.

## Consequences

Every archive format needs an extraction path in PreviewCore alongside its
scanner. Open With stays hidden for extracted entries because the temporary
file is not the user’s document. The depth cap prevents archive-inside-archive
loops from growing without bound.
