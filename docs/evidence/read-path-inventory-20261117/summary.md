## A. Read call sites by kind and where the blocking read runs

| shape | mech | sites |
|---|---|---|
| meta | caller | 1202 |
| whole | systhread_host | 233 |
| dir | caller | 176 |
| open | caller | 152 |
| whole | caller | 141 |
| read | caller | 84 |
| db | caller | 84 |
| meta | eio | 70 |
| meta | systhread_host | 64 |
| tail | read_pool | 30 |
| slice | systhread_host | 29 |
| whole | eio | 22 |
| dir | systhread_host | 21 |
| whole+parse | systhread_host | 20 |
| whole+parse | caller | 16 |
| range | read_pool | 16 |
| stream | systhread_host | 11 |
| dir | eio | 6 |
| stream+parse | systhread_host | 5 |
| lines | systhread_host | 1 |

## B. Content-read sites by reaching entry

| reached from | mech | sites |
|---|---|---|
| none of these (boot, tool, other loop or unresolved) | caller | 126 |
| none of these (boot, tool, other loop or unresolved) | eio | 6 |
| none of these (boot, tool, other loop or unresolved) | read_pool | 14 |
| none of these (boot, tool, other loop or unresolved) | systhread_host | 90 |
| refresh loop | caller | 2 |
| route | caller | 11 |
| route | eio | 2 |
| route | read_pool | 21 |
| route | systhread_host | 80 |
| route + refresh loop | caller | 2 |
| route + refresh loop | read_pool | 6 |
| route + refresh loop | systhread_host | 7 |
| route + turn | caller | 69 |
| route + turn | eio | 13 |
| route + turn | read_pool | 4 |
| route + turn | systhread_host | 98 |
| route + turn + refresh loop | caller | 31 |
| route + turn + refresh loop | eio | 1 |
| route + turn + refresh loop | systhread_host | 18 |
| turn | read_pool | 1 |
| turn | systhread_host | 6 |

## C. Entries reaching the most content-read sites (depth <= 30)

| entry | content-read sites |
|---|---|
| ROUTE GET /api/v1/dashboard/agent_core/telemetry/summary | 248 |
| ROUTE PREFIX_POST /api/v1/keepers/ | 218 |
| Keeper_agent_run.run_turn | 215 |
| ROUTE GET /api/v1/gate/keepers | 202 |
| ROUTE GET /api/v1/gate/keeper-status | 201 |
| ROUTE GET /api/v1/gate/keeper-sandbox-status | 201 |
| ROUTE POST /api/v1/operator/confirm | 196 |
| ROUTE POST /api/v1/operator/action | 194 |
| ROUTE PREFIX_GET /api/v1/keepers/ | 98 |
| ROUTE POST /api/v1/keepers/memory-catch-up | 78 |
| ROUTE POST /api/v1/tools/masc_goal_transition | 60 |
| ROUTE POST /api/v1/dashboard/agents/purge | 57 |
| ROUTE GET /mcp | 50 |
| ROUTE GET /mcp/operator | 50 |
| ROUTE GET /ag-ui/events | 49 |
| ROUTE GET /events/presence | 49 |
| ROUTE POST / | 49 |
| ROUTE POST /mcp | 49 |
| ROUTE POST /mcp/managed | 49 |
| ROUTE POST /mcp/operator | 49 |

## D. Routes the TUI refreshes, content reads within reach


### ROUTE GET /api/v1/keepers/turns — 13 sites

| depth | site | primitive | mech |
|---|---|---|---|
| 7 | lib/keeper/keeper_shutdown_store.ml:913 | fs.load_file | systhread_host |
| 8 | lib/keeper_runtime/keeper_event_queue_persistence.ml:1087 | safe.read_json | systhread_host |
| 8 | lib/workspace/workspace_utils_ops.ml:200 | safe.read_file | systhread_host |
| 8 | lib/workspace/workspace_utils_ops.ml:203 | safe.read_file | systhread_host |
| 9 | lib/backend/backend.ml:390 | eio.load | eio |
| 9 | lib/core/safe_ops.ml:351 | fs.load_file | systhread_host |
| 10 | lib/fs_compat/fs_compat_base_io.ml:130 | stdlib.really_input | caller |
| 11 | lib/fs_compat/fs_compat_jsonl_read.ml:373 | unix.read | caller |
| 12 | lib/keeper_runtime/keeper_event_queue_persistence.ml:468 | safe.read_file | systhread_host |
| 13 | lib/keeper_runtime/keeper_event_queue_quarantine.ml:66 | fs.load_file | systhread_host |
| 14 | lib/config/env_config_core.ml:466 | stdlib.in_channel | caller |
| 14 | lib/fs_compat/fs_compat_private_jsonl_read.ml:109 | unix.read | caller |
| 14 | lib/fs_compat/fs_compat_private_jsonl_read.ml:80 | unix.read | caller |

