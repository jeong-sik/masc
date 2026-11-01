# Task History Pre-Warm and Events Index Evidence (2026-11-01)

## Problem
1. **First-open cold scan on the 2-domain HTTP `read_pool`**:
   - At server startup, `Server_dashboard_http.warm_dashboard_surfaces` pre-warms `shell`, `board`, `planning`, `config`, and `keeper-memory-health` on the 8-domain `Background` pool, but did not pre-warm `Task.History_page` or `Task.Tool.task_history_events_json`.
   - As a result, the first operator click on a task in `masc-tui` (`GET /api/v1/dashboard/tasks/history/page`) triggered the cold index build across all 56 `.masc/activity-events` and `.masc/events` files (`442.5 MB`) on one of the 2 `read_pool` domains (`run_max_ms: 7298.54 ms`, `wait.max_ms: 6592.48 ms` observed in `/health?full=1`).
2. **Uncached per-call scan in `Task.Tool.task_history_events_json` and HTTP/2 `/api/v1/dashboard/tasks/history`**:
   - `Task.Tool.task_history_events_json` scanned every `.masc/events/YYYY-MM/DD.jsonl` file (`28 files`, `6.4 MB`, `7,263 lines`) on every call via `Fs_compat.load_file`, `String.split_on_char '\n'`, and `Yojson.Safe.from_string` on every line (`57.8–92.8 ms` per call).
   - Over HTTP/2, `GET /api/v1/dashboard/tasks/history` invoked `Task.Tool.task_history_events_json` directly on the main H2 Eio fiber without `Dashboard_cache.get_or_compute_payload` or `Pool_work.cpu` offloading (unlike the HTTP/1.1 handler in `server_routes_http_dashboard_handlers.ml`).

## Changes
1. **Per-file `.masc/events` index cache (`lib/task/tool_task.ml`)**:
   - Added a bounded (`256` files), mutex-protected, per-file index cache (`events_file_cache`) with 64-way striped scan locks (`events_file_scan_locks`).
   - Scans lines forward without `String.split_on_char '\n'` list allocation, indexing valid JSON events by their top-level `"task"` and `"task_id"` string fields in newest-first order per file.
   - Supports incremental tail append when `(st_dev, st_ino)` match, the previous file ended with `'\n'`, and `Digest.substring content 0 entry.st_size` matches `entry.prefix_digest`.
   - Verifies content digest on the newest active day file (`<= 256 KB`) so same-size, same-timestamp in-place edits never serve stale events.
2. **HTTP/2 parity (`lib/server/server_h2_gateway.ml`)**:
   - Routed `GET /api/v1/dashboard/tasks/history` through `Dashboard_cache.get_or_compute_payload` and `Pool_work.cpu ~name:__FUNCTION__` with `h2_respond_cached_payload`, sharing the `task_history:<base_path>:<task_id>:<limit>` cache key with HTTP/1.1.
3. **Startup pre-warm (`lib/server/server_dashboard_http.ml`)**:
   - Added `warm_task_history` to `warm_dashboard_surfaces` to pre-warm both `Task.History_page.read` and `Task.Tool.task_history_events_json` on the background pool during startup.

## Benchmark Results (`/Users/dancer/me/.masc/events`, 28 files / 6.4 MB / 7,263 lines)

| Task ID | Matching Rows | Baseline (`origin/main`) | Indexed (1st after prewarm) | Indexed (warm) | Speedup |
| :--- | ---: | ---: | ---: | ---: | ---: |
| `task-2757` | 2 | `82.438 ms` | `82.413 ms` (cold) | `0.430 ms` | **192x** |
| `task-2972` | 0 | `61.234 ms` | `0.380 ms` | `0.283 ms` | **216x** |
| `task-2946` | 4 | `58.417 ms` | `0.459 ms` | `0.356 ms` | **164x** |
| `__prewarm__` | 0 | `57.755 ms` | `0.344 ms` | `0.234 ms` | **247x** |
