(** Keeper_status — keeper list/trajectory/eval handlers and status dispatch.
    Single-keeper detail is in Keeper_status_detail. *)

open Tool_args
open Keeper_types
open Keeper_meta_contract
open Keeper_meta_store
open Keeper_types_profile
open Keeper_memory
open Keeper_execution
open Keeper_status_runtime
open Keeper_status_metrics

type tool_result = Keeper_types_profile.tool_result

include Keeper_status_bridge

(* Re-export handle_keeper_status from the detail module *)
let handle_keeper_status = Keeper_status_detail.handle_keeper_status

let read_tail_lines_or_empty ~site path ~max_bytes ~max_lines =
  match read_file_tail_lines_result path ~max_bytes ~max_lines with
  | Ok lines -> lines
  | Error exn_class ->
      record_memory_recall_read_error ~site path exn_class;
      []

let handle_keeper_list ctx args : tool_result =
  let limit = max 0 (get_int args "limit" 50) in
  let detailed = get_bool args "detailed" false in
  let dir = keeper_dir ctx.config in
  match Safe_ops.list_dir_safe dir with
  | Error e -> tool_result_error e
  | Ok _files ->
  let keeper_names = Keeper_meta_store.keeper_names ctx.config |> take limit in
  if not detailed then
    let json = `Assoc [
      ("count", `Int (List.length keeper_names));
      ("keepers", `List (List.map (fun k -> `String k) keeper_names));
    ] in
    tool_result_ok (Yojson.Safe.to_string json)
  else
    let now_ts = Time_compat.now () in
    let keepers =
      List.filter_map (fun name ->
        match read_effective_meta ctx.config name with
        | Error _ -> None
        | Ok None -> None
        | Ok (Some m) ->
          let created_ts =
            Workspace_resilience.Time.parse_iso8601_opt m.created_at |> Option.value ~default:0.0
          in
          let keeper_age_s = if created_ts <= 0.0 then 0.0 else now_ts -. created_ts in
          let last_turn_ago_s = if m.runtime.usage.last_turn_ts <= 0.0 then 0.0 else now_ts -. m.runtime.usage.last_turn_ts in
          let last_proactive_ago_s =
            if m.runtime.proactive_rt.last_ts <= 0.0 then 0.0 else now_ts -. m.runtime.proactive_rt.last_ts
          in
          let last_visible_proactive_ago_s =
            if m.runtime.proactive_rt.last_visible_ts <= 0.0 then 0.0
            else now_ts -. m.runtime.proactive_rt.last_visible_ts
          in
          let active_model = active_model_of_meta m in
          let next_model_hint = next_model_hint_of_meta m in
          let trace_history_count = List.length m.runtime.trace_history in
          let last_compaction_saved_tokens =
            max 0 (m.runtime.compaction_rt.last_before_tokens - m.runtime.compaction_rt.last_after_tokens)
          in
          let (compact_ratio_gate, compact_message_gate, compact_token_gate) =
            compaction_policy_of_keeper m
          in
          let metrics_store = Keeper_types_support.keeper_metrics_store ctx.config m.name in
          let metrics_path = Keeper_types_support.keeper_metrics_path ctx.config m.name in
          let metrics_window_lines =
            let dated = Dated_jsonl.read_recent_lines metrics_store 120 in
            if dated <> [] then dated
            else
              read_tail_lines_or_empty ~site:"keeper_status_metrics" metrics_path
                ~max_bytes:120000 ~max_lines:120
          in
          let last_metrics =
            match List.rev metrics_window_lines with
            | line :: _ -> (try Some (Yojson.Safe.from_string line) with Yojson.Json_error _ -> None)
            | [] -> None
          in
          let metrics_overview =
            summarize_metrics_lines metrics_window_lines ~default_generation:m.runtime.generation
          in
          let last_skill_metrics =
            let rec find_latest = function
              | [] -> None
              | line :: tl ->
                  (try
                     let j = Yojson.Safe.from_string line in
                     match Safe_ops.json_string_opt "skill_primary" j with
                     | Some primary when String.trim primary <> "" -> Some j
                     | _ -> find_latest tl
                   with Yojson.Json_error _ -> find_latest tl)
            in
            find_latest (List.rev metrics_window_lines)
          in
          (* RFC-0149 §3.1 — single typed read drives both the structured
             [memory_bank_summary] (consumed by [memory_bank] / counts
             elsewhere in this object) and the operator-visible
             [memory_recent_note] string field.  An IO fault surfaces a
             typed unavailable marker on the note, and the empty-shaped
             summary preserves the legacy aggregate semantics (zero notes,
             no kinds) so downstream JSON keys stay populated. *)
          let memory_bank_summary, memory_recent_note =
            match
              read_keeper_memory_summary_result
                ctx.config
                ~name:m.name
                ~max_bytes:120000
                ~max_lines:180
                ~recent_limit:3
            with
            | Ok summary ->
              let note =
                match summary.recent_notes with
                | row :: _ -> Some row.text
                | [] -> None
              in
              summary, note
            | Error exn_class ->
              let empty : Keeper_memory_policy.keeper_memory_summary =
                { total_notes = 0
                ; last_ts_unix = 0.0
                ; top_kind = None
                ; kind_counts = []
                ; recent_notes = []
                }
              in
              let note =
                Some
                  (Printf.sprintf "[memory unavailable: %s]"
                     (Keeper_memory_recall_exn_class.to_label exn_class))
              in
              empty, note
          in
            let continuity_reflection_hold_s =
              let cooldown = Float.of_int m.compaction.cooldown_sec in
              let last_reflection_ts =
                max m.runtime.last_continuity_update_ts m.runtime.proactive_rt.last_ts
              in
              if cooldown <= 0.0 then
                0.0
              else if last_reflection_ts <= 0.0 then
                cooldown
              else
                let elapsed = now_ts -. last_reflection_ts in
                max 0.0 (cooldown -. elapsed)
          in
          let context_json =
            match last_metrics with
            | None -> `Assoc [("source", `String "none")]
            | Some metrics ->
              `Assoc [
                ("source", `String "metrics");
                ("context_ratio", `Float (Safe_ops.json_float "context_ratio" metrics));
                ("context_tokens", `Int (Safe_ops.json_int "context_tokens" metrics));
                ("context_max", `Int (Safe_ops.json_int "context_max" metrics));
                ("message_count", `Int (Safe_ops.json_int "message_count" metrics));
              ]
          in
          let skill_route_json =
            let fallback_selection_mode_string = "agent" in
            let fallback_selection_provenance = "fallback" in
            match last_skill_metrics with
            | None -> `Null
            | Some metrics ->
                let primary = Safe_ops.json_string_opt "skill_primary" metrics in
                let secondary =
                  match Json_util.assoc_member_opt "skill_secondary" metrics with
                  | Some (`List xs) ->
                      xs
                      |> List.filter_map (fun v ->
                           match v with `String s when String.trim s <> "" -> Some s | _ -> None)
                  | None | Some _ -> []
                in
                let reason = Safe_ops.json_string_opt "skill_reason" metrics in
                `Assoc [
                  ("primary", Json_util.string_opt_to_json primary);
                  ("secondary", `List (List.map (fun s -> `String s) secondary));
                  ("reason", Json_util.string_opt_to_json reason);
                  ( "selection_mode",
                    `String
                      (Safe_ops.json_string_opt "skill_selection_mode" metrics
                       |> Option.value ~default:fallback_selection_mode_string) );
                  ( "provenance",
                    `String
                      (Safe_ops.json_string_opt "skill_provenance" metrics
                       |> Option.value ~default:fallback_selection_provenance) );
                  ("authoritative", `Bool false);
                ]
          in
          let runtime_blocker_fields =
            runtime_blocker_fields_json ctx.config m
          in
          let attention_fields =
            attention_fields_json ctx.config m
          in
          (* #16 (38-bug campaign PR-5): the persisted [m] (keeper_meta) alone
             cannot distinguish actively executing a turn from idle waiting
             from reactively woken — that state lives only in the in-memory
             registry entry, not on disk. [None] (keeper not currently
             registered, e.g. never launched) surfaces as JSON [null] rather
             than a guessed default. *)
          let run_state_json =
            match Keeper_registry.get ~base_path:ctx.config.base_path m.name with
            | Some entry ->
              let last_skip =
                match entry.Keeper_registry.last_skip_observation with
                | Some (ts, reasons) ->
                  Some Keeper_composite_observer.{ ls_ts = ts; ls_reasons = reasons }
                | None -> None
              in
              Keeper_composite_observer.run_state_to_json
                (Keeper_composite_observer.run_state_of_entry entry ~last_skip)
            | None -> `Null
          in
          Some (`Assoc ([
              ("name", `String m.name);
              ("agent_name", `String m.agent_name);
              ("trace_id", `String (Keeper_id.Trace_id.to_string m.runtime.trace_id));
              ("generation", `Int m.runtime.generation);
              ("goal", `String m.goal);
              ("keepalive_running", `Bool (runtime_keepalive_running ctx.config m));
              ("run_state", run_state_json);
              ("active_model", `String active_model);
              ("next_model_hint", Json_util.string_opt_to_json next_model_hint);
              ("keeper_age_s", `Float keeper_age_s);
              ("last_turn_ago_s", `Float last_turn_ago_s);
              ("last_proactive_ago_s", `Float last_proactive_ago_s);
              ("trace_history_count", `Int trace_history_count);
              ("handoff_count_total", `Int trace_history_count);
              ("compaction_count", `Int m.runtime.compaction_rt.count);
              ("last_compaction_saved_tokens", `Int last_compaction_saved_tokens);
              ("compaction_profile", `String m.compaction.profile);
              ("compaction_ratio_gate", `Float compact_ratio_gate);
              ("compaction_message_gate", `Int compact_message_gate);
              ("compaction_token_gate", `Int compact_token_gate);
              ("autoboot_enabled", `Bool m.autoboot_enabled);
              ("proactive_enabled", `Bool m.proactive.enabled);
              ("proactive_idle_sec", `Int m.proactive.idle_sec);
              ("proactive_cooldown_sec", `Int m.proactive.cooldown_sec);
              ("proactive_count_total", `Int m.runtime.proactive_rt.count_total);
              ("proactive_visible_count_total", `Int m.runtime.proactive_rt.visible_count_total);
              ("last_compaction_check_ts", `Float m.runtime.compaction_rt.last_check_ts);
              ( "last_compaction_decision",
                let decision =
                  compaction_runtime_decision_to_string
                    m.runtime.compaction_rt.last_decision
                in
                if String.trim decision = "" then `Null else `String decision );
              ("last_proactive_ts", `Float m.runtime.proactive_rt.last_ts);
              ("last_visible_proactive_ts", `Float m.runtime.proactive_rt.last_visible_ts);
              ("last_visible_proactive_ago_s", `Float last_visible_proactive_ago_s);
              ( "last_proactive_outcome"
              , `String
                  (proactive_cycle_outcome_to_string
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
            @ runtime_blocker_fields
            @ attention_fields @ [
              ("continuity_summary",
                if String.trim m.continuity_summary = ""
                then `Null
                else `String m.continuity_summary);
              ("continuity_compaction_cooldown_sec", `Int m.compaction.cooldown_sec);
              ("continuity_reflection_hold_s", `Float continuity_reflection_hold_s);
              ("last_continuity_update_ts", `Float m.runtime.last_continuity_update_ts);
              ("autonomous_turn_count", `Int m.runtime.autonomous_turn_count);
              ("autonomous_text_turn_count", `Int m.runtime.autonomous_text_turn_count);
              ("autonomous_tool_turn_count", `Int m.runtime.autonomous_tool_turn_count);
              ("board_reactive_turn_count", `Int m.runtime.board_reactive_turn_count);
              ("mention_reactive_turn_count", `Int m.runtime.mention_reactive_turn_count);
              ("noop_turn_count", `Int m.runtime.noop_turn_count);
              ("autonomous_action_count", `Int m.runtime.autonomous_action_count);
              ("memory_note_count", `Int memory_bank_summary.total_notes);
              ("memory_top_kind",
                Json_util.string_opt_to_json memory_bank_summary.top_kind);
              ("memory_recent_note",
                Json_util.string_opt_to_json memory_recent_note);
              ("context", context_json);
              ("skill_route", skill_route_json);
              ("metrics_overview", metrics_summary_to_json metrics_overview);
              ("memory_bank", memory_summary_to_json memory_bank_summary);
              ("storage_paths", `Assoc [
                ("meta", `String (keeper_meta_path ctx.config m.name));
                ("metrics", `String (Dated_jsonl.base_dir metrics_store));
                ("metrics_single_file", `String metrics_path);
                ( "memory_bank"
                , `String (Keeper_types_support.keeper_memory_bank_path ctx.config m.name) );
                ( "policy"
                , `String (Keeper_types_support.keeper_policy_log_path ctx.config m.name) );
                ( "feedback"
                , `String (Keeper_types_support.keeper_feedback_log_path ctx.config m.name) );
                ( "dataset_export"
                , `String
                    (Keeper_types_support.keeper_dataset_export_path ctx.config m.name)
                );
                ( "session_dir"
                , `String
                    (Keeper_types_support.keeper_session_dir
                       ctx.config
                       (Keeper_id.Trace_id.to_string m.runtime.trace_id)) );
                ( "history"
                , `String
                    (Keeper_types_support.keeper_history_path
                       ctx.config
                       (Keeper_id.Trace_id.to_string m.runtime.trace_id)) );
                ( "history_internal"
                , `String
                    (Keeper_types_support.keeper_internal_history_path
                       ctx.config
                       (Keeper_id.Trace_id.to_string m.runtime.trace_id)) );
              ]);
            ]))
        ) keeper_names
      in
      let json = `Assoc [
        ("count", `Int (List.length keepers));
        ("keepers", `List keepers);
      ] in
      tool_result_ok (Yojson.Safe.to_string json)

let handle_keeper_trajectory ctx args : tool_result =
  let requested_name = String.trim (get_string args "name" "") in
  if not (validate_name requested_name) then
    tool_result_error
      (Printf.sprintf
         "invalid keeper name %S (must be non-empty and match \
          [A-Za-z0-9._-]+; see Keeper_config.validate_name)"
         requested_name)
  else
    match read_meta_resolved ctx.config requested_name with
    | Error e -> tool_result_error ("read error: " ^ e)
    | Ok None -> tool_result_error (Printf.sprintf "keeper not found: %s" requested_name)
    | Ok (Some (_resolved_name, m)) ->
      let limit = get_int args "limit" 20 in
      let masc_root = Common.masc_dir_from_base_path ~base_path:ctx.config.base_path in
      let entries =
        Trajectory.read_entries ~masc_root ~keeper_name:m.name ~trace_id:(Keeper_id.Trace_id.to_string m.runtime.trace_id)
      in
      let total = List.length entries in
      (* Take the last N entries (most recent) *)
      let recent =
        if total <= limit then entries
        else
          let drop = total - limit in
          List.filteri (fun i _e -> i >= drop) entries
      in
      if recent = [] then
        tool_result_ok
          (Printf.sprintf
             "Keeper %s (trace: %s) has no trajectory entries."
             m.name
             (Keeper_id.Trace_id.to_string m.runtime.trace_id))
      else
        let json_list = List.map Trajectory.entry_to_json recent in
        let json = `Assoc [
          ("keeper", `String m.name);
          ("trace_id", `String (Keeper_id.Trace_id.to_string m.runtime.trace_id));
          ("generation", `Int m.runtime.generation);
          ("total_entries", `Int total);
          ("showing", `Int (List.length recent));
          ("entries", `List json_list);
        ] in
        tool_result_ok (Yojson.Safe.to_string json)

let handle_keeper_eval ctx args : tool_result =
  let requested_name = String.trim (get_string args "name" "") in
  if not (validate_name requested_name) then
    tool_result_error
      (Printf.sprintf
         "invalid keeper name %S (must be non-empty and match \
          [A-Za-z0-9._-]+; see Keeper_config.validate_name)"
         requested_name)
  else
    match read_meta_resolved ctx.config requested_name with
    | Error e -> tool_result_error ("read error: " ^ e)
    | Ok None -> tool_result_error (Printf.sprintf "keeper not found: %s" requested_name)
    | Ok (Some (_resolved_name, m)) ->
      let scenario_file = get_string_opt args "scenario_file" in
      let masc_root = Common.masc_dir_from_base_path ~base_path:ctx.config.base_path in
      let entries =
        Trajectory.read_entries ~masc_root ~keeper_name:m.name ~trace_id:(Keeper_id.Trace_id.to_string m.runtime.trace_id)
      in
      if entries = [] then
        tool_result_ok
          (Printf.sprintf "Keeper %s has no trajectory data to evaluate." m.name)
      else
        let total = List.length entries in
        (* Build a lightweight eval summary from trajectory *)
        let tool_names =
          List.map (fun (e : Trajectory.tool_call_entry) -> e.tool_name) entries
        in
        let unique_tools =
          List.sort_uniq String.compare tool_names
        in
        let tool_counts =
          List.map
            (fun tn ->
              let c = List_util.count_if (fun n -> n = tn) tool_names in
              (tn, c))
            unique_tools
        in
        let tool_stats =
          List.map
            (fun (tn, c) -> `Assoc [("tool", `String tn); ("count", `Int c)])
            (List.sort (fun (_, a) (_, b) -> compare b a) tool_counts)
        in
        (* Check if scenario file is provided for deeper eval *)
        let scenario_info =
          match scenario_file with
          | None -> `String "none (trajectory-only eval)"
          | Some sf ->
            (match Eval_harness.load_scenarios_from_file sf with
             | Error e -> `String (Printf.sprintf "failed to load: %s" e)
             | Ok scenarios ->
               `String (Printf.sprintf "loaded %d scenarios from %s"
                 (List.length scenarios) sf))
        in
        let json = `Assoc [
          ("keeper", `String m.name);
          ("trace_id", `String (Keeper_id.Trace_id.to_string m.runtime.trace_id));
          ("generation", `Int m.runtime.generation);
          ("total_turns", `Int m.runtime.usage.total_turns);
          ("total_input_tokens", `Int m.runtime.usage.total_input_tokens);
          ("total_output_tokens", `Int m.runtime.usage.total_output_tokens);
          ("total_tool_calls", `Int total);
          ("unique_tools", `Int (List.length unique_tools));
          ("tool_distribution", `List tool_stats);
          ("scenario_file", scenario_info);
          ("autonomous_action_count", `Int m.runtime.autonomous_action_count);
        ] in
        tool_result_ok (Yojson.Safe.to_string json)
