open Keeper_types

let json_member key = function
  | `Assoc _ as json -> Yojson.Safe.Util.member key json
  | _ -> `Null

let json_int_opt_member key json =
  match json_member key json with
  | `Int n -> Some n
  | `Intlit raw -> int_of_string_opt raw
  | _ -> None

let json_float_opt_member key json =
  match json_member key json with
  | `Float value -> Some value
  | `Int value -> Some (float_of_int value)
  | `Intlit raw -> float_of_string_opt raw
  | _ -> None

let json_string_opt_member key json =
  match json_member key json with
  | `String value when String.trim value <> "" -> Some value
  | _ -> None

let json_string_opt_value = function
  | `String value when String.trim value <> "" -> Some value
  | _ -> None

let json_bool_opt_member key json =
  match json_member key json with
  | `Bool value -> Some value
  | _ -> None

let json_list_member key json =
  match json_member key json with
  | `List items -> items
  | _ -> []

let json_string_list_member key json =
  json_list_member key json
  |> List.filter_map (function
       | `String value when String.trim value <> "" -> Some value
       | _ -> None)

let string_list_json values =
  `List (List.map (fun value -> `String value) values)

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
  Masc_domain.iso8601_of_unix_seconds ts

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

let terminal_reason_from_decision json =
  match json_member "terminal_reason" json with
  | `Assoc _ as terminal_reason -> Keeper_turn_terminal.of_json terminal_reason
  | _ -> None

let terminal_reason_from_receipt receipt =
  match json_string_opt_member "terminal_reason_code" receipt with
  | Some code ->
      Some (Keeper_turn_terminal.of_code ~source:"execution_receipt" code)
  | None -> None

let latest_terminal_reason_opt ~latest_decision ~latest_receipt =
  match Option.bind latest_decision terminal_reason_from_decision with
  | Some _ as value -> value
  | None -> Option.bind latest_receipt terminal_reason_from_receipt

let severity_of_approval_event event decision =
  match event with
  | "pending" -> "warn"
  | "expired" -> "bad"
  | "resolved" -> (
      match decision with
      | Some raw when String_util.contains_substring_ci raw "reject" -> "bad"
      | _ -> "ok")
  | "auto_approved_rule_match" | "auto_approved_always" | "rule_created" -> "ok"
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

let is_worktree_tool tool_name =
  String.equal tool_name "masc_worktree_create"

let live_pending_approval_timeline_event json =
  match json_float_opt_member "requested_at" json with
  | None -> None
  | Some ts_unix ->
      let tool_name =
        json_string_opt_member "tool_name" json |> Option.value ~default:"tool"
      in
      let approval_id =
        json_string_opt_member "id" json |> Option.value ~default:"unknown"
      in
      let task_id = json_string_opt_member "task_id" json in
      let blocker_class =
        if is_worktree_tool tool_name then "blocked_before_worktree"
        else "approval_pending"
      in
      let summary =
        Printf.sprintf
          "approval_required · id=%s · blocker=%s · waiting for operator"
          approval_id blocker_class
      in
      Some
        (timeline_event_json
           ?task_id
           ~ts_unix ~kind:"approval_pending_live"
           ~title:(Printf.sprintf "Approval Pending · %s" tool_name)
           ~summary
           ~severity:"warn"
           ~observation_only:true
           ~next_human_action:"resolve_approval"
           ())

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
            let blocker_note =
              if is_worktree_tool tool_name then
                " · blocked_before_worktree"
              else ""
            in
            let next_action =
              if is_worktree_tool tool_name then "retry_worktree_approval"
              else "retry_or_rerun"
            in
            ( "approval_expired",
              Printf.sprintf "Approval · %s" tool_name,
              (Option.value ~default:"approval expired" decision) ^ blocker_note,
              Some next_action )
        | "auto_approved_rule_match" ->
            let matched_by =
              json |> json_member "rule_match"
              |> json_string_opt_member "matched_by"
              |> Option.value ~default:"always_rule"
            in
            ( "approval_rule_match",
              Printf.sprintf "Approval Rule · %s" tool_name,
              Printf.sprintf "auto-approved by %s" matched_by,
              None )
        | "auto_approved_always" ->
            ( "approval_always_flag",
              Printf.sprintf "Approval Always · %s" tool_name,
              "auto-approved by keeper always_approve flag",
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

let terminal_reason_timeline_event ~latest_decision ~latest_receipt =
  let source_json, ts_unix_opt, reason_opt =
    match latest_decision with
    | Some decision -> (
        match terminal_reason_from_decision decision with
        | Some reason ->
            ( Some decision,
              (match json_float_opt_member "ts_unix" decision with
               | Some _ as value -> value
               | None -> json_float_opt_member "wall_clock" decision),
              Some reason )
        | None -> (None, None, None))
    | None -> (None, None, None)
  in
  let source_json, ts_unix_opt, reason_opt =
    match reason_opt, latest_receipt with
    | Some _, _ -> (source_json, ts_unix_opt, reason_opt)
    | None, Some receipt -> (
        match terminal_reason_from_receipt receipt with
        | Some reason ->
            let ts_unix_opt =
              match json_string_opt_member "ended_at" receipt with
              | Some ended_at ->
                  let ts = Masc_domain.parse_iso8601 ~default_time:0.0 ended_at in
                  if ts > 0.0 then Some ts else None
              | None -> None
            in
            (Some receipt, ts_unix_opt, Some reason)
        | None -> (None, None, None))
    | None, None -> (None, None, None)
  in
  match source_json, ts_unix_opt, reason_opt with
  | Some source_json, Some ts_unix, Some reason ->
      Some
        (timeline_event_json
           ?trace_id:(json_string_opt_member "trace_id" source_json)
           ?keeper_turn_id:(keeper_turn_id_of_json source_json)
           ?task_id:
             (match json_string_opt_member "task_id" source_json with
              | Some _ as value -> value
              | None -> json_string_opt_member "current_task_id" source_json)
           ~goal_ids:(goal_ids_of_json source_json)
           ?next_human_action:reason.next_action
           ~ts_unix ~kind:"terminal_reason"
           ~title:"Terminal Reason"
           ~summary:reason.summary
           ~severity:(Keeper_turn_terminal.severity_to_string reason.severity)
           ())
  | _ -> None

let transition_timeline_event json =
  match json_float_opt_member "wall_clock_at_decision" json with
  | None -> None
  | Some ts_unix ->
      let operator_signal =
        match json |> json_member "operator_signal" with
        | `Assoc fields -> Some fields
        | _ -> None
      in
      let signal_string key =
        Option.bind operator_signal (assoc_string_opt key)
      in
      let signal_bool key =
        Option.map
          (fun fields -> assoc_bool_default key ~default:false fields)
          operator_signal
      in
      let prev_phase =
        json |> json_member "prev_phase"
        |> json_string_opt_value
      in
      let new_phase =
        json |> json_member "new_phase"
        |> json_string_opt_value
      in
      let selected_event =
        json |> json_member "selected_event"
      in
      let event_type =
        (match json_string_opt_member "event_type" json with
         | Some _ as value -> value
         | None -> json_string_opt_member "type" selected_event)
        |> Option.value ~default:"transition"
      in
      let prev_phase = Option.value ~default:"unknown" prev_phase in
      let new_phase = Option.value ~default:"unknown" new_phase in
      let signal_summary = signal_string "summary" in
      let next_human_action =
        match signal_bool "requires_operator_decision" with
        | Some true -> signal_string "next_human_action"
        | _ -> None
      in
      let summary =
        match signal_summary with
        | Some signal when String.trim signal <> "" ->
            Printf.sprintf "%s -> %s via %s · %s"
              prev_phase new_phase event_type signal
        | _ ->
            Printf.sprintf "%s -> %s via %s"
              prev_phase new_phase event_type
      in
      let severity =
        signal_string "severity"
        |> Option.value ~default:(severity_of_transition_type event_type)
      in
      Some
        (timeline_event_json ?next_human_action ~ts_unix ~kind:"transition"
           ~title:(Printf.sprintf "Transition · %s" event_type)
           ~summary ~severity ())

