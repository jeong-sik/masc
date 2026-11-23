module M = Tool_blob_maintenance
module Board = Masc_board_handlers.Board_paths

let tree name = M.Store { name; classification = M.In_scope M.Tree }
let payload_tree name = M.Store { name; classification = M.In_scope M.Payload_tree }
let file name = M.Store { name; classification = M.In_scope M.File }
let excluded reason name = M.Store { name; classification = M.Excluded reason }
let no_reference = excluded M.Writes_no_reference

let finder_metadata = excluded M.Finder_metadata M.finder_metadata_name

let unpublished_writes =
  M.Names { matches = Fs_compat.is_unpublished_write_name; reason = M.Unpublished_write }
;;

(* Every dated store but schedule signals is one directory below .masc. *)
let dated_store root =
  let name = Dated_jsonl.Store.Root.relative_path root in
  let open Dated_jsonl.Store.Root in
  match root with
  (* Tool-call rows can be the only owner of a result. The bounded wire
     capture owns its references for as long as its row stays in retention. *)
  | Tool_calls | Wire_capture -> Some (tree name)
  | Transition_audit
  | Audit_approvals
  | Tool_events
  | Verdicts
  | Audit
  | Telemetry
  | Events
  | Tool_usage
  | Agent_core_events
  | Costs
  | Provider_usage_history
  | Telemetry_coverage_gaps -> Some (no_reference name)
  (* Rows carry observability previews truncated to 200 bytes
     ([Observability_redact.default_max_len]) and [_seq] is a plain counter;
     no reader resolves blobs from here, while authoritative stores
     ([tool_calls], [wire-capture], [board_posts.jsonl], [keepers]) stay in
     scope. *)
  | Activity_events -> Some (excluded M.Truncated_copies name)
  (* [schedules/signals]: inside the schedule directory classified below. *)
  | Schedule_signals -> None
;;

let lane_addons =
  M.Place
    { name = Lane_addon_store.name_in_masc_dir
    ; entries =
        [ (* Prepared evidence stays owned before its message commits. *)
          tree Lane_addon_store.broadcasts_directory
        ; excluded M.Settled_archive Lane_addon_store.tool_request_archive_directory
          (* Evidence retains original packet bytes as well as JSON input
             and model output. Scan embedded tool blob references without
             requiring arbitrary packet payloads to be JSON records. *)
        ; payload_tree "evidence"
        ; payload_tree "sampling-evidence"
        ; tree "host-results"
        ; tree "sampling"
        ; tree "sampling-outcomes"
        ; no_reference Lane_addon_store.actions_directory
        ; no_reference Lane_addon_store.bindings_directory
        ; tree Lane_addon_store.exact_requests_directory
        ; tree Lane_addon_store.tool_request_owners_directory
        ; tree Lane_addon_store.tool_request_bodies_directory
        ; no_reference Lane_addon_store.observations_directory
        ; no_reference Lane_addon_store.sequences_directory
        ; no_reference Lane_addon_asks.dirname
        ; no_reference Lane_addon_document_owner.dirname
        ; no_reference Lane_addon_runtime.kept_files_dirname
        ; no_reference Lane_addon_runtime.native_claims_directory
        ; finder_metadata
        ; unpublished_writes
        ]
    }
;;

