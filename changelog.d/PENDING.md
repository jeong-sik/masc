### Fixed

- `GET /api/v1/keepers/:name/memory-journal` answers 500 with `read_error`
  when the Keeper's memory journal exists and cannot be opened or read, or
  its path is not a regular file. The tail read raised `Sys_error` out of the
  handler in that case; a missing journal still reads as empty (#38596, #PENDING).

### Changed

- `Keeper_memory_os_current.read_journal_tail` and
  `read_journal_tail_projection` return a `result`, and
  `Dated_jsonl.map_tail_rows_result` reads a file's tail with open and read
  failures as `read_error` values (#38596, #PENDING).
