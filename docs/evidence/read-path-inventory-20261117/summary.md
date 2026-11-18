## A. Read call sites by kind, tree and layer

| kind | lib/call | lib/wrapper | bin/call | all |
|---|---|---|---|---|
| content | 461 | 34 | 59 | 554 |
| meta | 1069 | 117 | 85 | 1271 |
| open | 104 | 25 | 23 | 152 |
| dir | 175 | 13 | 15 | 203 |
| db | 84 | 0 | 0 | 84 |

## B. lib call sites by kind and mech

| kind | mech | sites |
|---|---|---|
| content | caller | 135 |
| content | eio | 10 |
| content | read_pool | 29 |
| content | systhread_host | 287 |
| db | caller | 84 |
| dir | caller | 154 |
| dir | eio | 1 |
| dir | systhread_host | 20 |
| meta | caller | 968 |
| meta | eio | 91 |
| meta | systhread_host | 10 |
| open | caller | 104 |

## C. lib call content sites by reaching entry (depth <= 30)

| reached from | sites |
|---|---|
| none of these (boot, tool, other loop or unresolved) | 134 |
| route | 116 |
| route + refresh loop | 19 |
| route + turn | 153 |
| route + turn + refresh loop | 32 |
| turn | 7 |

## D. Entries reaching the most lib call content sites

| entry | sites |
|---|---|
| ROUTE GET /api/v1/dashboard/agent_core/telemetry/summary | 223 |
| ROUTE PREFIX_POST /api/v1/keepers/ | 194 |
| Keeper_agent_run.run_turn | 192 |
| ROUTE GET /api/v1/gate/keepers | 178 |
| ROUTE GET /api/v1/gate/keeper-sandbox-status | 177 |
| ROUTE GET /api/v1/gate/keeper-status | 177 |
| ROUTE POST /api/v1/operator/confirm | 172 |
| ROUTE POST /api/v1/operator/action | 170 |
| ROUTE PREFIX_GET /api/v1/keepers/ | 84 |
| ROUTE POST /api/v1/keepers/memory-catch-up | 65 |
| ROUTE POST /api/v1/dashboard/agents/purge | 45 |
| ROUTE POST /api/v1/tools/masc_goal_transition | 44 |
| ROUTE GET /mcp | 42 |
| ROUTE GET /mcp/operator | 42 |
| ROUTE ADD /mcp | 41 |
| ROUTE ADD /mcp/managed | 41 |
| ROUTE ADD /mcp/operator | 41 |
| ROUTE ADD /mcp/play | 41 |
| ROUTE GET /ag-ui/events | 41 |
| ROUTE GET /events/presence | 41 |

## E. Routes the TUI requests, content sites within reach


### ROUTE GET /api/v1/keepers/turns — 8 call sites, 5 wrapper sites

| depth | site | primitive | mech | layer |
|---|---|---|---|---|
| 7 | lib/keeper/keeper_shutdown_store.ml:913 | fs.load_file | systhread_host | call |
| 8 | lib/keeper_runtime/keeper_event_queue_persistence.ml:1087 | safe.read_json | systhread_host | call |
| 8 | lib/workspace/workspace_utils_ops.ml:200 | safe.read_file | systhread_host | call |
| 8 | lib/workspace/workspace_utils_ops.ml:203 | safe.read_file | systhread_host | call |
| 9 | lib/backend/backend.ml:390 | eio.load | eio | call |
| 9 | lib/core/safe_ops.ml:351 | fs.load_file | systhread_host | wrapper |
| 10 | lib/fs_compat/fs_compat_base_io.ml:130 | stdlib.really_input | caller | wrapper |
| 11 | lib/fs_compat/fs_compat_jsonl_read.ml:373 | unix.read | caller | wrapper |
| 12 | lib/keeper_runtime/keeper_event_queue_persistence.ml:468 | safe.read_file | systhread_host | call |
| 13 | lib/keeper_runtime/keeper_event_queue_quarantine.ml:66 | fs.load_file | systhread_host | call |
| 14 | lib/config/env_config_core.ml:466 | stdlib.in_channel | caller | call |
| 14 | lib/fs_compat/fs_compat_private_jsonl_read.ml:109 | unix.read | caller | wrapper |
| 14 | lib/fs_compat/fs_compat_private_jsonl_read.ml:80 | unix.read | caller | wrapper |

