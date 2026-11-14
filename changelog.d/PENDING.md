### Fixed

- Saving a Keeper's runtime assignment, a lane or any other `runtime.toml`
  setting no longer appends a `[table]` header under a table the file writes
  as an inline table (`runtime = { default = "..." }` followed by
  `[runtime.assignments]`), or over a table dotted keys already define. TOML
  1.0 forbids both and the loader merged them, so the server kept running
  while a strict reader such as Python's `tomllib` refused the whole file.
  The save is now refused before the file is replaced, and the message names
  both lines and the spelling to use instead. A declaration the file already
  had does not block an unrelated save (#46981, #PENDING).
- Clearing or removing a Keeper whose assignment sits in an inline table or
  in dotted keys is refused with the reason. The writer edits rows under a
  `[runtime.assignments]` header, so it used to remove nothing and report the
  assignment as unchanged while the Keeper kept its route (#46981, #PENDING).
