(** Keeper_exec_status_metrics — metrics summary type, serialization, and
    line-based aggregation. Split from keeper_exec_status.ml. *)

type metrics_summary = {
  sample_points : int;
  turn_points : int;
  heartbeat_points : int;
  proactive_points : int;
  auto_reflect_count : int;
  auto_plan_count : int;
  auto_compact_count : int;
  auto_handoff_count : int;
  guardrail_stop_count : int;
  drift_applied_count : int;
  handoff_count : int;
  compaction_events : int;
  compaction_saved_tokens : int;
  memory_compaction_events : int;
  memory_compaction_before_notes : int;
  memory_compaction_dropped_notes : int;
  memory_compaction_invalid_dropped : int;
  memory_checks : int;
  memory_passed : int;
  memory_failed : int;
  memory_correction_applied : int;
  memory_correction_success : int;
  memory_score_sum : float;
  memory_weather_checks : int;
  memory_weather_passed : int;
  repetition_risk_sum : float;
  repetition_risk_points : int;
  goal_alignment_sum : float;
  goal_alignment_points : int;
  response_alignment_sum : float;
  response_alignment_points : int;
  goal_drift_sum : float;
  goal_drift_points : int;
  last_handoff : Yojson.Safe.t option;
  last_compaction : Yojson.Safe.t option;
}

type tool_audit_snapshot = {
  latest_tool_names : string list;
  latest_tool_call_count : int option;
  latest_action_source : string option;
  tool_audit_source : string option;
  tool_audit_at : string option;
}

let empty_metrics_summary =
  {
    sample_points = 0;
    turn_points = 0;
    heartbeat_points = 0;
    proactive_points = 0;
    auto_reflect_count = 0;
    auto_plan_count = 0;
    auto_compact_count = 0;
    auto_handoff_count = 0;
    guardrail_stop_count = 0;
    drift_applied_count = 0;
    handoff_count = 0;
    compaction_events = 0;
    compaction_saved_tokens = 0;
    memory_compaction_events = 0;
    memory_compaction_before_notes = 0;
    memory_compaction_dropped_notes = 0;
    memory_compaction_invalid_dropped = 0;
    memory_checks = 0;
    memory_passed = 0;
    memory_failed = 0;
    memory_correction_applied = 0;
    memory_correction_success = 0;
    memory_score_sum = 0.0;
    memory_weather_checks = 0;
    memory_weather_passed = 0;
    repetition_risk_sum = 0.0;
    repetition_risk_points = 0;
    goal_alignment_sum = 0.0;
    goal_alignment_points = 0;
    response_alignment_sum = 0.0;
    response_alignment_points = 0;
    goal_drift_sum = 0.0;
    goal_drift_points = 0;
    last_handoff = None;
    last_compaction = None;
  }

let empty_tool_audit_snapshot =
  {
    latest_tool_names = [];
    latest_tool_call_count = None;
    latest_action_source = None;
    tool_audit_source = None;
    tool_audit_at = None;
  }

let is_scheduled_autonomous_channel =
  Keeper_world_observation.is_autonomous_channel