### ROUTE GET /api/v1/gate/keepers — 202 sites

| depth | site | primitive | mech |
|---|---|---|---|
| 5 | lib/auth/auth_credential_base.ml:108 | stdlib.in_channel | caller |
| 6 | lib/keeper/keeper_meta_store.ml:222 | safe.read_file | systhread_host |
| 6 | lib/keeper/keeper_meta_store.ml:225 | safe.read_file | systhread_host |
| 7 | lib/core/safe_ops.ml:360 | fs.load_file | systhread_host |
| 7 | lib/keeper/keeper_status_detail.ml:477 | dj.read_recent | read_pool |
| 7 | lib/keeper/keeper_status_detail.ml:494 | dj.read_recent | read_pool |
| 7 | lib/tool_blob_store/tool_blob_store.ml:321 | fs.load_owned | systhread_host |
| 8 | lib/candle_config/candle_config.ml:303 | stdlib.in_channel | caller |
| 8 | lib/keeper/keeper_execution_receipt.ml:586 | dj.read_recent | read_pool |
| 9 | lib/keeper/keeper_checkpoint_store_decode.ml:139 | fs.load_owned | systhread_host |
| 9 | lib/keeper/keeper_checkpoint_store_retained.ml:154 | fs.load_owned | systhread_host |
| 9 | lib/keeper/keeper_next_request_forecast.ml:381 | dj.read_recent | read_pool |
| 9 | lib/keeper/keeper_official_client_session_store.ml:1109 | fs.load_file | systhread_host |
| 9 | lib/keeper/keeper_status_detail_observability.ml:8 | dj.read_recent | read_pool |
| 9 | lib/keeper/keeper_status_metrics.ml:272 | dj.read_recent | read_pool |
| 9 | lib/keeper/keeper_types_profile_toml_io.ml:107 | safe.read_file | systhread_host |
| 10 | lib/fs_compat/fs_compat_owned_file.ml:248 | unix.read | caller |
| 10 | lib/fs_compat/fs_compat_private_jsonl_write.ml:133 | unix.read | caller |
| 10 | lib/keeper/keeper_checkpoint_store_retained.ml:22 | fs.load_owned | systhread_host |
| 10 | lib/keeper/keeper_memory_recall.ml:60 | unix.read | caller |
| 10 | lib/keeper/keeper_shutdown_store.ml:913 | fs.load_file | systhread_host |
| 10 | lib/keeper/keeper_types_profile.ml:462 | safe.read_file | systhread_host |
| 10 | lib/tool_blob_store/tool_blob_store.ml:607 | fs.load_owned | systhread_host |
| 11 | lib/core/safe_ops.ml:351 | fs.load_file | systhread_host |
| 11 | lib/dated_jsonl/dated_jsonl.ml:533 | stdlib.really_input | caller |
| 11 | lib/fs_compat/fs_compat_base_io.ml:130 | stdlib.really_input | caller |
| 11 | lib/fs_compat/fs_compat_private_jsonl_write.ml:101 | unix.read | caller |
| 11 | lib/keeper/keeper_turn_up_config_persistence.ml:196 | safe.read_file | systhread_host |
| 11 | lib/keeper/keeper_types_profile.ml:318 | safe.read_file | systhread_host |
| 11 | lib/runtime/runtime_toml.ml:1250 | stdlib.in_channel | caller |
| 12 | lib/dated_jsonl/dated_jsonl.ml:1569 | fs.fold_appended_lines | systhread_host |
| 12 | lib/dated_jsonl/dated_jsonl.ml:723 | stdlib.really_input | caller |
| 12 | lib/fs_compat/fs_compat_jsonl_read.ml:373 | unix.read | caller |
| 12 | lib/fs_compat/fs_compat_private_file_update.ml:649 | unix.read | caller |
| 12 | lib/keeper/keeper_checkpoint_object_store.ml:57 | fs.load_owned | systhread_host |
| 12 | lib/keeper/keeper_checkpoint_store_canonical.ml:34 | unix.read | caller |
| 12 | lib/keeper/keeper_librarian_progress_file.ml:60 | fs.load_file | systhread_host |
| 12 | lib/keeper/keeper_librarian_unread_ledger.ml:25 | fs.load_file | systhread_host |
| 12 | lib/keeper/keeper_registry_tool_usage_persistence.ml:178 | fs.load_file | systhread_host |
| 12 | lib/process/process_eio.ml:492 | unix.read | caller |