### ROUTE GET /api/v1/gate/keepers — 178 call sites, 24 wrapper sites

| depth | site | primitive | mech | layer |
|---|---|---|---|---|
| 5 | lib/auth/auth_credential_base.ml:108 | stdlib.in_channel | caller | call |
| 6 | lib/keeper/keeper_meta_store.ml:222 | safe.read_file | systhread_host | call |
| 6 | lib/keeper/keeper_meta_store.ml:225 | safe.read_file | systhread_host | call |
| 7 | lib/core/safe_ops.ml:360 | fs.load_file | systhread_host | wrapper |
| 7 | lib/keeper/keeper_status_detail.ml:477 | dj.read_recent | read_pool | call |
| 7 | lib/keeper/keeper_status_detail.ml:494 | dj.read_recent | read_pool | call |
| 7 | lib/tool_blob_store/tool_blob_store.ml:321 | fs.load_owned | systhread_host | call |
| 8 | lib/candle_config/candle_config.ml:303 | stdlib.in_channel | caller | call |
| 8 | lib/keeper/keeper_execution_receipt.ml:586 | dj.read_recent | read_pool | call |
| 9 | lib/keeper/keeper_checkpoint_store_decode.ml:139 | fs.load_owned | systhread_host | call |
| 9 | lib/keeper/keeper_checkpoint_store_retained.ml:154 | fs.load_owned | systhread_host | call |
| 9 | lib/keeper/keeper_next_request_forecast.ml:381 | dj.read_recent | read_pool | call |
| 9 | lib/keeper/keeper_official_client_session_store.ml:1109 | fs.load_file | systhread_host | call |
| 9 | lib/keeper/keeper_status_detail_observability.ml:8 | dj.read_recent | read_pool | call |
| 9 | lib/keeper/keeper_status_metrics.ml:272 | dj.read_recent | read_pool | call |
| 9 | lib/keeper/keeper_types_profile_toml_io.ml:107 | safe.read_file | systhread_host | call |
| 10 | lib/fs_compat/fs_compat_owned_file.ml:248 | unix.read | caller | wrapper |
| 10 | lib/fs_compat/fs_compat_private_jsonl_write.ml:133 | unix.read | caller | wrapper |
| 10 | lib/keeper/keeper_checkpoint_store_retained.ml:22 | fs.load_owned | systhread_host | call |
| 10 | lib/keeper/keeper_memory_recall.ml:60 | unix.read | caller | call |
| 10 | lib/keeper/keeper_shutdown_store.ml:913 | fs.load_file | systhread_host | call |
| 10 | lib/keeper/keeper_types_profile.ml:462 | safe.read_file | systhread_host | call |
| 10 | lib/tool_blob_store/tool_blob_store.ml:607 | fs.load_owned | systhread_host | call |
| 11 | lib/core/safe_ops.ml:351 | fs.load_file | systhread_host | wrapper |
| 11 | lib/dated_jsonl/dated_jsonl.ml:533 | stdlib.really_input | caller | wrapper |
| 11 | lib/fs_compat/fs_compat_base_io.ml:130 | stdlib.really_input | caller | wrapper |
| 11 | lib/fs_compat/fs_compat_private_jsonl_write.ml:101 | unix.read | caller | wrapper |
| 11 | lib/keeper/keeper_turn_up_config_persistence.ml:196 | safe.read_file | systhread_host | call |
| 11 | lib/keeper/keeper_types_profile.ml:318 | safe.read_file | systhread_host | call |
| 11 | lib/runtime/runtime_toml.ml:1250 | stdlib.in_channel | caller | call |
| 12 | lib/dated_jsonl/dated_jsonl.ml:1569 | fs.fold_appended_lines | systhread_host | wrapper |
| 12 | lib/dated_jsonl/dated_jsonl.ml:723 | stdlib.really_input | caller | wrapper |
| 12 | lib/fs_compat/fs_compat_jsonl_read.ml:373 | unix.read | caller | wrapper |
| 12 | lib/fs_compat/fs_compat_private_file_update.ml:649 | unix.read | caller | wrapper |
| 12 | lib/keeper/keeper_checkpoint_object_store.ml:57 | fs.load_owned | systhread_host | call |
| 12 | lib/keeper/keeper_checkpoint_store_canonical.ml:34 | unix.read | caller | call |
| 12 | lib/keeper/keeper_librarian_progress_file.ml:60 | fs.load_file | systhread_host | call |
| 12 | lib/keeper/keeper_librarian_unread_ledger.ml:25 | fs.load_file | systhread_host | call |
| 12 | lib/keeper/keeper_registry_tool_usage_persistence.ml:178 | fs.load_file | systhread_host | call |
| 12 | lib/process/process_eio.ml:492 | unix.read | caller | call |