let metrics_summary_to_json (s : metrics_summary) : Yojson.Safe.t =
  let interaction_points = s.turn_points + s.proactive_points in
  let intervention_share =
    if interaction_points = 0 then 0.0
    else float_of_int s.proactive_points /. float_of_int interaction_points
  in
  let intervention_per_turn =
    if s.turn_points = 0 then 0.0
    else float_of_int s.proactive_points /. float_of_int s.turn_points
  in
  let drift_applied_rate =
    if interaction_points = 0 then 0.0
    else float_of_int s.drift_applied_count /. float_of_int interaction_points
  in
  let auto_reflect_rate =
    if interaction_points = 0 then 0.0
    else float_of_int s.auto_reflect_count /. float_of_int interaction_points
  in
  let auto_plan_rate =
    if interaction_points = 0 then 0.0
    else float_of_int s.auto_plan_count /. float_of_int interaction_points
  in
  let auto_compact_rate =
    if interaction_points = 0 then 0.0
    else float_of_int s.auto_compact_count /. float_of_int interaction_points
  in
  let auto_handoff_rate =
    if interaction_points = 0 then 0.0
    else float_of_int s.auto_handoff_count /. float_of_int interaction_points
  in
  let guardrail_stop_rate =
    if interaction_points = 0 then 0.0
    else float_of_int s.guardrail_stop_count /. float_of_int interaction_points
  in
  let memory_pass_rate =
    if s.memory_checks = 0 then 0.0
    else float_of_int s.memory_passed /. float_of_int s.memory_checks
  in
  let memory_avg_score =
    if s.memory_checks = 0 then 0.0
    else s.memory_score_sum /. float_of_int s.memory_checks
  in
  let memory_weather_pass_rate =
    if s.memory_weather_checks = 0 then 0.0
    else float_of_int s.memory_weather_passed /. float_of_int s.memory_weather_checks
  in
  let memory_compaction_drop_ratio =
    if s.memory_compaction_before_notes = 0 then 0.0
    else
      float_of_int s.memory_compaction_dropped_notes
      /. float_of_int s.memory_compaction_before_notes
  in
  let memory_compaction_drop_avg =
    if s.memory_compaction_events = 0 then 0.0
    else
      float_of_int s.memory_compaction_dropped_notes
      /. float_of_int s.memory_compaction_events
  in
  let repetition_risk_avg =
    if s.repetition_risk_points = 0 then 0.0
    else s.repetition_risk_sum /. float_of_int s.repetition_risk_points
  in
  let goal_alignment_avg =
    if s.goal_alignment_points = 0 then 0.0
    else s.goal_alignment_sum /. float_of_int s.goal_alignment_points
  in
  let response_alignment_avg =
    if s.response_alignment_points = 0 then 0.0
    else s.response_alignment_sum /. float_of_int s.response_alignment_points
  in
  let goal_drift_avg =
    if s.goal_drift_points = 0 then 0.0
    else s.goal_drift_sum /. float_of_int s.goal_drift_points
  in
  `Assoc
    [
      ("sample_points", `Int s.sample_points);
      ("turn_points", `Int s.turn_points);
      ("heartbeat_points", `Int s.heartbeat_points);
      ("proactive_points", `Int s.proactive_points);
      ("window_interactions", `Int interaction_points);
      ("intervention_share", `Float intervention_share);
      ("intervention_per_turn", `Float intervention_per_turn);
      ("auto_reflect_count", `Int s.auto_reflect_count);
      ("auto_plan_count", `Int s.auto_plan_count);
      ("auto_compact_count", `Int s.auto_compact_count);
      ("auto_handoff_count", `Int s.auto_handoff_count);
      ("guardrail_stop_count", `Int s.guardrail_stop_count);
      ("auto_reflect_rate", `Float auto_reflect_rate);
      ("auto_plan_rate", `Float auto_plan_rate);
      ("auto_compact_rate", `Float auto_compact_rate);
      ("auto_handoff_rate", `Float auto_handoff_rate);
      ("guardrail_stop_rate", `Float guardrail_stop_rate);
      ("drift_applied_count", `Int s.drift_applied_count);
      ("drift_applied_rate", `Float drift_applied_rate);
      ("handoff_count", `Int s.handoff_count);
      ("compaction_events", `Int s.compaction_events);
      ("compaction_saved_tokens", `Int s.compaction_saved_tokens);
      ("memory_compaction_events", `Int s.memory_compaction_events);
      ("memory_compaction_before_notes", `Int s.memory_compaction_before_notes);
      ("memory_compaction_dropped_notes", `Int s.memory_compaction_dropped_notes);
      ("memory_compaction_invalid_dropped", `Int s.memory_compaction_invalid_dropped);
      ("memory_compaction_drop_ratio", `Float memory_compaction_drop_ratio);
      ("memory_compaction_drop_avg", `Float memory_compaction_drop_avg);
      ("memory_checks", `Int s.memory_checks);
      ("memory_passed", `Int s.memory_passed);
      ("memory_failed", `Int s.memory_failed);
      ("memory_pass_rate", `Float memory_pass_rate);
      ("memory_avg_score", `Float memory_avg_score);
      ("memory_correction_applied", `Int s.memory_correction_applied);
      ("memory_correction_success", `Int s.memory_correction_success);
      ("memory_weather_checks", `Int s.memory_weather_checks);
      ("memory_weather_passed", `Int s.memory_weather_passed);
      ("memory_weather_pass_rate", `Float memory_weather_pass_rate);
      ("repetition_risk_avg", `Float repetition_risk_avg);
      ("goal_alignment_avg", `Float goal_alignment_avg);
      ("response_alignment_avg", `Float response_alignment_avg);
      ("goal_drift_avg", `Float goal_drift_avg);
      ("last_handoff", match s.last_handoff with Some j -> j | None -> `Null);
      ("last_compaction", match s.last_compaction with Some j -> j | None -> `Null);
    ]

let summarize_metrics_lines (lines : string list) ~(default_generation : int) :
    metrics_summary =
  let open Yojson.Safe.Util in
  List.fold_left
    (fun acc line ->
      try
        let j = Yojson.Safe.from_string line in
        let ts_unix = Safe_ops.json_float ~default:0.0 "ts_unix" j in
        let trace_id = Safe_ops.json_string ~default:"" "trace_id" j in
        let generation =
          Safe_ops.json_int ~default:default_generation "generation" j
        in
        let channel = Safe_ops.json_string ~default:"turn" "channel" j in
        let is_turn = channel = "turn" in
        let is_heartbeat = channel = "heartbeat" in
        let is_scheduled_autonomous =
          is_scheduled_autonomous_channel channel
        in
        let is_interaction = is_turn || is_scheduled_autonomous in
        let compacted = Safe_ops.json_bool ~default:false "compacted" j in
        let before_tokens =
          Safe_ops.json_int ~default:0 "compaction_before_tokens" j
        in
        let after_tokens =
          Safe_ops.json_int ~default:0 "compaction_after_tokens" j
        in
        let saved_tokens = max 0 (before_tokens - after_tokens) in
        let handoff = j |> member "handoff" in
        let handoff_performed =
          Safe_ops.json_bool ~default:false "performed" handoff
        in
        let to_model = Safe_ops.json_string_opt "to_model" handoff in
        let prev_trace_id = Safe_ops.json_string_opt "prev_trace_id" handoff in
        let new_trace_id = Safe_ops.json_string_opt "new_trace_id" handoff in
        let memory = j |> member "memory_check" in
        let memory_performed =
          Safe_ops.json_bool ~default:false "performed" memory
        in
        let memory_passed =
          Safe_ops.json_bool ~default:false "passed" memory
        in
        let memory_final_score =
          Safe_ops.json_float ~default:0.0 "final_score" memory
        in
        let memory_correction_applied =
          Safe_ops.json_bool ~default:false "correction_applied" memory
        in
        let memory_correction_success =
          Safe_ops.json_bool ~default:false "correction_success" memory
        in
        let memory_expected_topic =
          Safe_ops.json_string_opt "expected_topic" memory
        in
        let memory_compaction_performed =
          Safe_ops.json_bool ~default:false "memory_compaction_performed" j
        in
        let memory_compaction_before_now =
          Safe_ops.json_int ~default:0 "memory_compaction_before_notes" j
        in
        let memory_compaction_dropped_now =
          Safe_ops.json_int ~default:0 "memory_compaction_dropped_notes" j
        in
        let memory_compaction_invalid_now =
          Safe_ops.json_int ~default:0 "memory_compaction_invalid_dropped" j
        in
        let drift = j |> member "drift" in
        let drift_applied_now =
          Safe_ops.json_bool ~default:false "applied" drift
        in
        let memory_is_weather =
          match memory_expected_topic with Some "weather" -> true | _ -> false
        in
        let auto_rules = j |> member "auto_rules" in
        let auto_reflect_now =
          Safe_ops.json_bool
            ~default:(Safe_ops.json_bool ~default:false "reflect" auto_rules)
            "auto_reflect" j
        in
        let auto_plan_now =
          Safe_ops.json_bool
            ~default:(Safe_ops.json_bool ~default:false "plan" auto_rules)
            "auto_plan" j
        in
        let auto_compact_now =
          Safe_ops.json_bool
            ~default:(Safe_ops.json_bool ~default:false "compact" auto_rules)
            "auto_compact" j
        in
        let auto_handoff_now =
          Safe_ops.json_bool
            ~default:(Safe_ops.json_bool ~default:false "handoff" auto_rules)
            "auto_handoff" j
        in
        let guardrail_stop_now =
          Safe_ops.json_bool
            ~default:(Safe_ops.json_bool ~default:false "guardrail_stop" auto_rules)
            "guardrail_stop" j
        in
        let repetition_risk_opt = Safe_ops.json_float_opt "repetition_risk" j in
        let goal_alignment_opt = Safe_ops.json_float_opt "goal_alignment" j in
        let response_alignment_opt = Safe_ops.json_float_opt "response_alignment" j in
        let goal_drift_opt = Safe_ops.json_float_opt "goal_drift" j in
        let handoff_json =
          if handoff_performed then
            Some
              (`Assoc
                [
                  ("ts_unix", `Float ts_unix);
                  ("trace_id", `String trace_id);
                  ("generation", `Int generation);
                  ( "to_model",
                    match to_model with Some s when s <> "" -> `String s | _ -> `Null );
                  ( "prev_trace_id",
                    match prev_trace_id with Some s when s <> "" -> `String s | _ -> `Null );
                  ( "new_trace_id",
                    match new_trace_id with Some s when s <> "" -> `String s | _ -> `Null );
                ])
          else acc.last_handoff
        in
        let compaction_json =
          if compacted then
            let trigger = Safe_ops.json_string_opt "compaction_trigger" j in
            Some
              (`Assoc
                [
                  ("ts_unix", `Float ts_unix);
                  ("trace_id", `String trace_id);
                  ("generation", `Int generation);
                  ("before_tokens", `Int before_tokens);
                  ("after_tokens", `Int after_tokens);
                  ("saved_tokens", `Int saved_tokens);
                  ( "trigger",
                    match trigger with
                    | Some reason when String.trim reason <> "" -> `String reason
                    | _ -> `Null );
                ])
          else acc.last_compaction
        in
        {
          sample_points = acc.sample_points + 1;
          turn_points = acc.turn_points + (if is_turn then 1 else 0);
          heartbeat_points = acc.heartbeat_points + (if is_heartbeat then 1 else 0);
          proactive_points =
            acc.proactive_points + (if is_scheduled_autonomous then 1 else 0);
          auto_reflect_count =
            acc.auto_reflect_count + (if is_interaction && auto_reflect_now then 1 else 0);
          auto_plan_count =
            acc.auto_plan_count + (if is_interaction && auto_plan_now then 1 else 0);
          auto_compact_count =
            acc.auto_compact_count + (if is_interaction && auto_compact_now then 1 else 0);
          auto_handoff_count =
            acc.auto_handoff_count + (if is_interaction && auto_handoff_now then 1 else 0);
          guardrail_stop_count =
            acc.guardrail_stop_count + (if is_interaction && guardrail_stop_now then 1 else 0);
          drift_applied_count =
            acc.drift_applied_count + (if is_interaction && drift_applied_now then 1 else 0);
          handoff_count =
            acc.handoff_count + (if is_interaction && handoff_performed then 1 else 0);
          compaction_events =
            acc.compaction_events + (if is_interaction && compacted then 1 else 0);
          compaction_saved_tokens =
            acc.compaction_saved_tokens
            + (if is_interaction && compacted then saved_tokens else 0);
          memory_compaction_events =
            acc.memory_compaction_events
            + (if is_interaction && memory_compaction_performed then 1 else 0);
          memory_compaction_before_notes =
            acc.memory_compaction_before_notes
            + (if is_interaction && memory_compaction_performed then memory_compaction_before_now else 0);
          memory_compaction_dropped_notes =
            acc.memory_compaction_dropped_notes
            + (if is_interaction && memory_compaction_performed then memory_compaction_dropped_now else 0);
          memory_compaction_invalid_dropped =
            acc.memory_compaction_invalid_dropped
            + (if is_interaction && memory_compaction_performed then memory_compaction_invalid_now else 0);
          memory_checks =
            acc.memory_checks + (if is_interaction && memory_performed then 1 else 0);
          memory_passed =
            acc.memory_passed
            + (if is_interaction && memory_performed && memory_passed then 1 else 0);
          memory_failed =
            acc.memory_failed
            + (if is_interaction && memory_performed && not memory_passed then 1 else 0);
          memory_correction_applied =
            acc.memory_correction_applied
            + (if is_interaction && memory_performed && memory_correction_applied then 1 else 0);
          memory_correction_success =
            acc.memory_correction_success
            + (if is_interaction && memory_performed && memory_correction_success then 1 else 0);
          memory_score_sum =
            acc.memory_score_sum
            +. (if is_interaction && memory_performed then memory_final_score else 0.0);
          memory_weather_checks =
            acc.memory_weather_checks
            + (if is_interaction && memory_performed && memory_is_weather then 1 else 0);
          memory_weather_passed =
            acc.memory_weather_passed
            + (if is_interaction && memory_performed && memory_is_weather && memory_passed then 1 else 0);
          repetition_risk_sum =
            acc.repetition_risk_sum
            +. (match repetition_risk_opt with Some v -> v | None -> 0.0);
          repetition_risk_points =
            acc.repetition_risk_points + (if Option.is_some repetition_risk_opt then 1 else 0);
          goal_alignment_sum =
            acc.goal_alignment_sum
            +. (match goal_alignment_opt with Some v -> v | None -> 0.0);
          goal_alignment_points =
            acc.goal_alignment_points + (if Option.is_some goal_alignment_opt then 1 else 0);
          response_alignment_sum =
            acc.response_alignment_sum
            +. (if is_interaction then Option.value ~default:0.0 response_alignment_opt else 0.0);
          response_alignment_points =
            acc.response_alignment_points
            + (if is_interaction && Option.is_some response_alignment_opt then 1 else 0);
          goal_drift_sum =
            acc.goal_drift_sum
            +. (if is_interaction then Option.value ~default:0.0 goal_drift_opt else 0.0);
          goal_drift_points =
            acc.goal_drift_points
            + (if is_interaction && Option.is_some goal_drift_opt then 1 else 0);
          last_handoff = handoff_json;
          last_compaction = compaction_json;
        }
      with Yojson.Json_error _ | Yojson.Safe.Util.Type_error _ -> acc)
    empty_metrics_summary lines

let json_string_list_member key json =
  match Yojson.Safe.Util.member key json with
  | `List items ->
      items
      |> List.filter_map (function
             | `String value ->
                 let trimmed = String.trim value in
                 if trimmed = "" then None else Some trimmed
             | _ -> None)
  | _ -> []