### ROUTE GET /api/v1/dashboard/scheduled-automation — 5 sites

| depth | site | primitive | mech |
|---|---|---|---|
| 8 | lib/workspace/workspace_utils_ops.ml:200 | safe.read_file | systhread_host |
| 8 | lib/workspace/workspace_utils_ops.ml:203 | safe.read_file | systhread_host |
| 9 | lib/backend/backend.ml:390 | eio.load | eio |
| 9 | lib/core/safe_ops.ml:351 | fs.load_file | systhread_host |
| 12 | lib/fs_compat/fs_compat_base_io.ml:130 | stdlib.really_input | caller |

### ROUTE GET /api/v1/tui/preferences — 3 sites

| depth | site | primitive | mech |
|---|---|---|---|
| 2 | lib/tui_preference.ml:400 | fs.load_file | systhread_host |
| 5 | lib/fs_compat/fs_compat_base_io.ml:130 | stdlib.really_input | caller |
| 9 | lib/config/env_config_core.ml:466 | stdlib.in_channel | caller |

### ROUTE GET /api/v1/dashboard/health-line — 21 sites

| depth | site | primitive | mech |
|---|---|---|---|
| 8 | lib/keeper/keeper_meta_store.ml:222 | safe.read_file | systhread_host |
| 8 | lib/keeper/keeper_meta_store.ml:225 | safe.read_file | systhread_host |
| 9 | lib/candle_config/candle_config.ml:303 | stdlib.in_channel | caller |
| 9 | lib/core/safe_ops.ml:360 | fs.load_file | systhread_host |
| 10 | lib/keeper/keeper_status_metrics.ml:272 | dj.read_recent | read_pool |
| 11 | lib/fs_compat/fs_compat_private_jsonl_write.ml:133 | unix.read | caller |
| 11 | lib/keeper/keeper_types_profile_toml_io.ml:107 | safe.read_file | systhread_host |
| 11 | lib/workspace/workspace_utils_ops.ml:71 | safe.read_file | systhread_host |
| 12 | lib/auth/auth_credential_base.ml:108 | stdlib.in_channel | caller |
| 12 | lib/backend/backend.ml:390 | eio.load | eio |
| 12 | lib/fs_compat/fs_compat_private_jsonl_write.ml:101 | unix.read | caller |
| 12 | lib/workspace/workspace_utils_ops.ml:102 | fs.load_file | systhread_host |
| 13 | lib/core/safe_ops.ml:351 | fs.load_file | systhread_host |
| 13 | lib/dated_jsonl/dated_jsonl.ml:1569 | fs.fold_appended_lines | systhread_host |
| 13 | lib/fs_compat/fs_compat_base_io.ml:130 | stdlib.really_input | caller |
| 13 | lib/workspace/workspace_utils_ops.ml:200 | safe.read_file | systhread_host |
| 13 | lib/workspace/workspace_utils_ops.ml:203 | safe.read_file | systhread_host |
| 14 | lib/dated_jsonl/dated_jsonl.ml:723 | stdlib.really_input | caller |
| 14 | lib/fs_compat/fs_compat_private_jsonl_transaction.ml:562 | unix.read | caller |
| 15 | lib/dated_jsonl/dated_jsonl.ml:533 | stdlib.really_input | caller |
| 16 | lib/config/env_config_core.ml:466 | stdlib.in_channel | caller |

### ROUTE GET /api/v1/operator — 1 sites

| depth | site | primitive | mech |
|---|---|---|---|
| 12 | lib/auth/auth_credential_base.ml:108 | stdlib.in_channel | caller |

### ROUTE PREFIX_GET /api/v1/keepers/ — 98 sites