let workspace =
  List.filter_map dated_store Dated_jsonl.Store.Root.all
  @ [ tree Keeper_gate_path.dirname
    ; tree Common.keepers_runtime_dirname
    ; tree Keeper_chat_store.chat_dirname
    ; tree Workspace_utils_paths_backend.messages_dirname
    ; tree Workspace_init.traces_dirname
    ; tree Keeper_owned_job_invocation.requests_dirname
      (* Published reports own every revision, whatever chat or logs keep. *)
    ; tree Published_artifact_store.dirname
      (* Imported project sources can outlive their tool or chat row. *)
    ; tree Artifact_project_source_store.dirname
    ; tree Artifact_project_build_store.dirname
    ; file (Board.persisted_filename Board.Posts)
    ; lane_addons
    ; excluded M.Blob_store Tool_blob_store.dirname
    ; excluded M.Sweep_record Tool_blob_maintenance.dirname
    ; excluded M.Truncated_copies (Common.keeper_runtime_store_dirname Common.Keeper_trajectories)
    ; excluded M.Operator_config Config_dir_resolver.config_dirname
    ; excluded M.Repository_mirror Config_dir_resolver.repos_dirname
    ; finder_metadata
    ; unpublished_writes
    ; M.Names
        { matches = Runtime_antigravity_home.is_keeper_prepare_lock_name
        ; reason = M.Writes_no_reference
        }
    ; no_reference Workspace_utils_paths_backend.agents_dirname
    ; no_reference Workspace_utils_paths_backend.state_filename
    ; no_reference Workspace_utils_paths_backend.archive_filename
    ; no_reference Workspace_utils_paths_backend.tasks_dirname
    ; no_reference Workspace_broadcast.mention_outbox_dirname
    ; no_reference Workspace_broadcast.mention_outbox_quarantine_dirname
    ; no_reference (Board.persisted_filename Board.Reactions)
    ; no_reference (Board.persisted_filename Board.Sub_boards)
    ; no_reference (Board.persisted_filename Board.Votes)
    ; no_reference Common.auth_dirname
      (* The folder of the persons of a multi-account installation holds their
         logins, keys, Keeper conversations and the homes of their official
         clients. None writes a reference. A person's turn gives its client no
         tool of masc (no --mcp-config, test_server_preview_keeper_turn), so no
         output of a masc tool is stored for it. The person MCP answers with
         the text of its routes. *)
    ; no_reference Runtime_account_home_layout.accounts_dir
      (* Operator and Keeper vendor CLI homes under [.masc/official-clients/]
         (codex, claude, antigravity, codex-workspaces) hold logins,
         caches, symlinks, and vendor logs that MASC never resolves blobs from.
         MASC's own official-client outbox and consumed tool results sit under
         [keepers/], which remains in scope. *)
    ; excluded M.Vendor_client_home Runtime_account_home_layout.clients_dir
    ; no_reference Common.searxng_dirname
    ; no_reference Common.tui_dirname
    ; no_reference Common.tui_music_dirname
    ; no_reference Common.tui_account_login_filename
    ; no_reference Common.tui_play_pending_filename
    ; no_reference Common.tui_artifact_share_pending_filename
    ; no_reference Config_dir_resolver.constitution_dirname
    ; no_reference Config_dir_resolver.locks_dirname
    ; no_reference Config_dir_resolver.credentials_dirname
    ; no_reference Config_dir_resolver.tmp_dirname
    ; no_reference Config_dir_resolver.wiki_dirname
    ; no_reference Config_dir_resolver.microvm_dirname
    ; no_reference Config_dir_resolver.runtime_dirname
    ; no_reference Dated_jsonl.Store.decision_audit_dirname
    ; no_reference Schedule_runner.schedules_dirname
    ; no_reference Schedule_store.schedules_filename
    ; no_reference Goal_store.goals_filename
    ; no_reference Goal_store.goal_events_filename
    ; no_reference Goal_measurement.filename
    ; no_reference Goal_verification.verifications_filename
    ; no_reference Goal_delivery.notification_lock_key
    ; no_reference Goal_verification_run_registry.storage_filename
    ; no_reference Verification_run_registry.storage_filename
    ; no_reference Exact_lane_run_registry.storage_filename
    ; no_reference Fusion_run_registry.storage_filename
    ; no_reference Fusion_delivery_obligation.root_dirname
    ; no_reference Artifact_draft_store.dirname
    ; no_reference Tool_misc_web_fetch.artifacts_dirname
    ; no_reference Voice_bridge_core.audio_dirname
    ; no_reference Voice_config.filename
    (* The voice session store was deleted; a workspace that ran it still has the
       directory, so the name stays a known writes-no-reference entry. *)
    ; no_reference "voice_sessions"
    ; no_reference Keeper_board_attention_candidate.dirname
    ; no_reference Keeper_board_attention_partition.dirname
    ; no_reference Keeper_connector_names.dirname
    ; no_reference Keeper_execute_output_files.capture_dirname
    ; no_reference Keeper_external_attention.dirname
    ; no_reference Keeper_identity_tools.identity_dirname
    ; no_reference Keeper_efficiency.cache_dirname
    ; no_reference Keeper_volume_repair.store_dirname
    ; no_reference Keeper_ask_store.dirname
    (* The person-notes store was deleted; a workspace that ran it still has the
       directory, so the name stays a known writes-no-reference entry. *)
    ; no_reference "keeper_person_notes"
    ; no_reference Keeper_microvm_shim_readiness.recovery_namespace
    ; no_reference Keeper_paused_work_disposition_receipt.store_dirname
    ; no_reference Keeper_secret_projection.secrets_dirname
    ; no_reference Keeper_secret_redaction.ssh_dirname
    ; no_reference Candle_ledger.file_name
    ; no_reference Task.Planning_eio.current_task_filename
    ; no_reference Task.Planning_eio.trash_dirname
    ; no_reference Dated_jsonl.count_cache_filename
    ; no_reference Telemetry_unified.trajectory_summary_cache_filename
    ; no_reference Server_mcp_transport_http_session.sessions_filename
    ; no_reference Host_fd_pressure_poller.state_filename
    ; no_reference Builtin_skill_package.skills_dirname
    ; no_reference Builtin_skill_package.state_dirname
    ; no_reference Common.dos_dirname
    ; no_reference Common.msx_dirname
    ; no_reference Fs_compat.Publication_recovery.directory_leaf
    ; no_reference Metrics_store_eio.metrics_dirname
    ; no_reference Operator_pending_confirm.operator_dirname
    ; no_reference Config_dir_resolver.packages_dirname
    ; no_reference Browser_goal_space.filename
    ; no_reference Runtime_params.params_filename
    ; no_reference Runtime_params.audit_filename
    ; no_reference Play_room.dirname
    ; no_reference Prompt_preset.presets_dirname
    ; no_reference Prompt_preset.staging_dirname
    ; no_reference Prompt_override_persistence.filename
    ; no_reference Published_artifact_check_store.dirname
    ; no_reference Run_eio.runs_dirname
    ; no_reference Tool_metrics_store.database_filename
    ; no_reference World_memory_store.database_filename
    ; no_reference Workspace_memory_ledger.dirname
    ; no_reference Presentation_runtime_dependencies.runtime_tools_dirname
    ]