let json_int_opt_member key json =
  match Yojson.Safe.Util.member key json with
  | `Int value -> Some value
  | `Intlit raw -> (int_of_string_opt (raw))
  | `Float value -> Some (int_of_float value)
  | _ -> None

let action_source_opt_member json =
  match Safe_ops.json_string_opt "action_source" json with
  | Some _ as value -> value
  | None -> (
      match Yojson.Safe.Util.member "deliberation_execution" json with
      | `Assoc _ as nested ->
          Safe_ops.json_string_opt "action_source" nested
      | _ -> None)

let has_tool_audit_evidence ~tools ~raw_tool_call_count ~action_source =
  tools <> []
  || Option.fold ~none:false ~some:(fun count -> count > 0) raw_tool_call_count
  || Option.is_some action_source

let json_iso_opt json =
  match Safe_ops.json_string_opt "ts" json with
  | Some text when String.trim text <> "" -> Some (String.trim text)
  | _ ->
      let ts_unix = Safe_ops.json_float ~default:0.0 "ts_unix" json in
      if ts_unix > 0.0 then Some (Dashboard_utils.iso_of_unix ts_unix) else None

let read_recent_metrics_lines config keeper_name =
  let store = Keeper_types.keeper_metrics_store config keeper_name in
  let dated = Dated_jsonl.read_recent_lines store 8 in
  if dated <> [] then dated
  else
    let metrics_path = Keeper_types.keeper_metrics_path config keeper_name in
    Keeper_memory.read_file_tail_lines metrics_path ~max_bytes:40000 ~max_lines:8