| depth | site | primitive | mech |
|---|---|---|---|
| 2 | lib/dashboard_eval_feed/dashboard_eval_feed.ml:198 | fs.load_owned | systhread_host |
| 2 | lib/keeper/keeper_operator_note.ml:132 | fs.load_file | systhread_host |
| 2 | lib/keeper/keeper_response_feedback.ml:151 | fs.load_jsonl | systhread_host |
| 2 | lib/keeper_tool_call_log.ml:1504 | dj.range | read_pool |
| 2 | lib/server/server_dashboard_http_keeper_api.ml:73 | dj.read_recent | read_pool |
| 3 | lib/keeper/keeper_memory_os_events.ml:212 | fs.load_file | systhread_host |
| 3 | lib/keeper/keeper_memory_source_current.ml:351 | fs.load_file | systhread_host |
| 3 | lib/keeper/keeper_next_request_forecast.ml:381 | dj.read_recent | read_pool |
| 3 | lib/keeper/keeper_prompt_capture.ml:165 | fs.load_file | systhread_host |
| 3 | lib/keeper/keeper_raw_trace_reader.ml:233 | fs.load_owned_prefix | systhread_host |
| 3 | lib/keeper/keeper_raw_trace_reader.ml:285 | fs.load_owned | systhread_host |
| 3 | lib/server/server_keeper_turn_records.ml:15 | dj.read_recent | read_pool |
| 3 | lib/telemetry_coverage_gap/telemetry_coverage_gap.ml:121 | dj.read_recent | read_pool |
| 3 | lib/trajectory/trajectory.ml:1043 | dj.load_tail | read_pool |
| 3 | lib/trajectory/trajectory.ml:880 | fs.load_file | systhread_host |
| 4 | lib/keeper/keeper_memory_os_current_read_anchor.ml:31 | fs.load_file | systhread_host |
| 4 | lib/keeper/keeper_tool_result_file.ml:85 | fs.load_owned_prefix | systhread_host |
| 4 | lib/server/server_dashboard_http_keeper_runtime_manifest_scan.ml:338 | dj.load_tail | read_pool |
| 5 | lib/auth/auth_credential_base.ml:108 | stdlib.in_channel | caller |
| 5 | lib/build_identity.ml:196 | stdlib.really_input | caller |
| 5 | lib/fs_compat/fs_compat_base_io.ml:130 | stdlib.really_input | caller |
| 5 | lib/keeper/keeper_checkpoint_store_decode.ml:139 | fs.load_owned | systhread_host |
| 5 | lib/keeper/keeper_github_identity.ml:473 | fs.load_owned | systhread_host |
| 5 | lib/keeper/keeper_librarian_context.ml:153 | stdlib.in_channel | caller |
| 5 | lib/keeper/keeper_memory_os_current_journal.ml:29 | fs.load_file | systhread_host |
| 5 | lib/keeper/keeper_memory_os_current_journal.ml:46 | fs.load_file | systhread_host |
| 5 | lib/server/server_dashboard_http_keeper_api_scan_summary.ml:36 | fs.fold_jsonl_lines | systhread_host |
| 5 | lib/tool_blob_store/tool_blob_store.ml:321 | fs.load_owned | systhread_host |
| 6 | lib/candle_config/candle_config.ml:303 | stdlib.in_channel | caller |
| 6 | lib/config/env_config_core.ml:466 | stdlib.in_channel | caller |
| 6 | lib/fs_compat/fs_compat_owned_file.ml:248 | unix.read | caller |
| 6 | lib/fs_compat/fs_compat_private_jsonl_read.ml:396 | unix.read | caller |
| 6 | lib/keeper/keeper_autonomous_turn_source.ml:606 | dj.read_recent | read_pool |
| 6 | lib/keeper/keeper_chat_history_page.ml:73 | stdlib.really_input | caller |
| 6 | lib/keeper/keeper_checkpoint_object_store.ml:57 | fs.load_owned | systhread_host |
| 6 | lib/keeper/keeper_checkpoint_store_retained.ml:154 | fs.load_owned | systhread_host |
| 6 | lib/keeper/keeper_execution_receipt.ml:586 | dj.read_recent | read_pool |
| 6 | lib/keeper/keeper_librarian_progress_file.ml:60 | fs.load_file | systhread_host |
| 6 | lib/keeper/keeper_librarian_unread_ledger.ml:25 | fs.load_file | systhread_host |
| 6 | lib/keeper/keeper_meta_store.ml:222 | safe.read_file | systhread_host |
