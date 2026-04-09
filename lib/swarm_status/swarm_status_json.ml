
open Swarm_status_types

let lane_kind_order = function
  | Managed -> 0
  | Supervised -> 1
  | Projected -> 2

let lane_id = function
  | Managed -> "managed"
  | Projected -> "projected"
  | Supervised -> "supervised"

let lane_label = function
  | Managed -> "Managed Operation"
  | Projected -> "Projected Swarm"
  | Supervised -> "Supervised Session"

let lane_kind_string = function
  | Managed -> "managed"
  | Projected -> "projected"
  | Supervised -> "supervised"

let source_of_truth = function
  | Managed -> "managed_command_plane"
  | Projected -> "projected_swarm_json"
  | Supervised -> "team_session_operator"

let swarm_surface_contract_json =
  `Assoc
    [
      ("overview", `String "derived");
      ("lanes", `String "derived");
      ("timeline", `String "truth");
      ("gaps", `String "derived");
      ("recommended_next_action", `String "fallback");
    ]

let option_map_to_json f = function
  | Some value -> f value
  | None -> `Null

let string_option_to_json = option_map_to_json (fun value -> `String value)

let flag_to_json (flag : flag) =
  `Assoc
    [
      ("code", `String flag.code);
      ("severity", `String flag.severity);
      ("summary", `String flag.summary);
      ("provenance", `String "derived");
    ]

let timeline_event_to_json (event : timeline_event) =
  `Assoc
    [
      ("event_id", `String event.event_id);
      ("lane_id", `String event.lane_id);
      ("kind", `String event.kind);
      ("timestamp", `String event.timestamp);
      ("title", `String event.title);
      ("detail", `String event.detail);
      ("tone", `String event.tone);
      ("source", `String event.source);
      ("provenance", `String "truth");
    ]

let lane_to_json (lane : lane) =
  `Assoc
    [
      ("lane_id", `String lane.lane_id);
      ("label", `String lane.label);
      ("kind", `String lane.kind);
      ("present", `Bool lane.present);
      ("phase", `String lane.phase);
      ("motion_state", `String lane.motion_state);
      ("source_of_truth", `String lane.source_of_truth);
      ("last_movement_at", string_option_to_json lane.last_movement_at);
      ("movement_reason", `String lane.movement_reason);
      ("current_step", `String lane.current_step);
      ("blockers", `List (List.map (fun item -> `String item) lane.blockers));
      ( "counts",
        `Assoc
          [
            ("operations", `Int lane.operations);
            ("detachments", `Int lane.detachments);
            ("workers", `Int lane.workers);
            ("approvals", `Int lane.approvals);
            ("alerts", `Int lane.alerts);
          ] );
      ("hard_flags", `List (List.map flag_to_json lane.hard_flags));
      ("provenance", `String "derived");
      ("authoritative", `Bool false);
    ]

let recommendation_to_json (item : recommendation) =
  `Assoc
    [
      ("tool", `String item.tool);
      ("label", `String item.label);
      ("reason", `String item.reason);
      ("lane_id", string_option_to_json item.lane_id);
      ("provenance", `String "fallback");
      ("decision_engine", `String "deterministic_lane_rules");
      ("authoritative", `Bool false);
    ]

let get_string_opt json key =
  match U.member key json with
  | `String value ->
      let trimmed = String.trim value in
      if trimmed = "" then None else Some trimmed
  | _ -> None

let get_string_default json key default =
  match get_string_opt json key with
  | Some value -> value
  | None -> default

let list_member json key =
  match U.member key json with
  | `List rows -> rows
  | _ -> []

let get_detail_string json key =
  match U.member "detail" json with
  | `Assoc _ as detail -> (
      match U.member key detail with
      | `String value ->
          let trimmed = String.trim value in
          if trimmed = "" then None else Some trimmed
      | _ -> None)
  | _ -> None

let first_some = Dashboard_utils.first_some

let iso_of_unix = Dashboard_utils.iso_of_unix

let parse_iso_timestamp = Types.parse_iso8601_opt

let parse_timestamp timestamp =
  Option.bind timestamp parse_iso_timestamp

let max_timestamp options =
  options
  |> List.filter_map (fun (reason, timestamp) ->
         match timestamp, parse_timestamp timestamp with
         | Some iso, Some unix -> Some (unix, iso, reason)
         | _ -> None)
  |> List.sort (fun (left, _, _) (right, _, _) -> Float.compare right left)
  |> function
  | (_, iso, reason) :: _ -> Some (iso, reason)
  | [] -> None

let safe_json_string value =
  match value with
  | `String text ->
      let trimmed = String.trim text in
      if trimmed = "" then "" else trimmed
  | `Assoc _ | `List _ ->
      Yojson.Safe.to_string value
  | `Null -> ""
  | _ -> Yojson.Safe.to_string value

let summarize_detail json =
  let direct_candidates =
    [ get_detail_string json "message"; get_detail_string json "kind"; get_detail_string json "reason" ]
  in
  match List.find_opt Option.is_some direct_candidates with
  | Some (Some value) -> value
  | _ ->
      let rendered = safe_json_string (U.member "detail" json) in
      if String.length rendered > 140 then
        String.sub rendered 0 137 ^ "..."
      else
        rendered

let humanize_identifier value =
  let normalized =
    value
    |> String.split_on_char '_'
    |> List.map String.trim
    |> List.filter (fun item -> item <> "")
    |> String.concat " "
  in
  if normalized = "" then
    value
  else
    let capitalized = Bytes.of_string normalized in
    Bytes.set capitalized 0 (Char.uppercase_ascii (Bytes.get capitalized 0));
    Bytes.to_string capitalized

let movement_reason_summary = function
  | "recent_trace_event" -> "Recent trace evidence shows the lane is moving."
  | "pending_manual_confirmation" -> "Progress is paused until a manual confirmation is resolved."
  | "awaiting_policy_approval" -> "A policy approval is still gating the next transition."
  | "recent_worker_progress" -> "Recent worker progress is visible in the freshness window."
  | "recent_detachment_event" -> "A detachment event moved this lane recently."
  | "operation_updated" -> "The lane changed because its operation record was updated."
  | "session_event" -> "The lane changed because the execution session recorded a new event."
  | "session_updated" -> "The execution session metadata was updated recently."
  | "detachment_updated" -> "The detachment metadata was updated recently."
  | "no_active_data" -> "No active lane data is currently present."
  | "missing_runtime_progress" -> "No fresh runtime progress is currently visible."
  | other -> humanize_identifier other

let gap_guidance ~lane_ids code =
  let has_lane lane_id = List.exists (String.equal lane_id) lane_ids in
  match code with
  | "pending_manual_confirmation" when has_lane "managed" ->
      ( "Managed runtime cannot continue while a confirmation is pending.",
        "masc_policy_approve",
        "Approve or deny the pending managed action before checking more traces." )
  | "pending_manual_confirmation" ->
      ( "The supervised lane is waiting on an operator confirmation.",
        "masc_operator_confirm",
        "Confirm or deny the pending operator action before expecting more movement." )
  | "missing_worker_binding" ->
      ( "A supervised session with no worker binding cannot produce meaningful collaboration evidence.",
        "masc_team_session_status",
        "Inspect the execution session and attach or restart a worker before reading proof." )
  | "projected_only" ->
      ( "Projected swarm state shows intent, but not a live runtime.",
        "masc_operation_start",
        "Materialize a managed operation if this projected lane should become real work." )
  | "stale_data" when has_lane "managed" ->
      ( "Managed runtime exists, but the freshness window has expired.",
        "masc_dispatch_tick",
        "Run a dispatch tick or inspect managed traces to confirm whether progress is stuck." )
  | "stale_data" when has_lane "supervised" ->
      ( "The supervised session has gone stale and may no longer reflect active collaboration.",
        "masc_team_session_status",
        "Check the session status and recent worker events before treating it as active." )
  | "missing_trace_events" ->
      ( "Without trace events, the dashboard cannot show why the swarm moved or stalled.",
        "masc_observe_traces",
        "Collect or inspect recent trace events for the affected lane." )
  | "missing_runtime_progress" ->
      ( "The dashboard sees the lane, but not a fresh progress signal.",
        "masc_observe_traces",
        "Inspect traces and recent runtime messages to find the missing progress signal." )
  | "dashboard_source_split" ->
      ( "Projected and runtime-backed lanes are both active, so one surface can look contradictory.",
        "masc_observe_operations",
        "Compare projected state against managed operations before interpreting the swarm as one story." )
  | _ ->
      ( "This flag marks a gap between visible state and trustworthy runtime proof.",
        "masc_observe_traces",
        "Inspect recent traces before taking an operational action." )

let lane_kind_of_id lane_id =
  match lane_id with
  | "managed" -> Managed
  | "supervised" -> Supervised
  | _ -> Projected

let lane_has_flag lane code =
  List.exists (fun (flag : flag) -> String.equal flag.code code) lane.hard_flags

let lane_has_bad_flag lane =
  List.exists (fun (flag : flag) -> String.equal flag.severity "bad") lane.hard_flags

let lane_timestamp_key lane =
  match parse_timestamp lane.last_movement_at with
  | Some ts -> ts
  | None -> neg_infinity

let fallback_primary_lane present_lanes =
  present_lanes
  |> List.sort (fun (left : lane) (right : lane) ->
         let left_ts = lane_timestamp_key left in
         let right_ts = lane_timestamp_key right in
         let by_motion =
           match
             String.equal left.motion_state "moving",
             String.equal right.motion_state "moving"
           with
           | true, false -> -1
           | false, true -> 1
           | _ -> 0
         in
         if by_motion <> 0 then
           by_motion
         else
           let by_time = Float.compare right_ts left_ts in
           if by_time <> 0 then
             by_time
           else
             Int.compare
               (lane_kind_order (lane_kind_of_id left.lane_id))
               (lane_kind_order (lane_kind_of_id right.lane_id)))
  |> function
  | lane :: _ -> Some lane
  | [] -> None

let choose_primary_lane present_lanes recommendation =
  let find_lane_by pred = List.find_opt pred present_lanes in
  match
    Option.bind recommendation.lane_id (fun lane_id ->
        find_lane_by (fun (lane : lane) -> String.equal lane.lane_id lane_id))
  with
  | Some lane -> Some lane
  | None -> (
      match find_lane_by (fun lane -> lane_has_flag lane "pending_manual_confirmation") with
      | Some lane -> Some lane
      | None -> (
          match find_lane_by lane_has_bad_flag with
          | Some lane -> Some lane
          | None -> (
              match find_lane_by (fun lane -> lane_has_flag lane "stale_data") with
              | Some lane -> Some lane
              | None -> fallback_primary_lane present_lanes)))

let narrative_json (lanes : lane list) (timeline : timeline_event list)
    (recommendation : recommendation) =
  let present_lanes = List.filter (fun (lane : lane) -> lane.present) lanes in
  let primary_lane = choose_primary_lane present_lanes recommendation in
  let state =
    if present_lanes = [] then
      "idle"
    else if List.exists (fun (lane : lane) -> String.equal lane.motion_state "stalled") present_lanes then
      "stalled"
    else if List.exists (fun (lane : lane) -> String.equal lane.phase "completed") present_lanes then
      "completed"
    else if List.exists (fun (lane : lane) -> String.equal lane.motion_state "moving") present_lanes then
      "running"
    else
      "waiting"
  in
  let timeline_for_primary_lane =
    match primary_lane with
    | Some lane ->
        timeline
        |> List.filter (fun (event : timeline_event) ->
               String.equal event.lane_id lane.lane_id)
    | None -> []
  in
  let started =
    match
      timeline_for_primary_lane
      |> List.filter_map (fun (event : timeline_event) ->
             match parse_iso_timestamp event.timestamp with
             | Some ts -> Some (ts, event)
             | None -> None)
      |> List.sort (fun (left_ts, _) (right_ts, _) -> Float.compare left_ts right_ts)
    with
    | (_, event) :: _ -> Printf.sprintf "%s. %s" event.title event.detail
    | [] -> (
        match primary_lane with
        | Some lane ->
            Printf.sprintf "%s became the primary visible lane." lane.label
        | None -> "No visible swarm start signal is recorded yet.")
  in
  let active_work =
    match primary_lane with
    | Some lane ->
        Printf.sprintf "%s. %s" lane.current_step
          (movement_reason_summary lane.movement_reason)
    | None -> recommendation.reason
  in
  let completion =
    match
      List.find_opt
        (fun (lane : lane) -> String.equal lane.phase "completed")
        present_lanes
    with
    | Some lane ->
        Printf.sprintf "Completion evidence is visible for %s." lane.label
    | None -> "No completion evidence is visible yet."
  in
  `Assoc
    [
      ("state", `String state);
      ("started", `String started);
      ("active_work", `String active_work);
      ("completion", `String completion);
      ( "lane_id",
        match primary_lane with Some lane -> `String lane.lane_id | None -> `Null );
    ]
