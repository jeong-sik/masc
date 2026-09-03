(** Dashboard HTTP keeper — keepers_dashboard_json rendering.

    Extracted from server_dashboard_http.ml. Contains the keeper dashboard
    rendering: per-keeper metrics series, conversation history,
    memory bank, and diagnostic summaries. *)


open Dashboard_http_helpers
open Keeper_status_bridge

include Dashboard_http_keeper_detail

(** Runtime display constants and live runtime-id resolver moved
    to Dashboard_http_keeper_types (intra-library file split, 2026-05-16). *)
include Dashboard_http_keeper_types
module Outcomes = Dashboard_http_keeper_outcomes
module Trust = Dashboard_http_keeper_trust

let compute_outcomes_rollup = Outcomes.compute_outcomes_rollup

(* prompt_block_json / tokens_per_sec_json /
   last_latency_ms_json moved to Dashboard_http_keeper_types
   (intra-library file split, 2026-05-16). *)

let keeper_trust_json = Trust.keeper_trust_json

(* execution_trust_source / _producer / _dashboard_surface / _freshness_slo_s
   moved to Dashboard_http_keeper_types (intra-library file split,
   2026-05-16). *)

(* execution_receipt path/diagnostic helpers extracted to
   [Dashboard_http_keeper_execution_receipt] (godfile decomp). *)
let execution_receipt_store_pattern = Dashboard_http_keeper_execution_receipt.execution_receipt_store_pattern
let count_execution_receipt_entries = Dashboard_http_keeper_execution_receipt.count_execution_receipt_entries
let execution_receipt_coverage_gaps = Dashboard_http_keeper_execution_receipt.execution_receipt_coverage_gaps

let keeper_names (config : Workspace.config) =
  Keeper_meta_store.keeper_names config

let keeper_count (config : Workspace.config) : int =
  List.length (keeper_names config)

let configured_keeper_count (config : Workspace.config) : int =
  List.length (Keeper_meta_store.configured_keeper_names config)

let non_empty_trimmed_string_opt value =
  let trimmed = String.trim value in
  if trimmed = "" then None else Some trimmed

let degraded_keeper_dashboard_row
      ?error
      ~(site : string)
      (m : Keeper_meta_contract.keeper_meta)
  =
  let attention_reason = Option.value ~default:site error in
  let runtime_trust =
    `Assoc
      [ ("disposition", `String "Degraded")
      ; ("disposition_reason", `String site)
      ; ("operator_disposition", `String "blocked_runtime")
      ; ("operator_disposition_reason", `String site)
      ; ("needs_attention", `Bool true)
      ; ("attention_reason", `String attention_reason)
      ; ("next_human_action", `String "inspect_keeper_dashboard_worker")
      ]
  in
  let fd_observation = `Assoc (Keeper_fd_pressure.projection_fields ()) in
  let runtime_id =
    Keeper_meta_contract.runtime_id_of_meta m |> non_empty_trimmed_string_opt
  in
  let runtime_id_json = Json_util.string_opt_to_json runtime_id in
  let diagnostic =
    `Assoc
      ([ ("status", `String "degraded")
       ; ("reason", `String site)
       ; ("error", Json_util.string_opt_to_json error)
       ; ("fd_observation", fd_observation)
       ])
  in
  `Assoc
    ([ ("name", `String m.name)
     ; ( "keeper_id"
       , match m.keeper_id with
         | Some keeper_id -> `String (Keeper_id.Uid.to_string keeper_id)
         | None -> `Null )
     ; ("trace_id", `String (Keeper_id.Trace_id.to_string m.runtime.trace_id))
     ; ("current_task_id",
        Json_util.string_opt_to_json
          (Option.map Keeper_id.Task_id.to_string m.current_task_id))
     ; ("created_at", `String m.created_at)
     ; ("updated_at", `String m.updated_at)
     ; ("phase", `String "degraded")
     ; ("pipeline_stage", `String "degraded")
     ; ("status", `String "degraded")
     ; ("degraded", `Bool true)
     ; ("diagnostic", diagnostic)
     ; ("trust", runtime_trust)
     ; ("runtime_trust", runtime_trust)
     ; ("paused", `Bool m.paused)
     ; ("keepalive_running", `Bool false)
     ; ("total_turns", `Int m.runtime.usage.total_turns)
     ; ("runtime_id", runtime_id_json)
     ; ("runtime_canonical", runtime_id_json)
     ; ("selected_runtime_canonical", runtime_id_json)
      ; ("primary_model", `String (Keeper_meta_contract.runtime_id_of_meta m))
      ; ("active_model", `String (Keeper_status_runtime.active_model_of_meta m))
      ; ("active_model_label", `String (Keeper_status_runtime.active_model_label_of_meta m))
      ; ("last_model_used_label", `String (Keeper_status_runtime.active_model_label_of_meta m))
     ])

