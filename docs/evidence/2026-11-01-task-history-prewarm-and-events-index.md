# Task History Pre-Warm and Events Index Evidence (2026-11-01)

## Problem
1. **First-open cold scan on the 2-domain HTTP `read_pool`**:
   - At server startup, `Server_dashboard_http.warm_dashboard_surfaces` pre-warms `shell`, `board`, `planning`, `config`, and `keeper-memory-health` on the 8-domain `Background` pool, but did not pre-warm `Task.History_page` or `Task.Tool.task_history_events_json`.
   - As a result, the first operator click on a task in `masc-tui` (`GET /api/v1/dashboard/tasks/history/page`) triggered the cold index build across all 56 `.masc/activity-events` and `.masc/events` files (`442.5 MB`) on one of the 2 `read_pool` domains (`run_max_ms: 7298.54 ms`, `wait.max_ms: 6592.48 ms` observed in `/health?full=1`).
2. **Uncached per-call scan in `Task.Tool.task_history_events_json` and HTTP/2 `/api/v1/dashboard/tasks/history`**:
   - `Task.Tool.task_history_events_json` scanned every `.masc/events/YYYY-MM/DD.jsonl` file (`28 files`, `6.4 MB`, `7,263 lines`) on every call via `Fs_compat.load_file`, `String.split_on_char '\n'`, and `Yojson.Safe.from_string` on every line (`57.8–92.8 ms` per call).
   - Over HTTP/2, `GET /api/v1/dashboard/tasks/history` invoked `Task.Tool.task_history_events_json` directly on the main H2 Eio fiber without `Dashboard_cache.get_or_compute_payload` or `Pool_work.cpu` offloading (unlike the HTTP/1.1 handler in `server_routes_http_dashboard_handlers.ml`).
3. **Uncached `.masc/events` scan in `Workspace_task_id.next_task_number`, synchronous stripe locks in `Task_history_page`, and missing H2 `/api/v1/dashboard/tasks/inspection` route**:
   - `Workspace_task_id.next_task_number` scanned all `.masc/events/YYYY-MM/DD.jsonl` files from scratch on every task creation (`58.9–87.7 ms` while holding the backlog file lock).
   - `Task_history_page` held 64-way `Stdlib.Mutex` striped scan locks across file I/O and indexing and bounded `segment_cache` only by file count (`256`), not by total retained row count.
   - `Server_h2_gateway` lacked `GET /api/v1/dashboard/tasks/inspection`, which HTTP/1.1 serves for `masc-tui` original task inspection.

## Current Implementation (`#47060` + follow-up)
1. **Per-file `.masc/events` index cache (`lib/task/tool_task.ml`)**:
   - Added a per-file index cache (`events_file_cache`) bounded by both file count (`256` files) and serialized JSON source bytes (`max_cached_event_bytes = 64 MiB`; note: this cap tracks serialized source byte length, not exact OCaml heap words).
   - File reads, digests, and JSON indexing run unlocked outside `events_file_cache_mutex` (so slow scans never block unrelated worker domains) and explicitly re-raise `Eio.Cancel.Cancelled`. Only cache lookup, publication, and LRU eviction acquire `events_file_cache_mutex`.
   - Supports incremental tail append when `(st_dev, st_ino)` match, the previous file ended with `'\n'`, and `Digest.substring content 0 entry.st_size` matches `entry.prefix_digest`.
   - Verifies content digest on the newest active day file (`<= 256 KB`) so same-size, same-timestamp in-place edits never serve stale events.
2. **Lock-free segment scans and row budget in `Task_history_page` (`lib/task/task_history_page.ml`)**:
   - Removed the 64-way synchronous `Stdlib.Mutex` stripe array (`file_scan_locks`) so file scans and block digest checks run unlocked; `store_cached_segment` enforces monotonic replacement under `cache_mutex`, and `invalidate_cached_segment_if_same` only evicts the exact stale segment observed by the caller.
   - Added `max_cached_segment_rows = 2_000_000` (`segment_cache_retained_rows`) alongside `max_cached_files = 256` so LRU eviction bounds both file count and retained row count.
3. **Per-file max task ID cache in `Workspace_task_id` (`lib/workspace/workspace_task_id.ml`)**:
   - Replaced `event_history_task_ids` with `event_history_max_task_id` backed by a bounded (`256` files) per-file `max_task_id : int` cache (`event_max_id_cache`) with unlocked scans, `Eio.Cancel.Cancelled` propagation, incremental tail append, and newest-file digest verification.
4. **HTTP/2 parity (`lib/server/server_h2_gateway.ml`) & Startup pre-warm (`lib/server/server_dashboard_http.ml`)**:
   - Routed `GET /api/v1/dashboard/tasks/history` through `Dashboard_cache.get_or_compute_payload` and `Pool_work.cpu ~name:__FUNCTION__` with `h2_respond_cached_payload`.
   - Added `GET /api/v1/dashboard/tasks/inspection` to `Server_h2_gateway` to match the HTTP/1.1 route in `server_routes_http_routes_dashboard.ml`.
   - Added `warm_task_history` to `warm_dashboard_surfaces` to pre-warm both `Task.History_page.read` and `Task.Tool.task_history_events_json` on the background pool during startup.

## Historical Benchmark Results (`/Users/dancer/me/.masc/events`, 28 files / 6.4 MB / 7,263 lines)

### `Task.Tool.task_history_events_json` (measured during `#47060`)

| Task ID | Matching Rows | Baseline (`origin/main`) | Indexed (1st after prewarm) | Indexed (warm) | Speedup |
| :--- | ---: | ---: | ---: | ---: | ---: |
| `task-2757` | 2 | `82.438 ms` | `82.413 ms` (cold) | `0.430 ms` | **192x** |
| `task-2972` | 0 | `61.234 ms` | `0.380 ms` | `0.283 ms` | **216x** |
| `task-2946` | 4 | `58.417 ms` | `0.459 ms` | `0.356 ms` | **164x** |
| `__prewarm__` | 0 | `57.755 ms` | `0.344 ms` | `0.234 ms` | **247x** |

### `Workspace_task_id.event_history_max_task_id` (measured on live `/Users/dancer/me/.masc/events`, 29 files / 6.5 MB)

| Iteration | Max Task ID | Uncached Baseline | Cached (`event_max_id_cache`) | Speedup |
| :--- | ---: | ---: | ---: | ---: |
| 1 (cold) | `3000` | `87.664 ms` | `71.686 ms` | `1.2x` |
| 2 (warm) | `3000` | `58.939 ms` | `0.604 ms` | **98x** |
| 3 (warm) | `3000` | `66.850 ms` | `1.265 ms` | **53x** |
| 4 (warm) | `3000` | `64.326 ms` | `0.680 ms` | **95x** |