### ROUTE GET /api/v1/dashboard/scheduled-automation — 3 call sites, 2 wrapper sites

| depth | site | primitive | mech | layer |
|---|---|---|---|---|
| 8 | lib/workspace/workspace_utils_ops.ml:200 | safe.read_file | systhread_host | call |
| 8 | lib/workspace/workspace_utils_ops.ml:203 | safe.read_file | systhread_host | call |
| 9 | lib/backend/backend.ml:390 | eio.load | eio | call |
| 9 | lib/core/safe_ops.ml:351 | fs.load_file | systhread_host | wrapper |
| 12 | lib/fs_compat/fs_compat_base_io.ml:130 | stdlib.really_input | caller | wrapper |

### ROUTE GET /api/v1/tui/preferences — 2 call sites, 1 wrapper sites

| depth | site | primitive | mech | layer |
|---|---|---|---|---|
| 2 | lib/tui_preference.ml:400 | fs.load_file | systhread_host | call |
| 5 | lib/fs_compat/fs_compat_base_io.ml:130 | stdlib.really_input | caller | wrapper |
| 9 | lib/config/env_config_core.ml:466 | stdlib.in_channel | caller | call |

### ROUTE GET /api/v1/dashboard/health-line — 20 call sites, 9 wrapper sites

| depth | site | primitive | mech | layer |
|---|---|---|---|---|
| 8 | lib/keeper/keeper_meta_store.ml:222 | safe.read_file | systhread_host | call |
| 8 | lib/keeper/keeper_meta_store.ml:225 | safe.read_file | systhread_host | call |
| 9 | lib/candle_config/candle_config.ml:303 | stdlib.in_channel | caller | call |
| 9 | lib/core/safe_ops.ml:360 | fs.load_file | systhread_host | wrapper |
| 10 | lib/keeper/keeper_status_metrics.ml:272 | dj.read_recent | read_pool | call |
| 10 | lib/operator/operator_control_snapshot.ml:436 | dj.read_recent | read_pool | call |
| 10 | lib/operator/operator_control_snapshot_action_log.ml:97 | fs.fold_jsonl_lines | systhread_host | call |
| 11 | lib/fs_compat/fs_compat_private_jsonl_write.ml:133 | unix.read | caller | wrapper |
| 11 | lib/keeper/keeper_types_profile_toml_io.ml:107 | safe.read_file | systhread_host | call |
| 11 | lib/workspace/workspace_utils_ops.ml:71 | safe.read_file | systhread_host | call |
| 12 | lib/auth/auth_credential_base.ml:108 | stdlib.in_channel | caller | call |
| 12 | lib/backend/backend.ml:390 | eio.load | eio | call |
| 12 | lib/fs_compat/fs_compat_private_jsonl_write.ml:101 | unix.read | caller | wrapper |
| 12 | lib/keeper/keeper_context_observation_projection.ml:85 | dj.read_recent | read_pool | call |
| 12 | lib/operator/operator_control_snapshot_tool_audit.ml:18 | dj.read_recent | read_pool | call |
| 12 | lib/workspace/workspace_utils_ops.ml:102 | fs.load_file | systhread_host | call |
| 13 | lib/core/safe_ops.ml:351 | fs.load_file | systhread_host | wrapper |
| 13 | lib/dated_jsonl/dated_jsonl.ml:1569 | fs.fold_appended_lines | systhread_host | wrapper |
| 13 | lib/fs_compat/fs_compat_base_io.ml:130 | stdlib.really_input | caller | wrapper |
| 13 | lib/workspace/workspace_utils_ops.ml:200 | safe.read_file | systhread_host | call |
| 13 | lib/workspace/workspace_utils_ops.ml:203 | safe.read_file | systhread_host | call |
| 14 | lib/dated_jsonl/dated_jsonl.ml:533 | stdlib.really_input | caller | wrapper |
| 14 | lib/dated_jsonl/dated_jsonl.ml:723 | stdlib.really_input | caller | wrapper |
| 14 | lib/fs_compat/fs_compat_private_jsonl_transaction.ml:562 | unix.read | caller | wrapper |
| 16 | lib/config/env_config_core.ml:466 | stdlib.in_channel | caller | call |
| 17 | lib/keeper/keeper_execution_receipt.ml:586 | dj.read_recent | read_pool | call |
| 17 | lib/keeper/keeper_memory_recall.ml:60 | unix.read | caller | call |
| 17 | lib/keeper_tool_call_log.ml:1572 | dj.read_recent | read_pool | call |
| 21 | lib/keeper_approval/audit_recent_index.ml:369 | unix.read | caller | call |