let invalid_profile_dashboard_row ~keeper_name error =
  let config_error =
    Keeper_types_profile.keeper_toml_config_error_of_load_error
      ~keeper_name
      error
    |> Keeper_types_profile.keeper_toml_config_error_to_json
  in
  `Assoc
    [ ("name", `String keeper_name)
    ; ("phase", `String "Offline")
    ; ("lifecycle_phase", `String "Offline")
    ; ("pipeline_stage", `String "offline")
    ; ("pipeline_stage_detail", `String "keeper_profile_load_failed")
    ; ("status", `String "blocked")
    ; ("degraded", `Bool true)
    ; ("needs_attention", `Bool true)
    ; ("attention_reason", `String "config_invalid")
    ; ("next_human_action", `String "fix_keeper_toml_config")
    ; ("config_error", config_error)
    ; ("paused", `Bool false)
    ; ("keepalive_running", `Bool false)
    ]

type keeper_activity_source =
  | Keeper_meta
  | Tool_call of Yojson.Safe.t
  | Approval_pending of Yojson.Safe.t

let nonempty_json_string_opt key json =
  match Safe_ops.json_string_opt key json with
  | Some value ->
      let value = String.trim value in
      if value = "" then None else Some value
  | None -> None

let positive_json_float_opt key json =
  match Safe_ops.json_float_opt key json with
  | Some value ->
      (match classify_float value with
       | FP_normal | FP_subnormal | FP_zero when value > 0.0 -> Some value
       | FP_normal | FP_subnormal | FP_zero | FP_infinite | FP_nan -> None)
  | None -> None

let activity_source_to_string = function
  | Keeper_meta -> "keeper_meta"
  | Tool_call _ -> "tool_call"
  | Approval_pending _ -> "approval_pending"

let activity_source_ts meta_ts = function
  | Keeper_meta -> meta_ts
  | Tool_call json
  | Approval_pending json ->
      (match positive_json_float_opt "ts" json with
       | Some ts -> ts
       | None -> 0.0)

let activity_source_tool_opt = function
  | Keeper_meta -> None
  | Tool_call json ->
      (match nonempty_json_string_opt "tool" json with
       | Some tool -> Some tool
       | None -> nonempty_json_string_opt "tool_name" json)
  | Approval_pending json ->
      (match nonempty_json_string_opt "tool" json with
       | Some tool -> Some tool
       | None -> nonempty_json_string_opt "tool_name" json)

let latest_keeper_tool_activity keeper_name =
  try
    match Keeper_tool_call_log.read_latest ~keeper_name () with
    | Some json ->
        (match positive_json_float_opt "ts" json with
         | Some _ -> Some json
         | None -> None)
    | None -> None
  with
  | Eio.Cancel.Cancelled _ as exn -> raise exn
  | exn ->
      Log.Dashboard.warn
        "keeper dashboard tool_call activity read failed for %s: %s"
        keeper_name (Printexc.to_string exn);
      None

let approval_row_newer left right =
  match positive_json_float_opt "ts" left, positive_json_float_opt "ts" right with
  | Some left_ts, Some right_ts -> left_ts > right_ts
  | Some _, None -> true
  | None, Some _
  | None, None -> false

let latest_rows_by_approval_id rows =
  let table = Hashtbl.create 16 in
  List.iter
    (fun row ->
      match nonempty_json_string_opt "id" row with
      | None -> ()
      | Some id ->
          let should_replace =
            match Hashtbl.find_opt table id with
            | None -> true
            | Some existing -> approval_row_newer row existing
          in
          if should_replace then Hashtbl.replace table id row)
    rows;
  Hashtbl.fold (fun _ row acc -> row :: acc) table []

let unresolved_pending_approval row =
  match nonempty_json_string_opt "event" row with
  | Some "pending" ->
      (match nonempty_json_string_opt "decision" row with
       | None -> true
       | Some _ -> false)
  | _ -> false

let latest_pending_approval ~base_path ~keeper_name =
  match
    Keeper_approval.Audit.read_recent
      ~base_path ~keeper_name ~n:128 ()
  with
  | Error _ as error -> error
  | Ok rows ->
    Ok
      (latest_rows_by_approval_id rows
       |> List.filter unresolved_pending_approval
       |> List.fold_left
            (fun acc row ->
              match acc with
              | None -> Some row
              | Some existing when approval_row_newer row existing -> Some row
              | Some _ -> acc)
            None)

let freshest_activity_source ~meta_ts ~latest_tool ~pending_approval =
  let candidates =
    (if meta_ts > 0.0 then [ Keeper_meta ] else [])
    @ (match latest_tool with Some json -> [ Tool_call json ] | None -> [])
    @ (match pending_approval with Some json -> [ Approval_pending json ] | None -> [])
  in
  List.fold_left
    (fun acc source ->
      match acc with
      | None -> Some source
      | Some best ->
          if activity_source_ts meta_ts source > activity_source_ts meta_ts best
          then Some source
          else acc)
    None
    candidates

let activity_age_json ~now_ts ts =
  if ts <= 0.0 then `Null else `Float (max 0.0 (now_ts -. ts))

let activity_at_json ts =
  if ts <= 0.0 then `Null
  else `String (Masc_domain.iso8601_of_unix_seconds ts)

let activity_turn_opt source =
  match source with
  | Keeper_meta -> None
  | Tool_call json -> Safe_ops.json_int_opt "turn" json
  | Approval_pending json -> Safe_ops.json_int_opt "turn" json

let activity_keeper_turn_id_opt source =
  match source with
  | Keeper_meta -> None
  | Tool_call json -> Safe_ops.json_int_opt "keeper_turn_id" json
  | Approval_pending json -> Safe_ops.json_int_opt "keeper_turn_id" json

let live_activity_json ~now_ts ~meta_ts source =
  let ts = activity_source_ts meta_ts source in
  `Assoc [
    ("source", `String (activity_source_to_string source));
    ("at", activity_at_json ts);
    ("age_s", activity_age_json ~now_ts ts);
    ("tool", Json_util.string_opt_to_json (activity_source_tool_opt source));
    ("turn", Json_util.int_opt_to_json (activity_turn_opt source));
    ("keeper_turn_id", Json_util.int_opt_to_json (activity_keeper_turn_id_opt source));
  ]

let pending_approval_gate_json ~now_ts row =
  let ts =
    match positive_json_float_opt "ts" row with
    | Some ts -> ts
    | None -> 0.0
  in
  `Assoc [
    ("kind", `String "approval_required");
    ("source", `String "audit_approvals");
    ("id", Json_util.string_opt_to_json (nonempty_json_string_opt "id" row));
    ("tool", Json_util.string_opt_to_json (activity_source_tool_opt (Approval_pending row)));
    ("turn_id", Json_util.int_opt_to_json (Safe_ops.json_int_opt "turn_id" row));
    ("at", activity_at_json ts);
    ("age_s", activity_age_json ~now_ts ts);
    ("disposition", Json_util.string_opt_to_json (nonempty_json_string_opt "disposition" row));
    ("disposition_reason",
      Json_util.string_opt_to_json (nonempty_json_string_opt "disposition_reason" row));
  ]

let pending_approval_summary row =
  let tool =
    match activity_source_tool_opt (Approval_pending row) with
    | Some tool -> tool
    | None -> "tool"
  in
  Printf.sprintf "승인 대기 · %s" tool

let running_keeper_count (config : Workspace.config) : int =
  keeper_names config
  |> List.fold_left
       (fun count name ->
         match Keeper_meta_store.read_meta config name with
         | Ok (Some meta) when runtime_keepalive_running config meta -> count + 1
         | _ -> count)
       0

(* #10710: bounded fiber pool for per-keeper dashboard enrichment. Each
   keeper's metadata + metrics JSONL reads are independent, so the work is
   embarrassingly parallel; the cap keeps us from burning more file
   descriptors / scheduler slots than the render needs. Mirrors
   [Dashboard_execution.dashboard_enrich_max_fibers]. *)
let dashboard_keeper_max_fibers = 8

let keepers_dashboard_json ?(compact = false) (config : Workspace.config) : Yojson.Safe.t =
  let include_goals = true in
  let history_fragment_filter_enabled =
    bool_default_true_of_env "MASC_KEEPER_HISTORY_FRAGMENT_FILTER"
  in
  let series_points = 120 in
  let names =
    keeper_names config @ Keeper_meta_store.configured_keeper_names config
    |> List.sort_uniq String.compare
  in
  let now_ts = Time_compat.now () in
  (* #10710: fiber-batched keeper I/O. Each keeper's metadata + metrics reads
     run concurrently across a bounded fiber pool ([dashboard_keeper_max_fibers])
     instead of an unbounded [Eio.Fiber.all] fan-out. The enrich body has no
     shared mutable state, so results are collected positionally by
     [Eio.Fiber.List.map] and filter_map'd below. *)
  let rows =
    Eio.Fiber.List.map
      ~max_fibers:dashboard_keeper_max_fibers
      (fun name ->
      let row =
      try
      match
        Keeper_types_profile.load_keeper_profile_defaults_result_for_base_path
          ~base_path:config.base_path
          name
      with
      | Error error -> Some (invalid_profile_dashboard_row ~keeper_name:name error)
      | Ok _ ->
      match Keeper_meta_store.read_meta config name with
      | Error _ | Ok None -> None
      | Ok (Some (m : Keeper_meta_contract.keeper_meta)) ->
          let created_ts =
            Workspace_resilience.Time.parse_iso8601_opt m.created_at
            |> Option.value ~default:0.0
          in
          let keeper_age_s = Keeper_status_metrics.age_seconds_opt ~now_ts created_ts in
          let last_turn_ago_s =
            Keeper_status_metrics.age_seconds_opt ~now_ts m.runtime.usage.last_turn_ts
          in
          let last_handoff_ago_s =
            Keeper_status_metrics.age_seconds_opt ~now_ts m.runtime.last_handoff_ts
          in
          let last_proactive_ago_s =
            Keeper_status_metrics.age_seconds_opt ~now_ts m.runtime.proactive_rt.last_ts
          in
          let last_visible_proactive_ago_s =
            Keeper_status_metrics.age_seconds_opt ~now_ts m.runtime.proactive_rt.last_visible_ts
          in
          (* C-3 fix: compute last_activity from the most recent activity timestamp
             to avoid showing misleading staleness when agent is actually active *)
          let meta_activity_ts =
            List.fold_left max 0.0
              [ m.runtime.usage.last_turn_ts; m.runtime.proactive_rt.last_ts; m.runtime.last_handoff_ts;
                created_ts ]
          in
          let latest_tool_activity = latest_keeper_tool_activity m.name in
          let pending_approval, approval_audit_state =
            match
              latest_pending_approval
                ~base_path:config.base_path
                ~keeper_name:m.name
            with
            | Ok pending -> pending, `Assoc [ "state", `String "ready" ]
            | Error error ->
              ( None
              , `Assoc
                  [ "state", `String "unavailable"
                  ; ( "stage"
                    , `String
                        (Keeper_approval.Audit.read_stage_to_string error.stage) )
                  ; "error", `String error.detail
                  ] )
          in
          let activity_source =
            freshest_activity_source
              ~meta_ts:meta_activity_ts
              ~latest_tool:latest_tool_activity
              ~pending_approval
          in
          let last_activity_ts =
            match activity_source with
            | Some source -> activity_source_ts meta_activity_ts source
            | None -> 0.0
          in
          let last_activity_ago_s =
            Keeper_status_metrics.age_seconds_opt ~now_ts last_activity_ts
          in
          let live_activity_fields =
            let source_json =
              match activity_source with
              | Some source -> `String (activity_source_to_string source)
              | None -> `Null
            in
            let activity_json =
              match activity_source with
              | Some source -> live_activity_json ~now_ts ~meta_ts:meta_activity_ts source
              | None -> `Null
            in
            let gate_json =
              match pending_approval with
              | Some row -> pending_approval_gate_json ~now_ts row
              | None -> `Null
            in
            [
              ("last_activity_source", source_json);
              ("last_activity_at", activity_at_json last_activity_ts);
              ("live_activity", activity_json);
              ("current_gate", gate_json);
              ("approval_audit_state", approval_audit_state);
            ]
            @
            (match pending_approval with
             | Some row -> [ ("runtime_blocker_summary", `String (pending_approval_summary row)) ]
             | None -> [])
          in
          let trace_history_count = List.length m.runtime.trace_history in
          (* RFC-0149 §3.3 — removed [_effective_runtime_id] zombie
             binding (commit f0075c3611, "domain-owned counter").  The
             bound name was unused; the line existed only to trigger
             [Runtime_metrics.on_resolve_live_fallback] through the
             silent-fallback path — exactly the workaround RFC-0149
             §3.3 sunsets.  No replacement needed: unresolved runtimes
             surface on the canonical JSON field via the Result-returning
             resolver at the other call site below. *)
          let metrics_store = Keeper_types_support.keeper_metrics_store config m.name in
          (* Cap metrics lines to avoid O(n) slowdown as keepers accumulate turns.
             [series_points] is both the read and output bound. *)
          let metrics_cap = series_points in
          let metrics_lines = Dated_jsonl.read_recent_lines metrics_store metrics_cap in
          let parsed_metrics =
            Fs_compat.parse_jsonl_lines
              ~source:"keeper_dashboard_metrics"
              metrics_lines
            |> fst
          in
          let metrics_series_items, metrics_window_summary =
            compute_metrics_window
              ~parsed_metrics ~compact ~series_points
          in
          let metrics_series = `List metrics_series_items in

          let provider_health_json = `Null in

          let history_path =
            Filename.concat
              (Filename.concat (Keeper_types_profile.session_base_dir config) (Keeper_id.Trace_id.to_string m.runtime.trace_id))
              "history.jsonl"
          in
          let ( conversation_tail,
                k2k_recent,
                k2k_mentions,
                conversation_raw_count,
                conversation_fragment_count,
                conversation_fragment_filtered_count ) =
            keeper_history_summary_json
              ~all_keeper_names:names
              ~keeper_name:m.name
              ~history_path
              ~filter_fragments:history_fragment_filter_enabled
          in
          let conversation_tail_count =
            match conversation_tail with
            | `List xs -> List.length xs
            | _ -> 0
          in
          let conversation_items =
            match conversation_tail with
            | `List xs -> xs
            | _ -> []
          in
          let recent_preview_for_role role_name =
            let role_name = String.lowercase_ascii role_name in
            conversation_items
            |> List.fold_left
                 (fun acc item ->
                   let role =
                     Safe_ops.json_string ~default:"" "role" item
                     |> String.lowercase_ascii
                     |> String.trim
                   in
                   if String.equal role role_name then
                     let preview =
                       Safe_ops.json_string ~default:"" "preview" item |> String.trim
                     in
                     if preview = "" then acc else Some preview
                   else
                     acc)
                 None
          in
          let k2k_count =
            match k2k_recent with
            | `List xs -> List.length xs
            | _ -> 0
          in
          let keepalive_running = runtime_keepalive_running config m in
          let keepalive_interval_s =
            Runtime_params.get Runtime_settings.keeper_keepalive_interval_sec
            |> float_of_int
          in
          let snapshot_interval_s =
            Runtime_params.get Runtime_settings.keeper_snapshot_sec
            |> float_of_int
          in
          let heartbeat_stale_after_s =
            Keeper_status_runtime.keeper_heartbeat_stale_after_s
              ~keepalive_interval_s
              ~snapshot_interval_s
          in
          let registry_entry =
            Keeper_registry.get ~base_path:config.base_path m.name in
          let phase =
            match registry_entry with
            | Some entry -> Some (Keeper_state_machine.phase_to_string entry.phase)
            | None -> None
          in
          let conditions_json =
            match registry_entry with
            | Some entry ->
                Keeper_state_machine_json.conditions_to_json entry.conditions
            | None -> `Null
          in
          let keeper_last_error =
            match registry_entry with
            | Some entry -> entry.last_error
            | None -> None
          in
          let runtime_blocker_fields =
            runtime_blocker_fields_json config m
          in
          let attention_fields =
            attention_fields_json config m
          in
          let runtime_contract =
            Keeper_runtime_contract.runtime_observability_contract_json ~config m
          in
          let goal_progress =
            Option.value ~default:`Null (Json_util.assoc_member_opt "goal_progress" runtime_contract)
          in
          let blocked_task_count =
            Safe_ops.json_int "blocked_task_count" ~default:0 runtime_contract
          in
          let sandbox_target =
            Safe_ops.json_string "sandbox_target" ~default:"unknown"
              runtime_contract
          in
          let supervisor_diagnostics, recent_crash_count =
            match registry_entry with
            | Some entry ->
                let crash_log =
                  List.map (fun (ts, reason) ->
                    `Assoc [("ts", `Float ts); ("reason", `String reason)]
                  ) entry.crash_log in
                let disk_crashes =
                  (try
                     Keeper_crash_persistence.recent_crashes
                       ~keepers_dir:(Workspace.keepers_runtime_dir config)
                       ~name:m.name ~max_entries:20
                   with
                   | Eio.Cancel.Cancelled _ as exn -> raise exn
                   | exn ->
                       Log.Dashboard.warn
                         "keeper dashboard recent_crashes failed for %s: %s"
                         m.name (Printexc.to_string exn);
                       []) in
                let combined_log = match disk_crashes with
                  | [] -> crash_log
                  | _ -> disk_crashes in
                (`Assoc [
                  ("restart_count", `Int entry.restart_count);
                  ("crash_log", `List combined_log);
                  ("last_failure_reason",
                    match entry.last_failure_reason with
                    | Some r -> `String (Keeper_registry.failure_reason_to_string r)
                    | None -> `Null);
                ], List.length combined_log)
            | None ->
                (`Assoc [
                  ("restart_count", `Int 0);
                  ("crash_log", `List []);
                  ("last_failure_reason", `Null);
                  ("dead_since", `Null);
                ], 0)
          in
          let outcomes_json =
            compute_outcomes_rollup
              ~keeper_name:m.name
              ~agent_name:m.name
              ~recent_crash_count
              ~registry_entry
          in

          let context_budget =
            let runtime_id = Keeper_meta_contract.runtime_id_of_meta m in
            match
              Keeper_context_runtime.resolve_max_context_resolution_for_runtime_id
                ~requested_override:m.max_context_override
                ~runtime_id
            with
            | Ok max_context_resolution ->
                Keeper_context_runtime.context_budget_json_of_resolution
                  ~runtime_id
                  max_context_resolution
            | Error error ->
                `Assoc
                  [ ( "runtime_id", `String runtime_id )
                  ; ( "capacity_error"
                    , `String
                        (Keeper_context_runtime.max_context_resolution_error_to_string
                           error) )
                  ]
          in
          let context_projection_fields =
            Keeper_context_observation_projection.context_fields
              ~config
              ~keeper_name:m.name
              ~current_trace_id:(Keeper_id.Trace_id.to_string m.runtime.trace_id)
          in
	          let summary =
              let trust_json =
                keeper_trust_json ~include_receipt:(not compact) config m
              in
              let recent_tool_names =
                match metrics_window_summary with
                | `Assoc fields -> (
                    match List.assoc_opt "top_tools" fields with
                    | Some (`List items) ->
                        items
                        |> List.filter_map (fun item ->
                               let tool =
                                 Safe_ops.json_string ~default:"" "tool" item |> String.trim
                               in
                               if tool = "" then None else Some tool)
                    | _ -> [])
                | _ -> []
              in
              let diagnostic =
	                Keeper_status_runtime.keeper_diagnostic_json
	                  ~config
	                  ~meta:m
	                  ~keepalive_running
	                  ~history_items:conversation_items
	                  ~now_ts
	                |> Keeper_status_runtime.augment_keeper_diagnostic_json
	                     ~keepalive_running
	                     ~keepalive_started_at:(runtime_keepalive_started_at config m)
                     ~now_ts
              in
              let runtime_trust =
                if compact
                then Keeper_runtime_trust_snapshot.summary_json ~config ~meta:m
                else Keeper_runtime_trust_snapshot.snapshot_json ~config ~meta:m
              in
              let attention_fields =
                attention_fields_with_runtime_trust attention_fields runtime_trust
              in
              let detail_fields =
                if compact then []
                else [
                  ("metrics_series", metrics_series);
                  ("conversation_tail", conversation_tail);
                  ("k2k_recent", k2k_recent);
                ]
              in
	              let profile = Dashboard_execution_helpers.get_agent_profile m.name in
	              let lifecycle_phase =
	                Option.map
	                  (fun (entry : Keeper_registry.registry_entry) ->
	                    Keeper_state_machine.phase_to_string entry.phase)
	                  registry_entry
	              in
	              let pipeline_stage =
	                match registry_entry with
	                | Some entry ->
	                  Keeper_status_runtime.pipeline_stage_of_phase entry.phase
	                | None -> "offline"
	              in
	              let pipeline_stage_detail =
	                match registry_entry with
	                | Some entry ->
	                  Keeper_status_runtime.pipeline_stage_detail_of_phase entry.phase
	                | None -> "registry_absent"
	              in
		            `Assoc ([
	              ("name", `String m.name);
	              ("pipeline_stage", `String pipeline_stage);
	              ("lifecycle_phase", Json_util.string_opt_to_json lifecycle_phase);
	              ("pipeline_stage_detail", `String pipeline_stage_detail);
	              ("runtime_class", `String "keeper");
              ("phase", Json_util.string_opt_to_json phase);
              ("conditions", conditions_json);
              ("outcomes", outcomes_json);
            ] @ runtime_blocker_fields @ attention_fields @ [
              ("supervisor_diagnostics", supervisor_diagnostics);
              ( "keeper_id",
                match m.keeper_id with
                | Some keeper_id ->
                    `String (Keeper_id.Uid.to_string keeper_id)
                | None -> `Null );
              ("emoji", `String profile.emoji);
              ("koreanName", `String profile.korean_name);
              ("trace_id", `String (Keeper_id.Trace_id.to_string m.runtime.trace_id));
              ( "current_task_id",
                Json_util.string_opt_to_json
                  (Option.map Keeper_id.Task_id.to_string m.current_task_id) );
              ("created_at", `String m.created_at);
              ("updated_at", `String m.updated_at);
              ("trace_history_count", `Int trace_history_count);
              ( "active_goals_tree",
                if (not compact) && include_goals then
                  let all_goals = Goal_store.list_goals config () in
                  let linked =
                    List.filter
                      (fun (g : Goal_store.goal) ->
                         Goal_phase.admits_self_directed_progress g.phase)
                      all_goals
                  in
                  let tasks = Workspace.get_tasks_safe config in
                  (match
                     Keeper_approval_queue
                     .list_pending_dashboard_json_for_workspace
                       ~base_path:config.base_path
                   with
                  | Error error ->
                      `Assoc
                        [
                          ( "approval_queue_state",
                            Keeper_approval_queue
                            .approval_queue_unavailable_state_json
                              error );
                          ("count", `Null);
                          ("nodes", `Null);
                        ]
                  | Ok pending_approvals ->
                      let forest =
                        Dashboard_goals.build_forest ~config ~goals:linked
                          ~tasks ~pending_approvals
                      in
                      `Assoc
                        [
                          ( "approval_queue_state",
                            Keeper_approval_queue
                            .approval_queue_ready_state_json );
                          ("count", `Int (List.length linked));
                          ( "nodes",
                            `List
                              (List.map
                                 Dashboard_goals.tree_node_to_json
                                 forest) );
                        ])
                else
                  `Null );
              ("instructions",
                if String.trim m.instructions = "" then `Null else `String m.instructions);
              ( "models"
              , `List
                  (List.map
                     (fun s -> `String s)
                     (Keeper_model_labels.configured_model_labels_of_meta m)) );
              ("primary_model", `String (Keeper_meta_contract.runtime_id_of_meta m));
              ("active_model", `String (Keeper_status_runtime.active_model_of_meta m));
              ("next_model_hint", `Null);
              ("sandbox_profile",
                `String (Keeper_types_profile_sandbox.sandbox_profile_to_string m.sandbox_profile));
              ("sandbox_target", `String sandbox_target);
              ("keeper_last_error",
                Json_util.string_opt_to_json keeper_last_error);
              ("runtime_contract", runtime_contract);
              ("goal_progress", goal_progress);
              ("blocked_task_count", `Int blocked_task_count);
              ("runtime_trust", runtime_trust);
              ("paused", `Bool m.paused);
              ("keepalive_running", `Bool keepalive_running);
              ("keeper_keepalive_interval_s", `Float keepalive_interval_s);
              ("keeper_snapshot_interval_s", `Float snapshot_interval_s);
              ("heartbeat_stale_after_s", `Float heartbeat_stale_after_s);
              ("autoboot_enabled", `Bool m.autoboot_enabled);
              ( "status",
                `String
                  (Keeper_status_runtime.keeper_surface_status ~diagnostic) );
              ("keeper_age_s", Json_util.float_opt_to_json keeper_age_s);
              ( "uptime_hours"
              , Json_util.option_to_yojson
                  (fun age_s -> `Float (age_s /. Masc_time_constants.hour))
                  keeper_age_s );
              ("last_turn_ago_s", Json_util.float_opt_to_json last_turn_ago_s);
              ("last_handoff_ago_s", Json_util.float_opt_to_json last_handoff_ago_s);
              ("last_proactive_ago_s", Json_util.float_opt_to_json last_proactive_ago_s);
              ("last_visible_proactive_ago_s", Json_util.float_opt_to_json last_visible_proactive_ago_s);
              ("last_activity_ago_s", Json_util.float_opt_to_json last_activity_ago_s);
              ("handoff_count_total", `Int trace_history_count);
              ("total_turns", `Int m.runtime.usage.total_turns);
              ("total_input_tokens", `Int m.runtime.usage.total_input_tokens);
              ("total_output_tokens", `Int m.runtime.usage.total_output_tokens);
              ("total_tokens", `Int m.runtime.usage.total_tokens);
              ("total_cost_usd", `Float m.runtime.usage.total_cost_usd);
              ("last_model_used", `Null);
              ( "last_usage"
              , Option.fold
                  ~none:`Null
                  ~some:Keeper_usage_resolution.to_json
                  m.runtime.last_usage_resolution );
              ("last_latency_ms", last_latency_ms_json m.runtime.usage.last_latency_ms);
              ("autoboot_enabled", `Bool m.autoboot_enabled);
              ("proactive_enabled", `Bool m.proactive.enabled);
              ("proactive_count_total", `Int m.runtime.proactive_rt.count_total);
              ("proactive_visible_count_total", `Int m.runtime.proactive_rt.visible_count_total);
              ("last_proactive_ts", `Float m.runtime.proactive_rt.last_ts);
              ("last_visible_proactive_ts", `Float m.runtime.proactive_rt.last_visible_ts);
              ( "last_proactive_outcome"
              , `String
                  (Keeper_meta_contract.proactive_cycle_outcome_to_string
                     m.runtime.proactive_rt.last_outcome) );
              ("last_proactive_reason",
                if String.trim m.runtime.proactive_rt.last_reason = ""
                then `Null
                else `String m.runtime.proactive_rt.last_reason);
	              ("last_proactive_preview",
	                if String.trim m.runtime.proactive_rt.last_preview = ""
	                then `Null
	                else `String m.runtime.proactive_rt.last_preview);
            ]
            @ live_activity_fields
            @ context_projection_fields
            @ [
              ( "last_turn_usage"
              , Keeper_context_observation_projection.last_turn_usage_json
                  ~base_path:config.base_path
                  m );
              ("metrics_window", metrics_window_summary);
              ("recent_input_preview", Json_util.string_opt_to_json (recent_preview_for_role "user"));
              ("recent_output_preview", Json_util.string_opt_to_json (recent_preview_for_role "assistant"));
              ("recent_tool_names", `List (List.map (fun item -> `String item) recent_tool_names));
              ("conversation_tail_count", `Int conversation_tail_count);
              ("conversation_raw_count", `Int conversation_raw_count);
              ("conversation_fragment_count", `Int conversation_fragment_count);
              ("conversation_fragment_filtered_count", `Int conversation_fragment_filtered_count);
              ("k2k_count", `Int k2k_count);
              ("k2k_mentions", k2k_mentions);
              ("provider_health", provider_health_json);
              ("trust", trust_json);
              ("context_budget", context_budget);
              ("runtime_warning_ctx_ratio", `Float runtime_warning_ctx_ratio);
              (* Eval feed: latest verdict snapshot for this keeper (RFC-MASC-005) *)
              ("eval_latest",
                let base_path = config.base_path in
                let try_name agent_name =
                  Dashboard_eval_feed.read_latest ~base_path ~agent_name ~limit:1
                in
                let snapshots = try_name m.name in
                match snapshots with
                | s :: _ ->
                    `Assoc [
                      ("coverage", `Float s.verdict.coverage);
                      ("all_passed", `Bool s.verdict.all_passed);
                      ("passed_count",
                        `Int (List_util.count_if
                          (fun (lr : Dashboard_eval_feed.layer_result_json) -> lr.passed)
                          s.verdict.layer_results));
                      ("failed_count",
                        `Int (List_util.count_if
                          (fun (lr : Dashboard_eval_feed.layer_result_json) -> not lr.passed)
                          s.verdict.layer_results));
                      ("timestamp", `Float s.timestamp);
                      ("baseline_status", Json_util.string_opt_to_json s.baseline_status);
                    ]
                | [] -> `Null);
            ] @ detail_fields)
          in
          Some summary
      with
      | Eio.Cancel.Cancelled _ as exn -> raise exn
      | exn ->
          let error = Printexc.to_string exn in
          Keeper_fd_pressure.note_exception ~site:"keeper_dashboard.worker" exn;
          Log.Dashboard.error
            "keeper dashboard worker error (%s): %s"
            name
            error;
          (try
             match Keeper_meta_store.read_meta config name with
             | Ok (Some meta) ->
                 Some
                   (degraded_keeper_dashboard_row
                      ~site:"keeper_dashboard_worker_exception"
                      ~error
                      meta)
             | Error _ | Ok None -> None
           with
           | Eio.Cancel.Cancelled _ as exn -> raise exn
           | fallback_exn ->
               Log.Dashboard.error
                 "keeper dashboard degraded fallback failed (%s): %s"
                 name
                 (Printexc.to_string fallback_exn);
               None)
      in
      row)
      names
  in
  let summaries = List.filter_map Fun.id rows in
  `Assoc [
    ("keepers", `List summaries);
    ("total", `Int (List.length summaries));
  ]

let execution_trust_row_of_dashboard_row row =
  let field key =
    (* sound-partial: invalid-profile and degraded rows intentionally omit
       inapplicable fields; the established execution-trust wire value for
       those absent fields is JSON null. *)
    match Json_util.assoc_member_opt key row with
    | Some value -> value
    | None -> `Null
  in
  `Assoc
    [ ("name", field "name")
    ; ("keeper_id", field "keeper_id")
    ; ("phase", field "phase")
    ; ("pipeline_stage", field "pipeline_stage")
    ; ("status", field "status")
    ; ("trace_id", field "trace_id")
    ; ("current_task_id", field "current_task_id")
    ; ("trust", field "trust")
    ]

let execution_trust_row_of_meta
      ~(now_ts : float)
      (config : Workspace.config)
      (m : Keeper_meta_contract.keeper_meta)
  =
  let keepalive_running = runtime_keepalive_running config m in
  let registry_entry =
    Keeper_registry.get ~base_path:config.base_path m.name
  in
  let phase, pipeline_stage =
    match registry_entry with
    | Some entry ->
      ( `String (Keeper_state_machine.phase_to_string entry.phase)
      , Keeper_status_runtime.pipeline_stage_of_phase entry.phase )
    | None -> `Null, "offline"
  in
  (* [keeper_surface_status] depends only on the diagnostic health state. The
     reply-history fields in [keeper_diagnostic_json] do not participate in
     that state, so the trust surface must not read the conversation log. *)
  let diagnostic =
    Keeper_status_runtime.keeper_diagnostic_json
      ~config
      ~meta:m
      ~keepalive_running
      ~history_items:[]
      ~now_ts
  in
  `Assoc
    [ ("name", `String m.name)
    ; ( "keeper_id"
      , match m.keeper_id with
        | Some keeper_id -> `String (Keeper_id.Uid.to_string keeper_id)
        | None -> `Null )
    ; ("phase", phase)
    ; ("pipeline_stage", `String pipeline_stage)
    ; ( "status"
      , `String
          (Keeper_status_runtime.keeper_surface_status ~diagnostic) )
    ; ("trace_id", `String (Keeper_id.Trace_id.to_string m.runtime.trace_id))
    ; ( "current_task_id"
      , Json_util.string_opt_to_json
          (Option.map Keeper_id.Task_id.to_string m.current_task_id) )
    ; ("trust", keeper_trust_json ~include_receipt:false config m)
    ]

let execution_trust_keeper_rows (config : Workspace.config) =
  let names =
    keeper_names config @ Keeper_meta_store.configured_keeper_names config
    |> List.sort_uniq String.compare
  in
  let now_ts = Time_compat.now () in
  let results = Array.make (List.length names) None in
  Eio.Fiber.all
    (List.mapi
       (fun idx name () ->
         let row =
           try
             match
               Keeper_types_profile.load_keeper_profile_defaults_result_for_base_path
                 ~base_path:config.base_path
                 name
             with
             | Error error ->
               Some
                 (invalid_profile_dashboard_row ~keeper_name:name error
                  |> execution_trust_row_of_dashboard_row)
             | Ok _ ->
               (match Keeper_meta_store.read_meta config name with
                | Error _ | Ok None -> None
                | Ok (Some meta) ->
                  Some (execution_trust_row_of_meta ~now_ts config meta))
           with
           | Eio.Cancel.Cancelled _ as exn -> raise exn
           | exn ->
             let error = Printexc.to_string exn in
             Keeper_fd_pressure.note_exception
               ~site:"keeper_dashboard.worker"
               exn;
             Log.Dashboard.error
               "keeper dashboard worker error (%s): %s"
               name
               error;
             (try
                match Keeper_meta_store.read_meta config name with
                | Ok (Some meta) ->
                  Some
                    (degraded_keeper_dashboard_row
                       ~site:"keeper_dashboard_worker_exception"
                       ~error
                       meta
                     |> execution_trust_row_of_dashboard_row)
                | Error _ | Ok None -> None
              with
              | Eio.Cancel.Cancelled _ as exn -> raise exn
              | fallback_exn ->
                Log.Dashboard.error
                  "keeper dashboard degraded fallback failed (%s): %s"
                  name
                  (Printexc.to_string fallback_exn);
                None)
         in
         results.(idx) <- row)
       names);
  Array.to_list results |> List.filter_map Fun.id

let execution_trust_dashboard_json (config : Workspace.config) : Yojson.Safe.t =
  (* This surface is refreshed every minute. Building it from the generalized
     Keeper dashboard projection used to scan metrics, histories, goals,
     profiles, crash logs, and runtime contracts only to discard all but these
     eleven fields. Keep the producer specialized so refresh work stays
     proportional to execution-trust evidence. *)
  let keepers = execution_trust_keeper_rows config in
  let now = Unix.gettimeofday () in
  let keeper_names = keeper_names config in
  let keepers_root = Workspace.keepers_runtime_dir config in
  let exists = Sys.file_exists keepers_root in
  let entry_count = count_execution_receipt_entries config keeper_names in
  let latest_ts = latest_receipt_ts_of_keeper_rows keepers in
  let coverage_gaps = execution_receipt_coverage_gaps config in
  let coverage_gap = List.rev coverage_gaps |> List.find_opt (fun _ -> true) in
  `Assoc
    ([
      ("source", `String execution_trust_source);
      ("producer", `String execution_trust_producer);
      ("durable_store", `String (execution_receipt_store_pattern config));
      ("dashboard_surface", `String execution_trust_dashboard_surface);
      ("freshness_slo_s", `Float execution_trust_freshness_slo_s);
      ("entry_count", `Int entry_count);
      ("exists", `Bool exists);
      ("generated_at", `String (Masc_domain.now_iso ()));
      ("keepers", `List keepers);
      ("total", `Int (List.length keepers));
      ("coverage_gaps", `List coverage_gaps);
      ("coverage_gap_count", `Int (List.length coverage_gaps));
    ]
    @ freshness_fields ~now latest_ts
    @ source_health_fields
        ~now ~exists ~entry_count ~latest_ts ?coverage_gap ())

(* Per-keeper snapshot/config rendering extracted to
   [Dashboard_http_keeper_snapshot] (godfile decomp). *)
include Dashboard_http_keeper_snapshot
