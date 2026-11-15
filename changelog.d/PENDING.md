### Fixed

- `deployment_preflight_helper validate-stores` reads each Keeper's memory
  journal (`<keeper>.memory-journal.jsonl` in the config keepers directory)
  as the `keeper memory journal` store. A line the journal decoder rejects
  is refused, and the refusal names the file and its line number. Before,
  only the memory snapshot was read, so a journal line every journal reader
  refuses passed the check and stopped that Keeper's Librarian Memory
  programs after the start (#32504, #PENDING).

### Upgrade notes

- An install stops at `validate-stores` when a memory journal holds a line
  this build cannot decode. Boot does not read the journal; the store is
  preflight-only (#PENDING).
