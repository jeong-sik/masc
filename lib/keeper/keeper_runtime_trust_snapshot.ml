open Keeper_types

let json_int_opt_member key json =
  match Yojson.Safe.Util.member key json with
  | `Int n -> Some n
  | `Intlit raw -> int_of_string_opt raw
  | _ -> None

let json_float_opt_member key json =
  match Yojson.Safe.Util.member key json with
  | `Float value -> Some value
  | `Int value -> Some (float_of_int value)
  | `Intlit raw -> float_of_string_opt raw
  | _ -> None

let json_string_opt_member key json =
  match Yojson.Safe.Util.member key json with
  | `String value when String.trim value <> "" -> Some value
  | _ -> None

let json_string_opt_value = function
  | `String value when String.trim value <> "" -> Some value
  | _ -> None

let json_bool_opt_member key json =
  match Yojson.Safe.Util.member key json with
  | `Bool value -> Some value
  | _ -> None

let json_list_member key json =
  match Yojson.Safe.Util.member key json with
  | `List items -> items
  | _ -> []

let json_string_list_member key json =
  json_list_member key json
  |> List.filter_map (function
       | `String value when String.trim value <> "" -> Some value
       | _ -> None)

let assoc_bool_default key ~default fields =
  match List.assoc_opt key fields with
  | Some (`Bool value) -> value
  | _ -> default

let assoc_string_opt key fields =
  match List.assoc_opt key fields with
  | Some (`String value) when String.trim value <> "" -> Some value
  | _ -> None