;;

let config_keepers =
  [ M.Keeper_files { suffix = Config_dir_resolver.keeper_toml_suffix; reason = M.Operator_config }
  ; M.Keeper_files { suffix = Keeper_vision_tool.vision_store_suffix; reason = M.Other_media_store }
    (* The Librarian working context keeps whole chat operations, media
       sources included. *)
  ; M.Decoded_keeper_files
      { suffix = Keeper_librarian_context.filename_suffix
      ; decode =
          (fun path ->
             Keeper_librarian_context.read_committed_file path
             |> Result.map (Option.map Keeper_librarian_context.snapshot_json))
      }
    (* The recall index names the published context. The current recall pin
       and the dated recall history own it, and recall publishes it again
       from the committed working context when it is gone. *)
  ; M.Keeper_files
      { suffix = Keeper_librarian_context_recall.filename_suffix
      ; reason = M.Repairable_pointer
      }
    (* The Memory OS stores in this directory carry claim text, timestamps,
       memory and trace ids, request ids, revision numbers, original source
       paths and message digests — never a tool blob key. The scan decodes only
       normalized artifact references, so reading any of them adds nothing.
       Leave them unclassified and the sweep's unclassified gate refuses every
       deletion in a workspace where a Keeper has memory. *)
  ; M.Keeper_files
      { suffix = Keeper_memory_os_current_layout.suffix
      ; reason = M.Writes_no_reference
      }
  ; M.Keeper_files
      { suffix = Keeper_memory_source_current.suffix
      ; reason = M.Writes_no_reference
      }
    (* Memory history events name a memory id, a trace id and a query. *)
  ; M.Keeper_files
      { suffix = Keeper_memory_os_events.suffix
      ; reason = M.Writes_no_reference
      }
    (* A commit log line carries facts, the write or adoption that caused it,
       offsets into the turn log and what the Keeper was doing — no tool blob
       key. The writer's lock is an empty file. *)
  ; M.Keeper_files
      { suffix = Librarian_log_store.suffix
      ; reason = M.Writes_no_reference
      }
  ; M.Keeper_files
      { suffix = Librarian_log_store.archive_suffix
      ; reason = M.Writes_no_reference
      }
  ; M.Keeper_files
      { suffix = Librarian_writer.lock_suffix
      ; reason = M.Writes_no_reference
      }
  ; M.Keeper_files
      { suffix = Keeper_memory_digest.suffix
      ; reason = M.Writes_no_reference
      }
  ; M.Keeper_files
      { suffix = Keeper_memory_search_index.db_suffix
      ; reason = M.Writes_no_reference
      }
    (* Per-Keeper compaction WAL stores immutable compaction anchors, raw
       verbatim archived turns, and active microcompacted blob handles. Scan
       all three through the read-only SQLite decoder so active handles stay
       sweep-protected and SQLite sidecars (-wal/-shm/-journal) stay classified. *)
  ; M.Decoded_keeper_files
      { suffix = Keeper_compaction.db_suffix
      ; decode = Keeper_compaction.decode_live_blob_references_json
      }
    (* Per-Keeper canonical turn WAL stores unified Agent Core HTTP and
       ACP/Official CLI turns for cross-runtime failover continuity. Scan live
       JSON payloads through the read-only SQLite decoder so any referenced
       tool blobs stay sweep-protected and SQLite sidecars stay classified. *)
  ; M.Decoded_keeper_files
      { suffix = Keeper_canonical_turn_store.db_suffix
      ; decode = Keeper_canonical_turn_store.decode_live_blob_references_json
      }
  ; finder_metadata
  ; unpublished_writes
  ]
;;

let scope =
  { M.workspace
  ; config_keepers_dir =
      (fun ~base_path -> Config_dir_resolver.keepers_dir_for_base_path ~base_path)
  ; config_keepers
  ; derived =
      [ M.Suffix File_lock_eio.lock_suffix
      ; M.Suffix Common.recovery_mirror_suffix
      ; M.Suffix Common.sqlite_wal_suffix
      ; M.Suffix Common.sqlite_shm_suffix
      ; M.Suffix Common.sqlite_journal_suffix
      ; M.Parsed Keeper_memory_os_current.rejected_base
      ]
  }
;;
