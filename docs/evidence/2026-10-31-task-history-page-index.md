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

## Round 2 follow-up: Zero-AST slice scanner, fast inventory, and review hardening (2026-11-01)

Following the merge of PR #47004 (`5cfbb5bec3d2220b3720ae0847306f30833045d4`), profiling of the remaining cold-scan (`~4.9–6.0 s`) and warm-scan (`~35 ms`) paths identified two further bottlenecks and five P3 review follow-ups from `code-reviewer` (`be-sleepers`) and `code-reviewer-mother` (`anyang-keepers`):

1. **Zero-AST single-pass slice scanner (`scan_row_slice_fast`) with `classify_row` fallback**:
   - In Round 1, every nonblank row across the 806,631 rows in `/Users/dancer/me/.masc` allocated a fresh `String.sub` line copy, a `Yojson.Safe` lexer buffer, and a full `Yojson.Safe.t` AST even when 99.99% of rows belonged to unrelated tasks.
   - `previous_slice` now populates a mutable `row_slice` view directly into the immutable 64 KiB `reader.block` whenever a row fits within a single block (the common case), avoiding per-row string allocation.
   - `scan_row_slice_fast` validates RFC 8259 JSON syntax, UTF-8 byte sequences, finite numbers, duplicate keys (via a preallocated integer slice buffer `key_buf`), and `activity-events` / `events` schema fields directly over `[row_pos, row_pos + row_len)`, interning unescaped task ID slices via a separate-chaining `task_bucket` table (`add_slice_to_buckets` / `add_string_to_buckets`).
   - Any escaped key/task ID (`\uXXXX`), float or numeric-string `seq`/`ts_ms`, object with `> 64` keys, nesting `> 32`, or syntax error automatically falls back to `classify_row` (`Yojson.Safe.from_string` + `valid_json`), guaranteeing 100% behavioral parity with `Tui_decode_task_inspection.history`.
   - Only matching rows for the requested `task_id` (up to `max_events`) materialize a `Yojson.Safe.t` event envelope.
2. **Bracketed `Unix.lstat` directory inventory (`lstat_owned_regular_file`)**:
   - Replaces per-file `Fs_compat.inspect_owned_regular_file` (`open` + `fstat` + `close` + repeated parent chain walk on each of the 54 files) with `Unix.lstat` bracketed by pre/post `inspect_owned_dir ~root month_dir` identity checks (`same_stat_identity`), cutting the 54-file inventory + post-read `recheck` overhead from ~14 ms to ~1.5 ms.
3. **Settled-snapshot fast path and structural segment metadata (`anyang-keepers` P3 #1 & #2, `be-sleepers` P3 #1 & #2)**:
   - Tightened `matches_file_ownership` (`st_perm land 0o7777 = s.permissions`) and `matches_file_snapshot` (`Float.equal st.st_mtime s.modified_at && Float.equal st.st_ctime s.changed_at` when `st_size = s.file_size`).
   - Added structural metadata (`row_count : int`, `first_row_offset : int`, `verified_settled : bool`) to `cached_segment` along with `first_row_offset` newline boundary verification (`byte reader (cached.first_row_offset - 1) = '\n'`) and settled-snapshot digest bypass (`now -. modified_at > 2.0 && now -. changed_at > 2.0` with unchanged `owned_regular_file_snapshot`), while preserving full `block_digests` verification for any recently modified or appended file.
   - Replaced whole-table `Hashtbl.clear` eviction with monotonic `last_used` / `cache_clock` LRU eviction (`evict_lru_locked`).
   - Updated `lib/task/task_history_page.mli` to document the post-read TOCTOU window and cached segment digest/boundary verification contract.
4. **Validator parity test (`anyang-keepers` P3 #3)**:
   - Extended `test_task_history_buffered_sources` in `test/test_h2_journal.ml` to assert exact parity between `Task.History_page.read` and `Tui_decode_task_inspection.history` across standard integer `seq`/`ts_ms`, float `seq` + numeric-string `ts_ms`, `\uXXXX`-escaped keys and task IDs, duplicate root/nested keys, unknown root fields, non-string tags, and conflicting `subject` + `payload.task_id = null`.

### Round 2 live corpus benchmark (`/Users/dancer/me/.masc`, 54 dated files, 420.5 MB, 806,631 rows)

| Scenario | Task ID | Limit | Events | Elapsed seconds | Speedup vs pre-Round-1 (`7.91 s`) | Speedup vs Round 1 | Output equivalence |
|---|---|---:|---:|---:|---:|---:|---|
| Round 1 baseline cold | `task-2757` | 59 | 9 | 6.093949 | 1.30x | 1.00x (ref) | reference |
| Round 1 baseline warm | `task-2757` | 59 | 9 | 0.035183 | 225x | 1.00x (ref) | 100% identical JSON |
| **Round 2 candidate cold** | `task-2757` | 59 | 9 | **1.418588** | **5.58x** | **4.30x** | 100% identical JSON |
| **Round 2 candidate warm** | `task-2757` | 59 | 9 | **0.004986** | **1,586x** | **7.06x** | 100% identical JSON |
| **Round 2 candidate warm (cross-task)** | `task-2755` | 59 | 9 | **0.002952** | **2,679x** | **11.92x** | verified |
| **Round 2 candidate warm (cross-task)** | `task-2774` | 59 | 59 | **0.003591** | **2,202x** | **9.80x** | verified |

## Validation scope

- Standalone native compilation (`ocamlfind ocamlopt`) and execution of `test_validator_parity_and_fast_scanner_edge_cases`, `test_buffered_sources`, `test_current_and_incremental_sources`, and live `/Users/dancer/me/.masc` equivalence + timing harness passed (`[PASS]`). No full `dune build` was run.
- `git diff --check` passed.
- The running installed `/Users/dancer/.local/bin/masc` server process was not
  replaced during this session; deployed server/TUI runtime behavior after
  binary replacement remains a separate stage.