let latest_snapshot_of_lines lines ~parse_snapshot ~has_legacy_shape =
  let ordered = List.rev lines in
  match List.find_map parse_snapshot ordered with
  | Some _ as snapshot -> snapshot
  | None ->
      List.find_map
        (fun line ->
          try
            let json = Yojson.Safe.from_string line in
            match parse_snapshot line with
            | Some _ as snapshot -> snapshot
            | None ->
                if has_legacy_shape json then
                  Some
                    {
                      latest_tool_names = [];
                      latest_tool_call_count = Some 0;
                      latest_action_source = None;
                      tool_audit_source = None;
                      tool_audit_at = json_iso_opt json;
                    }
                else None
          with Yojson.Json_error _ -> None)
        ordered

let latest_tool_audit_snapshot_from_decisions config keeper_name =
  let path = Keeper_types.keeper_decision_log_path config keeper_name in
  if not (Fs_compat.file_exists path) then None
  else
    let lines = Keeper_memory.read_file_tail_lines path ~max_bytes:40000 ~max_lines:12 in
    let parse_snapshot line =
      try
        let json = Yojson.Safe.from_string line in
        let tools = json_string_list_member "tools_used" json in
        let raw_tool_call_count = json_int_opt_member "tool_call_count" json in
        let tool_call_count =
          match raw_tool_call_count with
          | Some _ as value -> value
          | None -> Some (List.length tools)
        in
        let action_source = action_source_opt_member json in
        if not (has_tool_audit_evidence ~tools ~raw_tool_call_count ~action_source)
        then None
        else
          Some
            {
              latest_tool_names = List.sort_uniq String.compare tools;
              latest_tool_call_count = tool_call_count;
              latest_action_source = action_source;
              tool_audit_source = Some "keeper_decision_log";
              tool_audit_at = json_iso_opt json;
            }
      with Yojson.Json_error _ -> None
    in
    latest_snapshot_of_lines lines
      ~parse_snapshot
      ~has_legacy_shape:(fun json ->
        Option.is_some (json_iso_opt json)
        || Option.is_some (Safe_ops.json_string_opt "selected_mode" json)
        || Option.is_some (Safe_ops.json_string_opt "outcome" json))
    |> Option.map (fun snapshot ->
           {
             snapshot with
             tool_audit_source =
               Some
                 (Option.value ~default:"keeper_decision_log"
                    snapshot.tool_audit_source);
           })

