# Task history page segment offset index and single-pass scan, 2026-10-31

## Observed failure

Operator-reported TUI inspection of `task-2757` (`MASC Task [task-2757]`)
remained stuck at `[ 4. 상태 전환 이력 (HISTORY) ] loading...`.
On the active workspace (`/Users/dancer/me/.masc`), the two dated history
stores (`activity-events/` and `events/`) contained 54 dated `.jsonl` files
totaling 420,468,941 bytes (806,631 physical rows; the single file
`activity-events/2026-10/30.jsonl` was 66,892,508 bytes).

Because `task-2757` had 9 matching history events (below the TUI's `limit=59`),
each `Task_history_page.read` scanned the entire 420.5 MB prefix across all 54
files from scratch:

1. `load_block` called `Fs_compat.load_owned_regular_file_range` on every
   64 KiB block (~6,570 blocks per read), executing ~18 `lstat`/`open`/`fstat`/
   `close` syscalls per block (~118,000 syscalls per history request).
2. Every nonblank line in every file underwent two full recursive passes over
   the parsed `Yojson.Safe.t` tree (`valid_json` with per-object `String_set`
   allocations followed by `row_state`).
3. No validated scan state was retained across calls, so navigating across
   tasks in `masc-tui` repeated the full 420.5 MB scan on every selection.

## Architecture of the repair (`lib/task/task_history_page.ml`)

1. **Held-descriptor block reader (`with_reader`, `ensure_reader_fd`, `load_block`)**:
   Each dated file is opened at most once per file scan after verifying its
   parent directory ownership chain (`Fs_compat.inspect_owned_directory_chain`),
   no-nofollow leaf `Unix.lstat` (`S_REG`, `st_uid = snapshot.owner_uid`,
   mode `0o022 = 0`), and open descriptor `Unix.fstat` identity against the
   captured inventory snapshot. Every 64 KiB block read re-verifies descriptor
   `fstat` ownership (`S_REG`, `owner_uid`, mode `0o022 = 0`) and snapshot
   identity (`device`, `inode`, and non-shrunk `file_size >= snapshot.file_size`).
2. **Single-pass JSON and schema validation (`valid_json`, `extract_activity_identities`, `classify_row`)**:
   Combines duplicate-key/finite-float validation with `activity-events` and
   `events` field validation and task identity extraction in one pass without
   intermediate `String_set` or list allocations on small objects.
3. **Snapshot- and digest-verified segment offset index (`cached_segment`, `scan_range_raw`)**:
   Stores only physical byte offsets (`int list String_map.t`) for matching
   `by_task` and `conflicting` rows over a validated `[scanned_from, scanned_to)`
   byte range, accompanied by the file's `owned_regular_file_snapshot` and
   64 KiB block SHA-256 digests (`block_digests`, covering all blocks when
   `scanned_to - scanned_from <= 512 KiB` and the first/last blocks of the
   segment otherwise). `verify_cached_segment` requires exact `equal_owned_regular_file_snapshot`
   equality whenever `file_size` has not grown, verifies all recorded
   `block_digests`, and immediately removes any invalidated cache entry before
   falling back to a cold scan:
   - **Append extension**: When the active day file grows (`before > cached.scanned_to`)
     and the cached digests match, only the appended tail
     `[cached.scanned_to, before)` is scanned, verified to stop exactly at the
     `cached.scanned_to` line boundary, and merged into the cached index.
   - **Warm lookup**: For `[cached.scanned_from, before)` within the verified
     cached segment, only the matching task's candidate physical offsets and any
     conflicting offsets in that window are visited in reverse physical order,
     re-validating each materialized row through `classify_row` and falling back
     to a full cold scan if any in-place discrepancy is detected.
   - **Downward continuation**: If a sparse task requires scanning below
     `cached.scanned_from` (`[0, cached.scanned_from)`), the reader verifies the
     `cached.scanned_from` line boundary, scans downward from `cached.scanned_from`,
     and merges the newly validated prefix.
   - **Lazy older-row semantics preserved**: If a cold scan stops early because
     `count = max_events` before reaching offset `0`, only the validated suffix
     `[stop_offset, before)` is cached so older unvisited malformed rows are not
     eagerly rejected until a continuation reaches them.

## Standalone reader + live corpus benchmark

Both baseline (`HEAD` before change) and candidate `lib/task/task_history_page.ml`
were compiled with `ocamlfind ocamlopt` (OCaml 5.5.1) against the existing
compiled workspace libraries and executed against:
1. The unit scenarios `test_buffered_sources` (extended with post-append fresh
   read and absent-task warm read assertions before the in-place overwrite check)
   and `test_current_and_incremental_sources` from `test/test_h2_journal.ml`.
2. The live `/Users/dancer/me/.masc` store (54 dated files, 420,468,941 bytes,
   806,631 rows).

| Scenario | Task ID | Limit | Events | Elapsed seconds | Output equivalence |
|---|---|---:|---:|---:|---|
| Baseline (run 1) | `task-2757` | 59 | 9 | 7.908240 | reference |
| Baseline (run 2) | `task-2757` | 59 | 9 | 6.757194 | 100% identical JSON |
| Candidate cold (run 1) | `task-2757` | 59 | 9 | 4.661375 | 100% identical JSON |
| Candidate warm (run 1) | `task-2757` | 59 | 9 | 0.008593 | 100% identical JSON |
| Candidate cold (run 2) | `task-2757` | 59 | 9 | 4.860890 | 100% identical JSON |
| Candidate warm (run 2) | `task-2757` | 59 | 9 | 0.009689 | 100% identical JSON |
| Candidate warm (cross-task) | `task-2755` | 59 | 9 | 0.008315 | verified |
| Candidate warm (cross-task) | `task-2774` | 59 | 59 | 0.005375 | verified |

Warm reads across all 54 dated files complete in **5.4–9.7 ms** (~800–920x
faster than baseline), where ~7 ms is the pre/post `inventory` directory sweep
and < 2 ms is `scan_files`.

## Validation scope

- Focused `ocamlfind ocamlc -c` and `ocamlfind ocamlopt -c` typechecks passed for
  `lib/task/task_history_page.mli`, `lib/task/task_history_page.ml`, and
  `test/test_h2_journal.ml` against existing compiled dependency interfaces.
  No full `dune build` was run.
- Standalone native execution of `test_buffered_sources` and
  `test_current_and_incremental_sources` passed (`[PASS]`).
- `git diff --check` passed.
- The running installed `/Users/dancer/.local/bin/masc` server process was not
  replaced during this session; deployed server/TUI runtime behavior after
  binary replacement remains a separate stage.