let assoc_json_opt key fields =
  match List.assoc_opt key fields with
  | Some `Null | None -> None
  | Some value -> Some value

let iso_of_unix_seconds ts =
  Types.iso8601_of_unix_seconds ts

let take limit values =
  values |> List.filteri (fun idx _ -> idx < limit)

let goal_ids_of_json json =
  match json_string_list_member "goal_ids" json with
  | [] -> (
      match json_string_opt_member "goal_id" json with
      | Some goal_id -> [ goal_id ]
      | None -> [])
  | goal_ids -> goal_ids

let keeper_turn_id_of_json json =
  match json_int_opt_member "keeper_turn_id" json with
  | Some _ as value -> value
  | None -> (
      match json_int_opt_member "turn_id" json with
      | Some _ as value -> value
      | None -> json_int_opt_member "turn" json)

let timeline_event_json ?trace_id ?keeper_turn_id ?task_id ?(goal_ids = [])
    ?next_human_action ?observed_at_unix ?(observation_only = false)
    ~ts_unix ~kind ~title ~summary ~severity () =
  let observed_at_unix = Option.value ~default:ts_unix observed_at_unix in
  `Assoc
    [
      ("kind", `String kind);
      ("ts", `String (iso_of_unix_seconds ts_unix));
      ("ts_unix", `Float ts_unix);
      ("observed_at", `String (iso_of_unix_seconds observed_at_unix));
      ("observed_at_unix", `Float observed_at_unix);
      ("observation_only", `Bool observation_only);
      ("trace_id", Json_util.string_opt_to_json trace_id);
      ("keeper_turn_id", Json_util.int_opt_to_json keeper_turn_id);
      ("task_id", Json_util.string_opt_to_json task_id);
      ("goal_ids", `List (List.map (fun goal_id -> `String goal_id) goal_ids));
      ("title", `String title);
      ("summary", `String summary);
      ("severity", `String severity);
      ("next_human_action", Json_util.string_opt_to_json next_human_action);
    ]

let severity_of_decision = function
  | "run" -> "ok"
  | "skip" -> "warn"
  | _ -> "warn"

let severity_of_tool_call success = if success then "ok" else "bad"

let severity_of_approval_event event decision =
  match event with
  | "pending" -> "warn"
  | "expired" -> "bad"
  | "resolved" -> (
      match decision with
      | Some raw when String_util.contains_substring_ci raw "reject" -> "bad"
      | _ -> "ok")
  | "auto_approved_rule_match" | "rule_created" -> "ok"
  | _ -> "warn"

let severity_of_transition_type event_type =
  if String_util.contains_substring_ci event_type "failed"
     || String_util.contains_substring_ci event_type "exhausted"
  then "bad"
  else if
    String_util.contains_substring_ci event_type "pause"
    || String_util.contains_substring_ci event_type "stop"
    || String_util.contains_substring_ci event_type "handoff"
    || String_util.contains_substring_ci event_type "compaction"
  then "warn"
  else "ok"

let tool_call_timeline_event json =
  match json_float_opt_member "ts" json, json_string_opt_member "tool" json with
  | Some ts_unix, Some tool_name ->
      let success =
        json_bool_opt_member "success" json |> Option.value ~default:true
      in
      let duration_ms = json_float_opt_member "duration_ms" json in
      let summary =
        match duration_ms with
        | Some ms ->
            Printf.sprintf "%s %s in %.0fms"
              tool_name
              (if success then "succeeded" else "failed")
              ms
        | None ->
            Printf.sprintf "%s %s"
              tool_name
              (if success then "succeeded" else "failed")
      in
      Some
        (timeline_event_json
           ?trace_id:(json_string_opt_member "trace_id" json)
           ?keeper_turn_id:(keeper_turn_id_of_json json)
           ?task_id:(json_string_opt_member "task_id" json)
           ~goal_ids:(goal_ids_of_json json)
           ~ts_unix ~kind:"tool_call"
           ~title:(Printf.sprintf "Tool · %s" tool_name)
           ~summary ~severity:(severity_of_tool_call success) ())
  | _ -> None

let approval_event_timeline_event json =
  match json_float_opt_member "ts" json, json_string_opt_member "event" json with
  | Some ts_unix, Some event ->
      let tool_name =
        json_string_opt_member "tool" json |> Option.value ~default:"tool"
      in
      let decision = json_string_opt_member "decision" json in
      let kind, title, summary, next_human_action =
        match event with
        | "pending" ->
            ( "approval_requested",
              Printf.sprintf "Approval · %s" tool_name,
              "approval requested and waiting for operator decision",
              Some "resolve_approval" )
        | "resolved" ->
            let decision_label =
              Option.value ~default:"resolved" decision
            in
            ( "approval_resolved",
              Printf.sprintf "Approval · %s" tool_name,
              Printf.sprintf "approval %s" decision_label,
              None )
        | "expired" ->
            ( "approval_expired",
              Printf.sprintf "Approval · %s" tool_name,
              Option.value ~default:"approval expired" decision,
              Some "retry_or_rerun" )
        | "auto_approved_rule_match" ->
            let matched_by =
              json |> Yojson.Safe.Util.member "rule_match"
              |> json_string_opt_member "matched_by"
              |> Option.value ~default:"always_rule"
            in
            ( "approval_rule_match",
              Printf.sprintf "Approval Rule · %s" tool_name,
              Printf.sprintf "auto-approved by %s" matched_by,
              None )
        | "rule_created" ->
            ( "approval_rule_created",
              Printf.sprintf "Approval Rule · %s" tool_name,
              "persistent approval rule recorded",
              None )
        | other ->
            ( "approval_event",
              Printf.sprintf "Approval · %s" tool_name,
              other,
              None )
      in
      Some
        (timeline_event_json
           ?keeper_turn_id:(keeper_turn_id_of_json json)
           ?task_id:(json_string_opt_member "task_id" json)
           ~goal_ids:(goal_ids_of_json json)
           ?next_human_action
           ~ts_unix ~kind ~title ~summary
           ~severity:(severity_of_approval_event event decision) ())
  | _ -> None

let decision_timeline_event json =
  match json_float_opt_member "wall_clock" json with
  | None -> None
  | Some ts_unix ->
      let turn_verdict =
        json_string_opt_member "turn_verdict" json
        |> Option.value ~default:"unknown"
      in
      let reasons =
        json_string_list_member "turn_reasons" json
      in
      let summary =
        match reasons with
        | [] -> Printf.sprintf "turn verdict=%s" turn_verdict
        | _ -> String.concat "; " reasons
      in
      Some
        (timeline_event_json ~ts_unix ~kind:"decision"
           ~title:"Turn Decision"
           ~summary
           ~severity:(severity_of_decision turn_verdict) ())

let transition_timeline_event json =
  match json_float_opt_member "wall_clock_at_decision" json with
  | None -> None
  | Some ts_unix ->
      let prev_phase =
        json |> Yojson.Safe.Util.member "prev_phase"
        |> json_string_opt_value
      in
      let new_phase =
        json |> Yojson.Safe.Util.member "new_phase"
        |> json_string_opt_value
      in
      let selected_event =
        json |> Yojson.Safe.Util.member "selected_event"
      in
      let event_type =
        json_string_opt_member "type" selected_event
        |> Option.value ~default:"transition"
      in
      let prev_phase = Option.value ~default:"unknown" prev_phase in
      let new_phase = Option.value ~default:"unknown" new_phase in
      Some
        (timeline_event_json ~ts_unix ~kind:"transition"
           ~title:(Printf.sprintf "Transition · %s" event_type)
           ~summary:
             (Printf.sprintf "%s -> %s via %s"
                prev_phase new_phase event_type)
           ~severity:(severity_of_transition_type event_type) ())

let receipt_timeline_event receipt =
  match json_string_opt_member "ended_at" receipt with
  | None -> None
  | Some ended_at ->
      let ts_unix =
        Types.parse_iso8601 ~default_time:0.0 ended_at
      in
      if ts_unix <= 0.0 then None
      else
        let outcome =
          json_string_opt_member "outcome" receipt
          |> Option.value ~default:"unknown"
        in
        let tool_contract_result =
          json_string_opt_member "tool_contract_result" receipt
          |> Option.value ~default:"unknown"
        in
        let cascade_outcome =
          receipt |> Yojson.Safe.Util.member "cascade"
          |> json_string_opt_member "outcome"
          |> Option.value ~default:"not_observed"
        in
        let error_kind =
          match Yojson.Safe.Util.member "error" receipt with
          | `Assoc _ as error -> json_string_opt_member "kind" error
          | _ -> None
        in
        let severity =
          match error_kind with
          | Some _ -> "bad"
          | None ->
              if String.equal tool_contract_result "violated" then "bad"
              else if
                String.equal cascade_outcome "passed_to_next_model"
                || (receipt |> Yojson.Safe.Util.member "cascade"
                    |> json_bool_opt_member "fallback_applied"
                    |> Option.value ~default:false)
              then "warn"
              else "ok"
        in
        Some
          (timeline_event_json
             ?trace_id:(json_string_opt_member "trace_id" receipt)
             ?keeper_turn_id:(json_int_opt_member "turn_count" receipt)
             ?task_id:(json_string_opt_member "current_task_id" receipt)
             ~goal_ids:(goal_ids_of_json receipt)
             ~ts_unix ~kind:"execution_receipt"
             ~title:"Execution Receipt"
             ~summary:
               (Printf.sprintf "%s · tool_contract=%s · cascade=%s"
                  outcome tool_contract_result cascade_outcome)
             ~severity ())

let blocker_timeline_event ?task_id ?(goal_ids = []) ?trace_id
    ?observed_at_unix ~ts_unix ~runtime_blocker_fields
    ~next_human_action () =
  let blocker_class = assoc_string_opt "runtime_blocker_class" runtime_blocker_fields in
  let blocker_summary =
    assoc_string_opt "runtime_blocker_summary" runtime_blocker_fields
  in
  match blocker_class, blocker_summary with
  | None, None -> None
  | Some blocker_class, Some summary
    when String.trim summary <> "" ->
      Some
        (timeline_event_json ?trace_id ?task_id ~goal_ids ?next_human_action
           ?observed_at_unix ~observation_only:true
           ~ts_unix ~kind:"runtime_blocker"
           ~title:"Runtime Blocker"
           ~summary
           ~severity:
             (match blocker_class with
              | "cascade_exhausted" | "completion_contract_violation" -> "bad"
              | _ -> "warn")
           ())
  | None, Some summary
    when String.trim summary <> "" ->
      Some
        (timeline_event_json ?trace_id ?task_id ~goal_ids ?next_human_action
           ?observed_at_unix ~observation_only:true
           ~ts_unix ~kind:"runtime_blocker"
           ~title:"Runtime Blocker"
           ~summary ~severity:"warn" ())
  | Some blocker_class, None ->
      Some
        (timeline_event_json ?trace_id ?task_id ~goal_ids ?next_human_action
           ?observed_at_unix ~observation_only:true
           ~ts_unix ~kind:"runtime_blocker"
           ~title:"Runtime Blocker"
           ~summary:blocker_class ~severity:"warn" ())
  | Some _, Some _ | None, Some _ -> None

let disposition_of_snapshot ~pending_approval_count ~runtime_blocker_fields =
  let continue_gate =
    assoc_bool_default "runtime_blocker_continue_gate" ~default:false
      runtime_blocker_fields
  in
  let blocker_class = assoc_string_opt "runtime_blocker_class" runtime_blocker_fields in
  let blocker_summary =
    assoc_string_opt "runtime_blocker_summary" runtime_blocker_fields
  in
  if pending_approval_count > 0 then ("Pause", "waiting_approval")
  else if continue_gate then ("Pause", "waiting_human_decision")
  else
    match blocker_class, blocker_summary with
    | Some "cascade_exhausted", _ -> ("Alert", "cascade_exhausted")
    | Some "completion_contract_violation", _ -> ("Alert", "fsm_invariant")
    | _, Some summary
      when String_util.contains_substring_ci summary "sandbox" ->
        ("Alert", "sandbox_violation")
    | Some _, _ -> ("Alert", "critical_block")
    | None, _ -> ("Pass", "healthy")

let disposition_fields_json ~(config : Coord.config) ~(meta : keeper_meta) :
    Yojson.Safe.t =
  let pending_approval_count =
    Keeper_approval_queue.pending_count_for_keeper ~keeper_name:meta.name
  in
  let runtime_blocker_fields =
    Keeper_status_bridge.runtime_blocker_fields_json config meta
  in
  let disposition, disposition_reason =
    disposition_of_snapshot ~pending_approval_count ~runtime_blocker_fields
  in
  `Assoc
    [
      ("disposition", `String disposition);
      ("disposition_reason", `String disposition_reason);
    ]

let latest_decision_json ~(config : Coord.config) ~(keeper_name : string) :
    Yojson.Safe.t option =
  let path = Keeper_types.keeper_decision_log_path config keeper_name in
  if not (Fs_compat.file_exists path) then None
  else
    Keeper_memory.read_file_tail_lines path ~max_bytes:40000 ~max_lines:20
    |> List.rev
    |> List.find_map (fun line ->
           match Yojson.Safe.from_string line with
           | exception Yojson.Json_error _ -> None
           | (`Assoc _ as json) -> Some json
           | _ -> None)