let latest_tool_audit_snapshot_from_metrics config keeper_name =
  let lines = read_recent_metrics_lines config keeper_name in
  let parse_snapshot line =
    try
      let json = Yojson.Safe.from_string line in
      let tools =
        json_string_list_member "tools_used" json
        |> List.sort_uniq String.compare
      in
      let raw_tool_call_count = json_int_opt_member "tool_call_count" json in
      let tool_call_count =
        match raw_tool_call_count with
        | Some _ as value -> value
        | None -> Some (List.length tools)
      in
      let action_source = action_source_opt_member json in
      if not (has_tool_audit_evidence ~tools ~raw_tool_call_count ~action_source)
      then None
      else
        Some
          {
            latest_tool_names = tools;
            latest_tool_call_count = tool_call_count;
            latest_action_source = action_source;
            tool_audit_source = Some "keeper_metrics";
            tool_audit_at = json_iso_opt json;
          }
    with Yojson.Json_error _ -> None
  in
  latest_snapshot_of_lines lines
    ~parse_snapshot
    ~has_legacy_shape:(fun json ->
      Option.is_some (json_iso_opt json)
      || Option.is_some (Safe_ops.json_string_opt "channel" json)
      || Option.is_some (Safe_ops.json_string_opt "work_kind" json))
  |> Option.map (fun snapshot ->
         {
           snapshot with
           tool_audit_source =
             Some
               (Option.value ~default:"keeper_metrics"
                  snapshot.tool_audit_source);
         })

let latest_tool_audit_snapshot_from_files config ~keeper_name =
  match latest_tool_audit_snapshot_from_decisions config keeper_name with
  | Some _ as snapshot -> snapshot
  | None -> latest_tool_audit_snapshot_from_metrics config keeper_name

let accountability_summary_lookup config =
  Keeper_accountability.accountability_summary_lookup config

let accountability_summary_json config ~keeper_name ~agent_name =
  Keeper_accountability.accountability_summary_json config ~keeper_name
    ~agent_name
