### Fixed

- `deployment_preflight_helper validate-stores` reads each Keeper's memory
  journal (`<keeper>.memory-journal.jsonl` in the config keepers directory)
  as the `keeper memory journal` store. A line the journal decoder rejects
  is refused, and the refusal names the file and its line number. Before,
  only the memory snapshot was read, so a journal line every journal reader
  refuses passed the check and stopped that Keeper's Librarian Memory
  programs after the start (#32504, #PENDING).
- The `keeper memory OS events` and `keeper absorbed memory facts` scans
  read `<keeper>.memory-events.jsonl` and `<keeper>.memory-absorbed.jsonl`
  in the config keepers directory, where Memory writes them. They looked in
  the runtime keepers directory, where no writer puts them, so they read no
  row of a workspace (#32504, #PENDING).

### Upgrade notes

- An install stops at `validate-stores` when a memory journal, events
  sidecar or absorbed-fact sidecar holds a line this build cannot decode.
  The events and absorbed-fact scans read rows for the first time, so a line
  written in an earlier format can stop the first install after this change.
  Boot does not read these stores; they are preflight-only (#PENDING).