### ROUTE GET /api/v1/operator — 19 call sites, 9 wrapper sites

| depth | site | primitive | mech | layer |
|---|---|---|---|---|
| 7 | lib/operator/operator_control_snapshot.ml:436 | dj.read_recent | read_pool | call |
| 7 | lib/operator/operator_control_snapshot_action_log.ml:97 | fs.fold_jsonl_lines | systhread_host | call |
| 9 | lib/keeper/keeper_context_observation_projection.ml:85 | dj.read_recent | read_pool | call |
| 9 | lib/keeper/keeper_meta_store.ml:222 | safe.read_file | systhread_host | call |
| 9 | lib/keeper/keeper_meta_store.ml:225 | safe.read_file | systhread_host | call |
| 9 | lib/operator/operator_control_snapshot_tool_audit.ml:18 | dj.read_recent | read_pool | call |
| 10 | lib/core/safe_ops.ml:360 | fs.load_file | systhread_host | wrapper |
| 10 | lib/keeper/keeper_types_profile_toml_io.ml:107 | safe.read_file | systhread_host | call |
| 11 | lib/dated_jsonl/dated_jsonl.ml:533 | stdlib.really_input | caller | wrapper |
| 11 | lib/keeper/keeper_status_metrics.ml:272 | dj.read_recent | read_pool | call |
| 11 | lib/workspace/workspace_utils_ops.ml:71 | safe.read_file | systhread_host | call |
| 12 | lib/auth/auth_credential_base.ml:108 | stdlib.in_channel | caller | call |
| 12 | lib/backend/backend.ml:390 | eio.load | eio | call |
| 12 | lib/core/safe_ops.ml:351 | fs.load_file | systhread_host | wrapper |
| 12 | lib/workspace/workspace_utils_ops.ml:200 | safe.read_file | systhread_host | call |
| 12 | lib/workspace/workspace_utils_ops.ml:203 | safe.read_file | systhread_host | call |
| 13 | lib/fs_compat/fs_compat_private_jsonl_write.ml:133 | unix.read | caller | wrapper |
| 13 | lib/workspace/workspace_utils_ops.ml:102 | fs.load_file | systhread_host | call |
| 14 | lib/dated_jsonl/dated_jsonl.ml:1569 | fs.fold_appended_lines | systhread_host | wrapper |
| 14 | lib/fs_compat/fs_compat_base_io.ml:130 | stdlib.really_input | caller | wrapper |
| 14 | lib/fs_compat/fs_compat_private_jsonl_write.ml:101 | unix.read | caller | wrapper |
| 14 | lib/keeper/keeper_execution_receipt.ml:586 | dj.read_recent | read_pool | call |
| 14 | lib/keeper/keeper_memory_recall.ml:60 | unix.read | caller | call |
| 14 | lib/keeper_tool_call_log.ml:1572 | dj.read_recent | read_pool | call |
| 15 | lib/dated_jsonl/dated_jsonl.ml:723 | stdlib.really_input | caller | wrapper |
| 16 | lib/config/env_config_core.ml:466 | stdlib.in_channel | caller | call |
| 16 | lib/fs_compat/fs_compat_private_jsonl_transaction.ml:562 | unix.read | caller | wrapper |
| 18 | lib/keeper_approval/audit_recent_index.ml:369 | unix.read | caller | call |