let latest_tool_call_json ~(keeper_name : string) =
  Keeper_tool_call_log.read_latest ~keeper_name ()

let pending_approval_json ~(keeper_name : string) =
  match Keeper_approval_queue.list_pending_dashboard_json () with
  | `List entries ->
      entries
      |> List.filter (fun json ->
             String.equal keeper_name
               (Safe_ops.json_string ~default:"" "keeper_name" json))
      |> List.sort (fun left right ->
             Float.compare
               (Safe_ops.json_float ~default:0.0 "requested_at" right)
               (Safe_ops.json_float ~default:0.0 "requested_at" left))
      |> fun entries -> `List entries
  | _ -> `List []

let latest_turn_id ~(registry_entry : Keeper_registry.registry_entry option)
    ~(latest_decision : Yojson.Safe.t option)
    ~(latest_tool_call : Yojson.Safe.t option)
    ~(latest_receipt : Yojson.Safe.t option) =
  match Option.bind latest_decision (json_int_opt_member "turn_id") with
  | Some _ as turn_id -> turn_id
  | None ->
      (match Option.bind latest_tool_call (json_int_opt_member "keeper_turn_id") with
       | Some _ as turn_id -> turn_id
       | None ->
           (match Option.bind latest_receipt (json_int_opt_member "turn_count") with
            | Some _ as turn_id -> turn_id
            | None -> (
                match registry_entry with
                | Some { current_turn_observation = Some turn; _ } -> Some turn.turn_id
                | Some { last_completed_turn = Some turn; _ } -> Some turn.ct_turn_id
                | _ -> None)))

let latest_receipt_json ~(config : Coord.config) ~(keeper_name : string) =
  Keeper_execution_receipt.latest_json config keeper_name

let sort_timeline_events events =
  List.sort
    (fun left right ->
      match
        Bool.compare
          (json_bool_opt_member "observation_only" left
           |> Option.value ~default:false)
          (json_bool_opt_member "observation_only" right
           |> Option.value ~default:false)
      with
      | 0 ->
          Float.compare
            (json_float_opt_member "ts_unix" right |> Option.value ~default:0.0)
            (json_float_opt_member "ts_unix" left |> Option.value ~default:0.0)
      | cmp -> cmp)
    events

let latest_causal_from_timeline = function
  | `List items -> (
      match
        List.find_opt
          (fun json ->
             not
               (json_bool_opt_member "observation_only" json
                |> Option.value ~default:false))
          items
      with
      | Some event -> event
      | None -> (
          match items with
          | event :: _ -> event
          | [] -> `Null))
  | _ -> `Null

let approval_state_json ~pending_approval_count ~latest_tool_call
    ~latest_approval_audit ~latest_receipt =
  let latest_rule_match =
    Option.bind latest_approval_audit (fun json ->
        match Yojson.Safe.Util.member "rule_match" json with
        | `Assoc _ as rule_match -> Some rule_match
        | _ -> None)
  in
  let latest_event_kind =
    Option.bind latest_approval_audit (json_string_opt_member "event")
  in
  let resolution_mode =
    Option.bind latest_tool_call (json_string_opt_member "approval_mode")
  in
  let approval_profile =
    Option.bind latest_receipt (fun receipt ->
        receipt |> Yojson.Safe.Util.member "approval"
        |> json_string_opt_member "profile")
  in
  let state =
    if pending_approval_count > 0 then "pending"
    else
      match latest_event_kind with
      | Some "auto_approved_rule_match" -> "always_rule"
      | Some "resolved" -> "resolved"
      | Some "expired" -> "expired"
      | Some _ -> "observed"
      | None -> "idle"
  in
  `Assoc
    [
      ("state", `String state);
      ("pending_count", `Int pending_approval_count);
      ("profile", Json_util.string_opt_to_json approval_profile);
      ("resolution_mode", Json_util.string_opt_to_json resolution_mode);
      ("latest_event_kind", Json_util.string_opt_to_json latest_event_kind);
      ( "latest_event_at",
        match Option.bind latest_approval_audit (json_float_opt_member "ts") with
        | Some ts -> `String (iso_of_unix_seconds ts)
        | None -> `Null );
      ( "matched_by",
        match latest_rule_match with
        | Some json -> json |> json_string_opt_member "matched_by" |> Json_util.string_opt_to_json
        | None -> `Null );
      ( "rule_id",
        match latest_rule_match with
        | Some json -> json |> json_string_opt_member "rule_id" |> Json_util.string_opt_to_json
        | None -> `Null );
      ( "auto_approved",
        match latest_approval_audit with
        | Some json ->
            json_bool_opt_member "auto_approved" json
            |> Json_util.bool_opt_to_json
        | None -> `Null );
    ]

let execution_summary_json ~meta ~latest_receipt =
  let sandbox_kind =
    match latest_receipt with
    | Some receipt ->
        receipt |> Yojson.Safe.Util.member "sandbox"
        |> json_string_opt_member "kind"
    | None -> Some (Keeper_types.sandbox_profile_to_string meta.sandbox_profile)
  in
  let network_mode =
    match latest_receipt with
    | Some receipt ->
        receipt |> Yojson.Safe.Util.member "sandbox"
        |> json_string_opt_member "network_mode"
    | None -> Some (Keeper_types.network_mode_to_string meta.network_mode)
  in
  let tool_contract_result =
    Option.bind latest_receipt (json_string_opt_member "tool_contract_result")
  in
  let mutation_guard_summary =
    match tool_contract_result with
    | Some "violated" -> "mutation_contract_violated"
    | Some "satisfied" -> "mutation_contract_satisfied"
    | Some other -> other
    | None -> "mutation_contract_not_observed"
  in
  `Assoc
    [
      ("tool_contract_result", Json_util.string_opt_to_json tool_contract_result);
      ( "sandbox_summary",
        match (sandbox_kind, network_mode) with
        | Some kind, Some mode -> `String (Printf.sprintf "%s / %s" kind mode)
        | Some kind, None -> `String kind
        | None, Some mode -> `String mode
        | None, None -> `Null );
      ("mutation_guard_summary", `String mutation_guard_summary);
      ( "latest_receipt_at",
        match Option.bind latest_receipt (json_string_opt_member "ended_at") with
        | Some value -> `String value
        | None -> `Null );
    ]

let causal_timeline_json ~meta ~latest_decision ~latest_receipt
    ~latest_tool_call ~latest_approval_audit ~runtime_blocker_fields
    ~next_human_action =
  let tool_events =
    Keeper_tool_call_log.read_recent ~keeper_name:meta.name ~n:6 ()
    |> List.filter_map tool_call_timeline_event
  in
  let approval_events =
    Keeper_approval_queue.read_recent_audit ~keeper_name:meta.name ~n:8 ()
    |> List.filter_map approval_event_timeline_event
  in
  let transition_events =
    match Keeper_transition_audit.recent_transitions_json
            ~keeper_name:meta.name ~limit:6 with
    | `List items -> items |> List.filter_map transition_timeline_event
    | _ -> []
  in
  let decision_events =
    (match latest_decision with
     | Some json -> [ decision_timeline_event json ]
     | None -> [])
    |> List.filter_map Fun.id
  in
  let receipt_events =
    (match latest_receipt with
     | Some receipt -> [ receipt_timeline_event receipt ]
     | None -> [])
    |> List.filter_map Fun.id
  in
  let blocker_events =
    let task_id = Keeper_runtime_contract.current_task_id_opt meta in
    let goal_ids = meta.active_goal_ids in
    let trace_id = Keeper_id.Trace_id.to_string meta.runtime.trace_id in
    let observed_at_unix = Time_compat.now () in
    [
      blocker_timeline_event ~ts_unix:observed_at_unix ~observed_at_unix
        ~runtime_blocker_fields ?task_id ~goal_ids
        ~trace_id ~next_human_action ()
    ]
    |> List.filter_map Fun.id
  in
  let latest_tool_call_event =
    match latest_tool_call with
    | Some json -> tool_call_timeline_event json
    | None -> None
  in
  let latest_approval_event =
    match latest_approval_audit with
    | Some json -> approval_event_timeline_event json
    | None -> None
  in
  let dedupe_key json =
    let kind = json_string_opt_member "kind" json |> Option.value ~default:"" in
    let ts = json_string_opt_member "ts" json |> Option.value ~default:"" in
    let title = json_string_opt_member "title" json |> Option.value ~default:"" in
    kind ^ "|" ^ ts ^ "|" ^ title
  in
  let dedupe acc item =
    let key = dedupe_key item in
    if List.exists (fun existing -> String.equal key (dedupe_key existing)) acc
    then acc
    else item :: acc
  in
  tool_events @ approval_events @ transition_events @ decision_events
  @ receipt_events @ blocker_events
  @ (List.filter_map Fun.id [ latest_tool_call_event; latest_approval_event ])
  |> List.fold_left dedupe []
  |> sort_timeline_events
  |> take 12
  |> fun items -> `List items

let snapshot_json ~(config : Coord.config) ~(meta : keeper_meta) =
  let registry_entry =
    Keeper_registry.get ~base_path:config.base_path meta.name
  in
  let latest_decision = latest_decision_json ~config ~keeper_name:meta.name in
  let latest_tool_call = latest_tool_call_json ~keeper_name:meta.name in
  let latest_receipt = latest_receipt_json ~config ~keeper_name:meta.name in
  let latest_approval_audit =
    match Keeper_approval_queue.read_recent_audit ~keeper_name:meta.name ~n:1 () with
    | json :: _ -> Some json
    | [] -> None
  in
  let pending_approvals = pending_approval_json ~keeper_name:meta.name in
  let pending_approval_count =
    match pending_approvals with
    | `List entries -> List.length entries
    | _ -> 0
  in
  let runtime_blocker_fields =
    Keeper_status_bridge.runtime_blocker_fields_json config meta
  in
  let attention_fields =
    Keeper_status_bridge.attention_fields_json config meta
  in
  let runtime_phase =
    match registry_entry with
    | Some entry -> `String (Keeper_state_machine.phase_to_string entry.phase)
    | None -> `Null
  in
  let selected_model =
    Option.bind latest_decision (fun json ->
        match Yojson.Safe.Util.member "telemetry" json with
        | `Assoc _ as telemetry ->
            (match json_string_opt_member "selected_model" telemetry with
             | Some _ as value -> value
             | None -> json_string_opt_member "model_used" telemetry)
        | _ -> None)
  in
  let runtime_contract =
    Keeper_runtime_contract.runtime_contract_json ~config meta
  in
  let disposition, disposition_reason =
    disposition_of_snapshot ~pending_approval_count ~runtime_blocker_fields
  in
  let needs_attention =
    assoc_bool_default "needs_attention" ~default:false attention_fields
  in
  let attention_reason =
    assoc_string_opt "attention_reason" attention_fields
  in
  let next_human_action =
    assoc_string_opt "next_human_action" attention_fields
  in
  let approval_state =
    approval_state_json ~pending_approval_count ~latest_tool_call
      ~latest_approval_audit ~latest_receipt
  in
  let execution_summary =
    execution_summary_json ~meta ~latest_receipt
  in
  let causal_timeline =
    causal_timeline_json ~meta ~latest_decision ~latest_receipt
      ~latest_tool_call ~latest_approval_audit
      ~runtime_blocker_fields ~next_human_action
  in
  let latest_causal_event =
    latest_causal_from_timeline causal_timeline
  in
  `Assoc
    [
      ("trace_id", `String (Keeper_id.Trace_id.to_string meta.runtime.trace_id));
      ("generation", `Int meta.runtime.generation);
      ( "turn_id",
        match
          latest_turn_id ~registry_entry ~latest_decision ~latest_tool_call
            ~latest_receipt
        with
        | Some turn_id -> `Int turn_id
        | None -> `Null );
      ("phase", runtime_phase);
      ("raw_phase", runtime_phase);
      ("current_task_id", Json_util.string_opt_to_json (Keeper_runtime_contract.current_task_id_opt meta));
      ("goal_id", Json_util.string_opt_to_json (Keeper_runtime_contract.primary_goal_id_opt meta));
      ("goal_ids", `List (List.map (fun goal_id -> `String goal_id) meta.active_goal_ids));
      ("active_model", `String (Keeper_exec_status.active_model_label_of_meta meta));
      ("selected_model", Json_util.string_opt_to_json selected_model);
      ("runtime_contract", runtime_contract);
      ("runtime_blockers", `Assoc runtime_blocker_fields);
      ("disposition", `String disposition);
      ("disposition_reason", `String disposition_reason);
      ("needs_attention", `Bool needs_attention);
      ("attention_reason", Json_util.string_opt_to_json attention_reason);
      ("next_human_action", Json_util.string_opt_to_json next_human_action);
      ("approval", approval_state);
      ("execution", execution_summary);
      ("pending_approval_count", `Int pending_approval_count);
      ("pending_approvals", pending_approvals);
      ("latest_decision", Option.value ~default:`Null latest_decision);
      ("latest_tool_call", Option.value ~default:`Null latest_tool_call);
      ("latest_receipt", Option.value ~default:`Null latest_receipt);
      ("latest_causal_event", latest_causal_event);
      ("causal_timeline", causal_timeline);
      ( "last_event_bus_correlation",
        match registry_entry with
        | Some entry ->
            Json_util.string_opt_to_json entry.last_event_bus_correlation
        | None -> `Null );
    ]