let receipt_timeline_event receipt =
  match json_string_opt_member "ended_at" receipt with
  | None -> None
  | Some ended_at ->
      let ts_unix =
        Masc_domain.parse_iso8601 ~default_time:0.0 ended_at
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
          receipt |> json_member "cascade"
          |> json_string_opt_member "outcome"
          |> Option.value ~default:"not_observed"
        in
        let error_kind =
          match json_member "error" receipt with
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
                || (receipt |> json_member "cascade"
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

let operator_disposition_of_display ~disposition ~disposition_reason =
  match disposition with
  | "Pass" -> ("pass", disposition_reason)
  | "Pause" -> ("pause_human", disposition_reason)
  | "Alert" -> ("alert_exhausted", disposition_reason)
  | _ -> ("pause_human", disposition_reason)

let display_disposition_of_operator ~operator_disposition
    ~operator_disposition_reason =
  let reason default =
    match String.trim operator_disposition_reason with
    | "" -> default
    | value -> value
  in
  match String.lowercase_ascii operator_disposition with
  | "pass" -> ("Pass", "healthy")
  | "skipped" -> ("Pass", "phase_skipped")
  | "pass_next_model" -> ("Pass", "cascade_fallback")
  | "pause_human" -> ("Pause", reason "needs_human_attention")
  | "fail_open_next_cascade" -> ("Pause", reason "degraded_retry")
  | "user_cancelled" -> ("Pause", reason "cancelled")
  | "alert_exhausted" -> ("Alert", reason "cascade_exhausted")
  | "unknown" -> ("Alert", reason "unmapped_cascade_state")
  | _ -> ("Alert", reason "unmapped_operator_disposition")

let receipt_operator_disposition receipt =
  match
    ( json_string_opt_member "operator_disposition" receipt,
      json_string_opt_member "operator_disposition_reason" receipt )
  with
  | Some disposition, Some reason -> Some (disposition, reason)
  | Some disposition, None -> Some (disposition, "")
  | None, _ -> None

let effective_disposition_fields ~fallback_disposition ~fallback_reason
    latest_receipt =
  match Option.bind latest_receipt receipt_operator_disposition with
  | Some (operator_disposition, operator_disposition_reason) ->
      let disposition, disposition_reason =
        display_disposition_of_operator ~operator_disposition
          ~operator_disposition_reason
      in
      ( disposition,
        disposition_reason,
        operator_disposition,
        operator_disposition_reason )
  | None ->
      let operator_disposition, operator_disposition_reason =
        operator_disposition_of_display ~disposition:fallback_disposition
          ~disposition_reason:fallback_reason
      in
      ( fallback_disposition,
        fallback_reason,
        operator_disposition,
        operator_disposition_reason )

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
  let latest_receipt = Keeper_execution_receipt.latest_json config meta.name in
  let disposition, disposition_reason, _, _ =
    effective_disposition_fields ~fallback_disposition:disposition
      ~fallback_reason:disposition_reason latest_receipt
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

let pending_first_json pending_approvals =
  match pending_approvals with
  | `List (first :: _) ->
      let tool_name = json_string_opt_member "tool_name" first in
      let approval_id = json_string_opt_member "id" first in
      let task_id = json_string_opt_member "task_id" first in
      let blocker_class =
        match tool_name with
        | Some t when is_worktree_tool t -> Some "blocked_before_worktree"
        | _ -> None
      in
      `Assoc
        [
          ("id", Json_util.string_opt_to_json approval_id);
          ("tool_name", Json_util.string_opt_to_json tool_name);
          ("task_id", Json_util.string_opt_to_json task_id);
          ("blocker_class", Json_util.string_opt_to_json blocker_class);
        ]
  | _ -> `Null

let approval_state_json ~pending_approval_count ~pending_approvals ~latest_tool_call
    ~latest_approval_audit ~latest_receipt =
  let latest_rule_match =
    Option.bind latest_approval_audit (fun json ->
        match json_member "rule_match" json with
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
        receipt |> json_member "approval"
        |> json_string_opt_member "profile")
  in
  let state =
    if pending_approval_count > 0 then "pending"
    else
      match latest_event_kind with
      | Some "auto_approved_always" -> "always_flag"
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
      ("pending_first", pending_first_json pending_approvals);
    ]

let execution_summary_json ~meta ~latest_receipt =
  let sandbox_kind =
    match latest_receipt with
    | Some receipt ->
        receipt |> json_member "sandbox"
        |> json_string_opt_member "kind"
    | None -> Some (Keeper_types.sandbox_profile_to_string meta.sandbox_profile)
  in
  let network_mode =
    match latest_receipt with
    | Some receipt ->
        receipt |> json_member "sandbox"
        |> json_string_opt_member "network_mode"
    | None -> Some (Keeper_types.network_mode_to_string meta.network_mode)
  in
  let sandbox_root =
    match latest_receipt with
    | Some receipt ->
        receipt |> json_member "sandbox"
        |> json_string_opt_member "sandbox_root"
    | None -> None
  in
  let tool_contract_result =
    Option.bind latest_receipt (json_string_opt_member "tool_contract_result")
  in
  let requested_tools =
    match latest_receipt with
    | Some receipt -> json_string_list_member "requested_tools" receipt
    | None -> []
  in
  let tools_used =
    match latest_receipt with
    | Some receipt -> json_string_list_member "tools_used" receipt
    | None -> []
  in
  let required_tools, missing_required_tools =
    match latest_receipt with
    | Some receipt ->
        let surface = json_member "tool_surface" receipt in
        ( json_string_list_member "required_tools" surface,
          json_string_list_member "missing_required_tools" surface )
    | None -> [], []
  in
  let cascade_json =
    match latest_receipt with
    | Some receipt -> json_member "cascade" receipt
    | None -> `Null
  in
  let cascade_attempt_count =
    match cascade_json with
    | `Null -> None
    | json -> json_int_opt_member "attempt_count" json
  in
  let cascade_fallback_applied =
    match cascade_json with
    | `Null -> None
    | json -> json_bool_opt_member "fallback_applied" json
  in
  let cascade_outcome =
    match cascade_json with
    | `Null -> None
    | json -> json_string_opt_member "outcome" json
  in
  let cascade_selected_model =
    match cascade_json with
    | `Null -> None
    | json -> json_string_opt_member "selected_model" json
  in
  let mutation_guard_summary =
    match tool_contract_result with
    | Some "violated" -> "mutation_contract_violated"
    | Some ("satisfied" | "satisfied_execution" | "satisfied_completion") ->
        "mutation_contract_satisfied"
    | Some other -> other
    | None -> "mutation_contract_not_observed"
  in
  `Assoc
    [
      ("tool_contract_result", Json_util.string_opt_to_json tool_contract_result);
      ( "runtime_proof_status",
        Json_util.string_opt_to_json tool_contract_result );
      ("required_tools", string_list_json required_tools);
      ("missing_required_tools", string_list_json missing_required_tools);
      ("requested_tools", string_list_json requested_tools);
      ("tools_used", string_list_json tools_used);
      ("requested_tool_count", `Int (List.length requested_tools));
      ("tools_used_count", `Int (List.length tools_used));
      ( "provider_attempt_count",
        match cascade_attempt_count with
        | Some value -> `Int value
        | None -> `Null );
      ( "provider_fallback_applied",
        match cascade_fallback_applied with
        | Some value -> `Bool value
        | None -> `Null );
      ( "provider_selected_model",
        Json_util.string_opt_to_json cascade_selected_model );
      ( "cascade_outcome",
        Json_util.string_opt_to_json cascade_outcome );
      ( "sandbox_summary",
        match (sandbox_kind, network_mode) with
        | Some kind, Some mode -> `String (Printf.sprintf "%s / %s" kind mode)
        | Some kind, None -> `String kind
        | None, Some mode -> `String mode
        | None, None -> `Null );
      ("sandbox_root", Json_util.string_opt_to_json sandbox_root);
      ("mutation_guard_summary", `String mutation_guard_summary);
      ( "latest_receipt_at",
        match Option.bind latest_receipt (json_string_opt_member "ended_at") with
        | Some value -> `String value
        | None -> `Null );
    ]