### ROUTE PREFIX_GET /api/v1/keepers/ — 84 call sites, 14 wrapper sites

| depth | site | primitive | mech | layer |
|---|---|---|---|---|
| 2 | lib/dashboard_eval_feed/dashboard_eval_feed.ml:198 | fs.load_owned | systhread_host | call |
| 2 | lib/keeper/keeper_operator_note.ml:132 | fs.load_file | systhread_host | call |
| 2 | lib/keeper/keeper_response_feedback.ml:151 | fs.load_jsonl | systhread_host | call |
| 2 | lib/keeper_tool_call_log.ml:1504 | dj.range | caller | call |
| 2 | lib/server/server_dashboard_http_keeper_api.ml:73 | dj.read_recent | read_pool | call |
| 3 | lib/keeper/keeper_memory_os_events.ml:212 | fs.load_file | systhread_host | call |
| 3 | lib/keeper/keeper_memory_source_current.ml:351 | fs.load_file | systhread_host | call |
| 3 | lib/keeper/keeper_next_request_forecast.ml:381 | dj.read_recent | read_pool | call |
| 3 | lib/keeper/keeper_prompt_capture.ml:165 | fs.load_file | systhread_host | call |
| 3 | lib/keeper/keeper_raw_trace_reader.ml:233 | fs.load_owned_prefix | systhread_host | call |
| 3 | lib/keeper/keeper_raw_trace_reader.ml:285 | fs.load_owned | systhread_host | call |
| 3 | lib/server/server_keeper_turn_records.ml:15 | dj.read_recent | read_pool | call |
| 3 | lib/telemetry_coverage_gap/telemetry_coverage_gap.ml:121 | dj.read_recent | read_pool | call |
| 3 | lib/trajectory/trajectory.ml:1043 | dj.load_tail | read_pool | call |
| 3 | lib/trajectory/trajectory.ml:880 | fs.load_file | systhread_host | call |
| 4 | lib/keeper/keeper_memory_os_current_read_anchor.ml:31 | fs.load_file | systhread_host | call |
| 4 | lib/keeper/keeper_tool_result_file.ml:85 | fs.load_owned_prefix | systhread_host | call |
| 4 | lib/server/server_dashboard_http_keeper_runtime_manifest_scan.ml:338 | dj.load_tail | read_pool | call |
| 5 | lib/auth/auth_credential_base.ml:108 | stdlib.in_channel | caller | call |
| 5 | lib/build_identity.ml:196 | stdlib.really_input | caller | call |
| 5 | lib/fs_compat/fs_compat_base_io.ml:130 | stdlib.really_input | caller | wrapper |
| 5 | lib/keeper/keeper_checkpoint_store_decode.ml:139 | fs.load_owned | systhread_host | call |
| 5 | lib/keeper/keeper_github_identity.ml:473 | fs.load_owned | systhread_host | call |
| 5 | lib/keeper/keeper_librarian_context.ml:153 | stdlib.in_channel | caller | call |
| 5 | lib/keeper/keeper_memory_os_current_journal.ml:29 | fs.load_file | systhread_host | call |
| 5 | lib/keeper/keeper_memory_os_current_journal.ml:46 | fs.load_file | systhread_host | call |
| 5 | lib/server/server_dashboard_http_keeper_api_scan_summary.ml:36 | fs.fold_jsonl_lines | systhread_host | call |
| 5 | lib/tool_blob_store/tool_blob_store.ml:321 | fs.load_owned | systhread_host | call |
| 6 | lib/candle_config/candle_config.ml:303 | stdlib.in_channel | caller | call |
| 6 | lib/config/env_config_core.ml:466 | stdlib.in_channel | caller | call |
| 6 | lib/fs_compat/fs_compat_owned_file.ml:248 | unix.read | caller | wrapper |
| 6 | lib/fs_compat/fs_compat_private_jsonl_read.ml:396 | unix.read | caller | wrapper |
| 6 | lib/keeper/keeper_autonomous_turn_source.ml:606 | dj.read_recent | read_pool | call |
| 6 | lib/keeper/keeper_chat_history_page.ml:73 | stdlib.really_input | caller | call |
| 6 | lib/keeper/keeper_checkpoint_object_store.ml:57 | fs.load_owned | systhread_host | call |
| 6 | lib/keeper/keeper_checkpoint_store_retained.ml:154 | fs.load_owned | systhread_host | call |
| 6 | lib/keeper/keeper_execution_receipt.ml:586 | dj.read_recent | read_pool | call |
| 6 | lib/keeper/keeper_librarian_progress_file.ml:60 | fs.load_file | systhread_host | call |
| 6 | lib/keeper/keeper_librarian_unread_ledger.ml:25 | fs.load_file | systhread_host | call |
| 6 | lib/keeper/keeper_meta_store.ml:222 | safe.read_file | systhread_host | call |

### ROUTE GET /api/v1/dashboard/logs/stream — 0 call sites, 0 wrapper sites


### ROUTE GET /health @Server_routes_http_routes_frontend — 9 call sites, 3 wrapper sites

| depth | site | primitive | mech | layer |
|---|---|---|---|---|
| 7 | lib/auth/auth_credential_base.ml:108 | stdlib.in_channel | caller | call |
| 7 | lib/server/server_routes_http_runtime.ml:146 | stdlib.in_channel | caller | call |
| 8 | lib/build_identity.ml:196 | stdlib.really_input | caller | call |
| 10 | lib/web_dashboard.ml:186 | fs.load_owned | systhread_host | call |
| 11 | lib/config/env_config_core.ml:466 | stdlib.in_channel | caller | call |
| 11 | lib/installed_dashboard.ml:144 | fs.load_owned | systhread_host | call |
| 12 | lib/fs_compat/fs_compat_owned_file.ml:248 | unix.read | caller | wrapper |
| 14 | lib/process/process_eio.ml:492 | unix.read | caller | call |
| 14 | lib/workspace/workspace_utils_backend_setup.ml:30 | safe.read_file | systhread_host | call |
| 16 | lib/core/safe_ops.ml:351 | fs.load_file | systhread_host | wrapper |
| 17 | lib/process/process_eio_stderr.ml:77 | stdlib.in_channel | caller | call |
| 19 | lib/fs_compat/fs_compat_base_io.ml:130 | stdlib.really_input | caller | wrapper |