let causal_timeline_json ~base_path ~meta ~latest_decision ~latest_receipt
    ~latest_tool_call ~latest_approval_audit ~runtime_blocker_fields
    ~next_human_action =
  let tool_events =
    Keeper_tool_call_log.read_recent ~keeper_name:meta.name ~n:6 ()
    |> List.filter_map tool_call_timeline_event
  in
  let approval_events =
    Keeper_approval_queue.read_recent_audit ~base_path ~keeper_name:meta.name
      ~n:8 ()
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
  let terminal_reason_events =
    [ terminal_reason_timeline_event ~latest_decision ~latest_receipt ]
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
  let live_pending_events =
    match pending_approval_json ~keeper_name:meta.name with
    | `List entries -> List.filter_map live_pending_approval_timeline_event entries
    | _ -> []
  in
  tool_events @ approval_events @ transition_events @ terminal_reason_events
  @ decision_events @ receipt_events @ blocker_events @ live_pending_events
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
  let latest_terminal_reason =
    latest_terminal_reason_opt ~latest_decision ~latest_receipt
  in
  let latest_terminal_reason_json =
    latest_terminal_reason
    |> Option.map Keeper_turn_terminal.to_json
    |> Option.value ~default:`Null
  in
  let latest_next_action =
    Option.bind latest_terminal_reason (fun reason -> reason.next_action)
  in
  let latest_approval_audit =
    match
      Keeper_approval_queue.read_recent_audit ~base_path:config.base_path
        ~keeper_name:meta.name ~n:1 ()
    with
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
        match json_member "telemetry" json with
        | `Assoc _ as telemetry ->
            (match json_string_opt_member "selected_model" telemetry with
             | Some _ as value -> value
             | None -> json_string_opt_member "model_used" telemetry)
        | _ -> None)
  in
  let runtime_contract =
    Keeper_runtime_contract.runtime_contract_json ~config meta
  in
  let fallback_disposition, fallback_disposition_reason =
    disposition_of_snapshot ~pending_approval_count ~runtime_blocker_fields
  in
  let disposition, disposition_reason, operator_disposition,
      operator_disposition_reason =
    effective_disposition_fields ~fallback_disposition
      ~fallback_reason:fallback_disposition_reason latest_receipt
  in
  let needs_attention =
    assoc_bool_default "needs_attention" ~default:false attention_fields
    || String.equal disposition "Pause"
    || String.equal disposition "Alert"
  in
  let attention_reason =
    assoc_string_opt "attention_reason" attention_fields
  in
  let next_human_action =
    assoc_string_opt "next_human_action" attention_fields
  in
  let approval_state =
    approval_state_json ~pending_approval_count ~pending_approvals
      ~latest_tool_call ~latest_approval_audit ~latest_receipt
  in
  let execution_summary =
    execution_summary_json ~meta ~latest_receipt
  in
  let causal_timeline =
    causal_timeline_json ~base_path:config.base_path ~meta ~latest_decision
      ~latest_receipt
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
      ("operator_disposition", `String operator_disposition);
      ("operator_disposition_reason", `String operator_disposition_reason);
      ("needs_attention", `Bool needs_attention);
      ("attention_reason", Json_util.string_opt_to_json attention_reason);
      ("next_human_action", Json_util.string_opt_to_json next_human_action);
      ("approval", approval_state);
      ("execution", execution_summary);
      ("latest_terminal_reason", latest_terminal_reason_json);
      ("latest_next_action", Json_util.string_opt_to_json latest_next_action);
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
