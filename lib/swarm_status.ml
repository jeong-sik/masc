module U = Yojson.Safe.Util

type lane_kind =
  | Managed
  | Projected
  | Supervised

type flag = {
  code : string;
  severity : string;
  summary : string;
}

type timeline_event = {
  event_id : string;
  lane_id : string;
  kind : string;
  timestamp : string;
  title : string;
  detail : string;
  tone : string;
  source : string;
}

type lane = {
  lane_id : string;
  label : string;
  kind : string;
  present : bool;
  phase : string;
  motion_state : string;
  source_of_truth : string;
  last_movement_at : string option;
  movement_reason : string;
  current_step : string;
  blockers : string list;
  operations : int;
  detachments : int;
  workers : int;
  approvals : int;
  alerts : int;
  hard_flags : flag list;
}

type recommendation = {
  tool : string;
  label : string;
  reason : string;
  lane_id : string option;
}

type operation_info = {
  operation_id : string;
  objective : string;
  source : string;
  status : string;
  trace_id : string;
  detachment_session_id : string option;
  note : string option;
  updated_at : string option;
}

type detachment_info = {
  detachment_id : string;
  operation_id : string;
  source : string;
  status : string;
  runtime_kind : string option;
  session_id : string option;
  roster : string list;
  leader_id : string option;
  last_event_at : string option;
  last_progress_at : string option;
  updated_at : string option;
}

type alert_info = {
  alert_id : string;
  severity : string;
  scope_type : string option;
  scope_id : string option;
  title : string option;
  detail : string option;
  timestamp : string option;
}

type decision_info = {
  decision_id : string;
  source : string;
  status : string;
  scope_type : string option;
  scope_id : string option;
  operation_id : string option;
  requested_action : string option;
  created_at : string option;
}

type trace_info = {
  event_id : string;
  event_type : string;
  source : string;
  trace_id : string;
  operation_id : string option;
  actor : string option;
  timestamp : string option;
  detail : Yojson.Safe.t;
}

type session_info = {
  session_id : string;
  goal : string;
  status : string;
  started_at : float;
  updated_at_iso : string;
  last_event_at : string option;
  last_turn_at : string option;
  worker_names : string list;
  min_agents_violation_streak : int;
  policy_violation_count : int;
}

let moving_window_sec = 300.0
let stale_window_sec = 900.0
let timeline_limit = 20

let lane_kind_order = function
  | Managed -> 0
  | Supervised -> 1
  | Projected -> 2

let lane_id = function
  | Managed -> "managed"
  | Projected -> "projected"
  | Supervised -> "supervised"

let lane_label = function
  | Managed -> "Managed CPv2"
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
    ]

let recommendation_to_json (item : recommendation) =
  `Assoc
    [
      ("tool", `String item.tool);
      ("label", `String item.label);
      ("reason", `String item.reason);
      ("lane_id", string_option_to_json item.lane_id);
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
  match U.member "detail" json |> U.member key with
  | `String value ->
      let trimmed = String.trim value in
      if trimmed = "" then None else Some trimmed
  | _ -> None

let first_some left right =
  match left with
  | Some _ -> left
  | None -> right

let parse_timestamp timestamp =
  Option.bind timestamp Command_plane_v2.parse_iso_timestamp

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

let operation_of_json row =
  let json = U.member "operation" row in
  {
    operation_id = get_string_default json "operation_id" "";
    objective = get_string_default json "objective" "";
    source = get_string_default json "source" "managed";
    status = get_string_default json "status" "active";
    trace_id = get_string_default json "trace_id" "";
    detachment_session_id = get_string_opt json "detachment_session_id";
    note = get_string_opt json "note";
    updated_at = get_string_opt json "updated_at";
  }

let detachment_of_json row =
  let json = U.member "detachment" row in
  {
    detachment_id = get_string_default json "detachment_id" "";
    operation_id = get_string_default json "operation_id" "";
    source = get_string_default json "source" "managed";
    status = get_string_default json "status" "active";
    runtime_kind = get_string_opt json "runtime_kind";
    session_id = get_string_opt json "session_id";
    roster =
      list_member json "roster"
      |> List.filter_map (function
           | `String value ->
               let trimmed = String.trim value in
               if trimmed = "" then None else Some trimmed
           | _ -> None);
    leader_id = get_string_opt json "leader_id";
    last_event_at = get_string_opt json "last_event_at";
    last_progress_at = get_string_opt json "last_progress_at";
    updated_at = get_string_opt json "updated_at";
  }

let alert_of_json json =
  {
    alert_id = get_string_default json "alert_id" "";
    severity = get_string_default json "severity" "warn";
    scope_type = get_string_opt json "scope_type";
    scope_id = get_string_opt json "scope_id";
    title = get_string_opt json "title";
    detail = get_string_opt json "detail";
    timestamp = get_string_opt json "timestamp";
  }

let decision_of_json json =
  {
    decision_id = get_string_default json "decision_id" "";
    source = get_string_default json "source" "managed";
    status = get_string_default json "status" "pending";
    scope_type = get_string_opt json "scope_type";
    scope_id = get_string_opt json "scope_id";
    operation_id = get_string_opt json "operation_id";
    requested_action = get_string_opt json "requested_action";
    created_at = get_string_opt json "created_at";
  }

let trace_of_json json =
  {
    event_id = get_string_default json "event_id" "";
    event_type = get_string_default json "event_type" "trace";
    source = get_string_default json "source" "command_plane";
    trace_id = get_string_default json "trace_id" "";
    operation_id = get_string_opt json "operation_id";
    actor = get_string_opt json "actor";
    timestamp = get_string_opt json "timestamp";
    detail =
      match U.member "detail" json with
      | `Assoc _ as detail -> detail
      | `List _ as detail -> detail
      | `Null -> `Assoc []
      | value -> value;
  }

let session_worker_names (session : Team_session_types.session) =
  let actor_names =
    session.agent_names
    @ List.filter_map
        (fun (worker : Team_session_types.planned_worker) -> worker.runtime_actor)
        session.planned_workers
  in
  Team_session_types.dedup_strings actor_names

let session_info_of_session (session : Team_session_types.session) =
  {
    session_id = session.session_id;
    goal = session.goal;
    status = Team_session_types.status_to_string session.status;
    started_at = session.started_at;
    updated_at_iso = session.updated_at_iso;
    last_event_at = Option.map Command_plane_v2.iso_of_unix session.last_event_at;
    last_turn_at = Option.map Command_plane_v2.iso_of_unix session.last_turn_at;
    worker_names = session_worker_names session;
    min_agents_violation_streak = session.min_agents_violation_streak;
    policy_violation_count = List.length session.policy_violations;
  }

let operation_active (operation : operation_info) =
  match String.lowercase_ascii operation.status with
  | "completed" | "cancelled" | "failed" -> false
  | _ -> true

let operation_terminal (operation : operation_info) = not (operation_active operation)

let detachment_active (detachment : detachment_info) =
  match String.lowercase_ascii detachment.status with
  | "completed" | "cancelled" | "failed" | "stopped" -> false
  | _ -> true

let decision_pending (decision : decision_info) =
  String.equal (String.lowercase_ascii decision.status) "pending"

let session_active (session : session_info) =
  match String.lowercase_ascii session.status with
  | "running" | "paused" -> true
  | _ -> false

let classify_operation (operation : operation_info) =
  if String.equal operation.source "managed" then
    Managed
  else if operation.detachment_session_id <> None then
    Supervised
  else if String.starts_with ~prefix:"swarm-" operation.operation_id
          || String.starts_with ~prefix:"swarm-trace-" operation.trace_id
  then
    Projected
  else
    Projected

let classify_detachment operations_by_id (detachment : detachment_info) =
  if String.equal detachment.source "managed" then
    Managed
  else
    match detachment.runtime_kind with
    | Some "team_session" -> Supervised
    | Some "swarm_projection" -> Projected
    | _ -> (
        match List.assoc_opt detachment.operation_id operations_by_id with
        | Some kind -> kind
        | None ->
            if detachment.session_id <> None then Supervised else Projected)

let classify_alert operations_by_id detachments_by_id (alert : alert_info) =
  match alert.scope_type, alert.scope_id with
  | Some "operation", Some scope_id -> Option.value ~default:Managed (List.assoc_opt scope_id operations_by_id)
  | Some "detachment", Some scope_id -> Option.value ~default:Managed (List.assoc_opt scope_id detachments_by_id)
  | _ -> Managed

let classify_decision operations_by_id (decision : decision_info) =
  if String.equal decision.source "projected_operator" then
    Supervised
  else
    match decision.operation_id with
    | Some operation_id -> Option.value ~default:Managed (List.assoc_opt operation_id operations_by_id)
    | None -> (
        match decision.scope_type with
        | Some "team_session" -> Supervised
        | _ -> Managed)

let classify_trace operations_by_id (trace : trace_info) =
  if String.equal trace.source "team_session" || String.equal trace.source "operator" then
    Supervised
  else if String.equal trace.source "swarm"
          || String.starts_with ~prefix:"swarm-trace-" trace.trace_id
  then
    Projected
  else
    match trace.operation_id with
    | Some operation_id -> Option.value ~default:Managed (List.assoc_opt operation_id operations_by_id)
    | None -> Managed

let severity_sort = function
  | "bad" -> 0
  | "warn" -> 1
  | _ -> 2

let compare_flag (left : flag) (right : flag) =
  let by_severity =
    Int.compare (severity_sort left.severity) (severity_sort right.severity)
  in
  if by_severity <> 0 then by_severity
  else String.compare left.code right.code

let unique_strings values =
  let table = Hashtbl.create 16 in
  values
  |> List.filter (fun value ->
         if String.trim value = "" then
           false
         else if Hashtbl.mem table value then
           false
         else (
           Hashtbl.add table value ();
           true))

let worker_names_from_detachments detachments =
  detachments
  |> List.concat_map (fun (detachment : detachment_info) ->
         detachment.roster
         @ (match detachment.leader_id with Some value -> [ value ] | None -> []))
  |> unique_strings

let lane_last_movement traces decisions detachments operations sessions =
  let trace_candidates =
    traces |> List.map (fun (trace : trace_info) -> ("recent_trace_event", trace.timestamp))
  in
  let decision_candidates =
    decisions
    |> List.filter (fun (decision : decision_info) -> String.equal decision.status "pending")
    |> List.map (fun (decision : decision_info) ->
           if String.equal decision.source "projected_operator" then
             ("pending_manual_confirmation", decision.created_at)
           else
             ("awaiting_policy_approval", decision.created_at))
  in
  let detachment_candidates =
    detachments
    |> List.concat_map (fun (detachment : detachment_info) ->
           [
             ("recent_worker_progress", detachment.last_progress_at);
             ("recent_detachment_event", detachment.last_event_at);
             ("detachment_updated", detachment.updated_at);
           ])
  in
  let operation_candidates =
    operations
    |> List.map (fun (operation : operation_info) -> ("operation_updated", operation.updated_at))
  in
  let session_candidates =
    sessions
    |> List.concat_map (fun (session : session_info) ->
           [
             ("recent_worker_progress", session.last_turn_at);
             ("session_event", session.last_event_at);
             ("session_updated", Some session.updated_at_iso);
           ])
  in
  max_timestamp
    (trace_candidates @ decision_candidates @ detachment_candidates @ operation_candidates
   @ session_candidates)

let lane_motion_state now ~present ~phase ~last_movement_at ~approvals =
  if not present then
    "waiting"
  else if String.equal phase "completed" then
    "terminal"
  else
    match parse_timestamp last_movement_at with
    | Some ts when now -. ts <= moving_window_sec -> "moving"
    | Some ts when now -. ts <= stale_window_sec ->
        if approvals > 0 then "waiting" else "waiting"
    | Some _ -> "stalled"
    | None ->
        if approvals > 0 then "waiting" else "stalled"

let lane_phase ~present ~active_operations ~detachments ~workers ~approvals ~motion_state ~terminal =
  if not present then
    "forming"
  else if terminal && approvals = 0 then
    "completed"
  else if approvals > 0 then
    "awaiting_approval"
  else if active_operations > 0 && detachments = 0 then
    "dispatching"
  else if String.equal motion_state "stalled" then
    "blocked"
  else if detachments > 0 || workers > 0 then
    "executing"
  else
    "forming"

let lane_current_step kind ~present ~phase ~motion_state ~approvals ~detachments ~workers =
  match kind with
  | Managed ->
      if not present then "Start a managed operation"
      else if approvals > 0 then "Resolve pending policy approval"
      else if String.equal phase "dispatching" then "Materialize detachments with dispatch tick"
      else if String.equal motion_state "stalled" then "Inspect traces or run dispatch tick"
      else if detachments > 0 then "Observe active detachments"
      else "Track managed execution"
  | Projected ->
      if not present then "No projected swarm is active"
      else if approvals > 0 then "Resolve manual approval before converting projection"
      else "Convert projection into managed runtime"
  | Supervised ->
      if not present then "No supervised team session is active"
      else if approvals > 0 then "Confirm the pending operator action"
      else if workers = 0 then "Bind runtime workers to the session"
      else if String.equal motion_state "stalled" then "Inspect session status and recent events"
      else "Observe team-session progress"

let lane_blockers kind ~phase ~motion_state ~approvals ~workers ~flags =
  let base = [] in
  let base =
    if approvals > 0 then
      "Manual approval is still blocking this lane." :: base
    else base
  in
  let base =
    if String.equal motion_state "stalled" then
      "No recent progress is visible inside the freshness window." :: base
    else base
  in
  let base =
    match kind with
    | Supervised when workers = 0 && not (String.equal phase "completed") ->
        "No worker binding is visible for the supervised session." :: base
    | Projected when List.exists (fun (flag : flag) -> String.equal flag.code "projected_only") flags ->
        "This lane is projection-only and has no managed runtime backing." :: base
    | _ -> base
  in
  List.rev base

let append_flag flags code severity summary =
  if List.exists (fun (flag : flag) -> String.equal flag.code code) flags then
    flags
  else
    { code; severity; summary } :: flags

let lane_flags kind ~present ~approvals ~workers ~trace_count ~last_movement_at
    ~mixed_runtime_sources =
  let flags = [] in
  let flags =
    match kind with
    | Projected when present ->
        append_flag flags "projected_only" "warn"
          "Projected state is visible without managed runtime backing."
    | _ -> flags
  in
  let flags =
    if present && trace_count = 0 then
      append_flag flags "missing_trace_events" "warn"
        "No trace events are attached to this lane."
    else flags
  in
  let flags =
    if present && approvals > 0 then
      append_flag flags "pending_manual_confirmation" "warn"
        "Manual approval or confirmation is still pending."
    else flags
  in
  let flags =
    match kind with
    | Supervised when present && workers = 0 ->
        append_flag flags "missing_worker_binding" "bad"
          "The supervised lane has no visible worker binding."
    | _ -> flags
  in
  let flags =
    if present && last_movement_at = None then
      append_flag flags "missing_runtime_progress" "warn"
        "Runtime progress is missing for this lane."
    else flags
  in
  let flags =
    match parse_timestamp last_movement_at with
    | Some ts when present && Time_compat.now () -. ts > stale_window_sec ->
        append_flag flags "stale_data" "warn"
          "The most recent movement is older than the freshness window."
    | _ -> flags
  in
  let flags =
    if mixed_runtime_sources then
      append_flag flags "dashboard_source_split" "warn"
        "Projected and runtime-backed lanes are both active; compare them separately."
    else flags
  in
  List.sort compare_flag flags

let lane_timeline_events kind traces sessions decisions =
  let trace_events =
    traces
    |> List.filter_map (fun (trace : trace_info) ->
           match trace.timestamp with
           | None -> None
           | Some timestamp ->
               Some
                 {
                   event_id = trace.event_id;
                   lane_id = lane_id kind;
                   kind = trace.event_type;
                   timestamp;
                   title = trace.event_type;
                   detail = summarize_detail (`Assoc [ ("detail", trace.detail) ]);
                   tone = if String.equal trace.source "operator" then "warn" else "ok";
                   source = trace.source;
                 })
  in
  let session_events =
    sessions
    |> List.map (fun (session : session_info) ->
           {
             event_id = "session-" ^ session.session_id;
             lane_id = lane_id kind;
             kind = "session_state";
             timestamp =
               Option.value ~default:session.updated_at_iso
                 (first_some session.last_turn_at session.last_event_at);
             title = session.goal;
             detail =
               Printf.sprintf "session %s is %s"
                 session.session_id session.status;
             tone =
               if String.equal session.status "running" then "ok" else "warn";
             source = "team_session";
           })
  in
  let approval_events =
    decisions
    |> List.filter (fun (decision : decision_info) -> String.equal decision.status "pending")
    |> List.filter_map (fun (decision : decision_info) ->
           match decision.created_at with
           | None -> None
           | Some timestamp ->
               Some
                 {
                   event_id = "decision-" ^ decision.decision_id;
                   lane_id = lane_id kind;
                   kind = "pending_confirmation";
                   timestamp;
                   title =
                     Option.value ~default:"Pending approval" decision.requested_action;
                   detail = "Manual confirmation is still pending.";
                   tone = "warn";
                   source = decision.source;
                 })
  in
  trace_events @ session_events @ approval_events

let projected_refresh_event operations detachments =
  let timestamps =
    (operations
     |> List.filter_map (fun (operation : operation_info) -> operation.updated_at))
    @ (detachments
      |> List.filter_map (fun (detachment : detachment_info) ->
             first_some detachment.last_progress_at detachment.updated_at))
  in
  let latest =
    timestamps
    |> List.filter_map (fun timestamp ->
           match Command_plane_v2.parse_iso_timestamp timestamp with
           | Some ts -> Some (ts, timestamp)
           | None -> None)
    |> List.sort (fun (left, _) (right, _) -> Float.compare right left)
    |> function
    | (_, timestamp) :: _ -> Some timestamp
    | [] -> None
  in
  Option.map
    (fun timestamp ->
      {
        event_id = "projected-refresh";
        lane_id = lane_id Projected;
        kind = "projection_refresh";
        timestamp;
        title = "Projected swarm state refreshed";
        detail = "Projected swarm data was refreshed from .masc/swarm.json.";
        tone = "warn";
        source = "swarm_projection";
      })
    latest

let read_operation_infos config =
  Command_plane_v2.list_operations_json config
  |> fun json -> list_member json "operations"
  |> List.map operation_of_json
  |> List.filter (fun (operation : operation_info) -> operation.operation_id <> "")

let read_detachment_infos config =
  Command_plane_v2.list_detachments_json config
  |> fun json -> list_member json "detachments"
  |> List.map detachment_of_json
  |> List.filter (fun (detachment : detachment_info) ->
         detachment.detachment_id <> "")

let read_alert_infos config =
  Command_plane_v2.list_alerts_json config
  |> fun json -> list_member json "alerts"
  |> List.map alert_of_json
  |> List.filter (fun (alert : alert_info) -> alert.alert_id <> "")

let read_decision_infos config =
  Command_plane_v2.list_policy_decisions_json config
  |> fun json -> list_member json "decisions"
  |> List.map decision_of_json
  |> List.filter (fun (decision : decision_info) -> decision.decision_id <> "")

let read_trace_infos ?(limit = timeline_limit) config =
  Command_plane_v2.list_traces_json config ~limit ()
  |> fun json -> list_member json "events"
  |> List.map trace_of_json
  |> List.filter (fun (trace : trace_info) -> trace.event_id <> "")

let read_session_infos config =
  Team_session_store.list_sessions config |> List.map session_info_of_session

let operation_infos_of_snapshot snapshot =
  snapshot
  |> U.member "operations"
  |> fun json -> list_member json "operations"
  |> List.map operation_of_json
  |> List.filter (fun (operation : operation_info) -> operation.operation_id <> "")

let detachment_infos_of_snapshot snapshot =
  snapshot
  |> U.member "detachments"
  |> fun json -> list_member json "detachments"
  |> List.map detachment_of_json
  |> List.filter (fun (detachment : detachment_info) ->
         detachment.detachment_id <> "")

let alert_infos_of_snapshot snapshot =
  snapshot
  |> U.member "alerts"
  |> fun json -> list_member json "alerts"
  |> List.map alert_of_json
  |> List.filter (fun (alert : alert_info) -> alert.alert_id <> "")

let decision_infos_of_snapshot snapshot =
  snapshot
  |> U.member "decisions"
  |> fun json -> list_member json "decisions"
  |> List.map decision_of_json
  |> List.filter (fun (decision : decision_info) -> decision.decision_id <> "")

let trace_infos_of_snapshot snapshot =
  snapshot
  |> U.member "traces"
  |> fun json -> list_member json "events"
  |> List.map trace_of_json
  |> List.filter (fun (trace : trace_info) -> trace.event_id <> "")

let slice_by_kind kind classify rows =
  List.filter (fun row -> classify row = kind) rows

let lane_present kind ~operations ~detachments ~alerts ~decisions ~traces ~sessions =
  match kind with
  | Managed ->
      (* Managed lanes should reflect live command-plane runtime, not historical
         trace residue. Current managed alerts are recomputed from snapshot state
         and must keep the lane visible, but old traces alone should not keep it
         present forever and surface stale_data as if work were still in flight. *)
      List.exists operation_active operations
      || List.exists detachment_active detachments
      || List.exists decision_pending decisions
      || alerts <> []
  | Supervised ->
      (* Supervised traces are historical. Only live session/runtime artifacts should
         make the lane present, otherwise stale operator/team-session traces create a
         phantom supervised lane after the real session has already ended. *)
      operations <> [] || detachments <> [] || decisions <> [] || sessions <> []
  | Projected ->
      operations <> [] || detachments <> [] || alerts <> [] || decisions <> [] || traces <> []
      || sessions <> []

let lane_for_kind kind ~now ~operations ~detachments ~alerts ~decisions ~traces
    ~sessions ~mixed_runtime_sources =
  let workers =
    match kind with
    | Supervised ->
        sessions |> List.concat_map (fun (session : session_info) -> session.worker_names)
        |> unique_strings |> List.length
    | Managed | Projected ->
        worker_names_from_detachments detachments |> List.length
  in
  let present = lane_present kind ~operations ~detachments ~alerts ~decisions ~traces ~sessions in
  let approvals =
    decisions
    |> List.filter (fun (decision : decision_info) -> String.equal decision.status "pending")
    |> List.length
  in
  let alerts_count = List.length alerts in
  let terminal =
    present
    && operations <> []
    && List.for_all operation_terminal operations
    && approvals = 0
  in
  let active_operations =
    operations |> List.filter operation_active |> List.length
  in
  let last_movement, movement_reason =
    match lane_last_movement traces decisions detachments operations sessions with
    | Some (timestamp, reason) -> (Some timestamp, reason)
    | None ->
        if not present then
          (None, "no_active_data")
        else
          (None, "missing_runtime_progress")
  in
  let motion_state =
    lane_motion_state now ~present ~phase:"" ~last_movement_at:last_movement ~approvals
  in
  let phase =
    lane_phase ~present ~active_operations ~detachments:(List.length detachments)
      ~workers ~approvals ~motion_state ~terminal
  in
  let flags =
    lane_flags kind ~present ~approvals ~workers ~trace_count:(List.length traces)
      ~last_movement_at:last_movement ~mixed_runtime_sources
  in
  let blockers =
    lane_blockers kind ~phase ~motion_state ~approvals ~workers ~flags
  in
  let current_step =
    lane_current_step kind ~present ~phase ~motion_state ~approvals
      ~detachments:(List.length detachments) ~workers
  in
  {
    lane_id = lane_id kind;
    label = lane_label kind;
    kind = lane_kind_string kind;
    present;
    phase;
    motion_state;
    source_of_truth = source_of_truth kind;
    last_movement_at = last_movement;
    movement_reason;
    current_step;
    blockers;
    operations = List.length operations;
    detachments = List.length detachments;
    workers;
    approvals;
    alerts = alerts_count;
    hard_flags = flags;
  }

let choose_recommendation lanes =
  let find_lane lane_id =
    List.find_opt (fun (lane : lane) -> String.equal lane.lane_id lane_id) lanes
  in
  let has_flag lane code =
    List.exists (fun (flag : flag) -> String.equal flag.code code) lane.hard_flags
  in
  match List.find_opt (fun (lane : lane) -> has_flag lane "pending_manual_confirmation") lanes with
  | Some lane when String.equal lane.lane_id "managed" ->
      {
        tool = "masc_policy_approve";
        label = "Resolve pending approval";
        reason = "A managed command-plane decision is blocking progress.";
        lane_id = Some lane.lane_id;
      }
  | Some lane ->
      {
        tool = "masc_operator_confirm";
        label = "Confirm the pending action";
        reason = "A supervised operator action is still waiting for confirmation.";
        lane_id = Some lane.lane_id;
      }
  | None -> (
      match
        List.find_opt
          (fun (lane : lane) ->
            String.equal lane.lane_id "managed"
            && lane.present && lane.detachments = 0 && lane.operations > 0)
          lanes
      with
      | Some lane ->
          {
            tool = "masc_dispatch_tick";
            label = "Materialize detachments";
            reason = "Managed operations exist, but detachments have not been reconciled yet.";
            lane_id = Some lane.lane_id;
          }
      | None -> (
          match
            List.find_opt
              (fun (lane : lane) ->
                String.equal lane.lane_id "managed" && has_flag lane "stale_data")
              lanes
          with
          | Some lane ->
              {
                tool = "masc_dispatch_tick";
                label = "Reconcile the managed lane";
                reason = "The managed lane is stale and needs a dispatch tick or trace check.";
                lane_id = Some lane.lane_id;
              }
          | None -> (
              match
                List.find_opt
                  (fun (lane : lane) ->
                    String.equal lane.lane_id "supervised"
                    && has_flag lane "stale_data")
                  lanes
              with
              | Some lane ->
                  {
                    tool = "masc_team_session_status";
                    label = "Inspect the team session";
                    reason = "The supervised lane is stale and needs a session status check.";
                    lane_id = Some lane.lane_id;
                  }
              | None -> (
                  match
                    ( find_lane "projected",
                      find_lane "managed",
                      find_lane "supervised" )
                  with
                  | Some projected, Some managed, _
                    when projected.present && not managed.present ->
                      {
                        tool = "masc_operation_start";
                        label = "Convert projection into runtime";
                        reason = "Projected swarm state exists without a managed operation.";
                        lane_id = Some projected.lane_id;
                      }
                  | Some projected, _, Some supervised
                    when projected.present && not supervised.present ->
                      {
                        tool = "masc_team_session_start";
                        label = "Start a supervised session";
                        reason = "Projected swarm state exists without a supervised session.";
                        lane_id = Some projected.lane_id;
                      }
                  | _ ->
                      {
                        tool = "masc_observe_traces";
                        label = "Observe recent movement";
                        reason = "The swarm is moving; trace review is the next high-signal step.";
                        lane_id = None;
                      }))))

let build_json_from_inputs ~timeline_limit_override ~now
    ~operations ~detachments ~alerts ~decisions ~traces ~sessions =
  let operation_kinds =
    operations
    |> List.map (fun (operation : operation_info) ->
           (operation.operation_id, classify_operation operation))
  in
  let detachment_kinds =
    detachments
    |> List.map (fun (detachment : detachment_info) ->
           ( detachment.detachment_id,
             classify_detachment operation_kinds detachment ))
  in
  let mixed_runtime_sources =
    let has_managed =
      List.exists (fun (operation : operation_info) -> classify_operation operation = Managed) operations
      || List.exists
           (fun (detachment : detachment_info) ->
             classify_detachment operation_kinds detachment = Managed)
           detachments
    in
    let has_projected =
      List.exists (fun (operation : operation_info) -> classify_operation operation = Projected) operations
      || List.exists
           (fun (detachment : detachment_info) ->
             classify_detachment operation_kinds detachment = Projected)
           detachments
    in
    has_managed && has_projected
  in
  let alerts_by_kind kind =
    slice_by_kind kind (classify_alert operation_kinds detachment_kinds) alerts
  in
  let decisions_by_kind kind =
    slice_by_kind kind (classify_decision operation_kinds) decisions
  in
  let traces_by_kind kind =
    slice_by_kind kind (classify_trace operation_kinds) traces
  in
  let lanes =
    [ Managed; Supervised; Projected ]
    |> List.map (fun kind ->
           let lane_operations =
             slice_by_kind kind classify_operation operations
             |> (match kind with
                | Supervised -> List.filter operation_active
                | Managed | Projected -> Fun.id)
           in
           let lane_detachments =
             slice_by_kind kind (classify_detachment operation_kinds) detachments
             |> (match kind with
                | Supervised -> List.filter detachment_active
                | Managed | Projected -> Fun.id)
           in
           let lane_decisions =
             decisions_by_kind kind
             |> (match kind with
                | Supervised -> List.filter decision_pending
                | Managed | Projected -> Fun.id)
           in
           let lane_sessions =
             match kind with
             | Supervised -> List.filter session_active sessions
             | Managed | Projected -> []
           in
           lane_for_kind kind ~now ~operations:lane_operations
             ~detachments:lane_detachments ~alerts:(alerts_by_kind kind)
             ~decisions:lane_decisions ~traces:(traces_by_kind kind)
             ~sessions:lane_sessions ~mixed_runtime_sources)
  in
  let timeline =
    let projected_events =
      match
        projected_refresh_event
          (slice_by_kind Projected classify_operation operations)
          (slice_by_kind Projected (classify_detachment operation_kinds) detachments)
      with
      | Some event -> [ event ]
      | None -> []
    in
    let lane_events =
      lanes
      |> List.sort (fun (left : lane) (right : lane) ->
             Int.compare
               (lane_kind_order
                  (match left.lane_id with
                  | "managed" -> Managed
                  | "supervised" -> Supervised
                  | _ -> Projected))
               (lane_kind_order
                  (match right.lane_id with
                  | "managed" -> Managed
                  | "supervised" -> Supervised
                  | _ -> Projected)))
      |> List.concat_map (fun (lane : lane) ->
             let kind =
               match lane.lane_id with
               | "managed" -> Managed
               | "supervised" -> Supervised
               | _ -> Projected
             in
             lane_timeline_events kind
               (traces_by_kind kind)
               (if kind = Supervised then sessions else [])
               (decisions_by_kind kind))
    in
    (projected_events @ lane_events)
    |> List.filter_map (fun (event : timeline_event) ->
           match Command_plane_v2.parse_iso_timestamp event.timestamp with
           | Some ts -> Some (ts, event)
           | None -> None)
    |> List.sort (fun (left, _) (right, _) -> Float.compare right left)
    |> List.filteri (fun idx _ -> idx < timeline_limit_override)
    |> List.map snd
  in
  let gap_groups =
    let grouped = Hashtbl.create 16 in
    List.iter
      (fun (lane : lane) ->
        List.iter
          (fun (flag : flag) ->
            let key = flag.code in
            let existing =
              match Hashtbl.find_opt grouped key with
              | Some value -> value
              | None -> (flag, [])
            in
            let group_flag, lane_ids = existing in
            Hashtbl.replace grouped key (group_flag, lane.lane_id :: lane_ids))
          lane.hard_flags)
      lanes;
    grouped
    |> Hashtbl.to_seq
    |> List.of_seq
    |> List.map (fun (_, (flag, lane_ids)) ->
           let lane_ids = lane_ids |> List.rev |> List.sort_uniq String.compare in
           `Assoc
             [
               ("code", `String flag.code);
               ("severity", `String flag.severity);
               ("summary", `String flag.summary);
               ("lane_ids", `List (List.map (fun lane_id -> `String lane_id) lane_ids));
               ("count", `Int (List.length lane_ids));
             ])
    |> List.sort (fun left right ->
           let left_severity = left |> U.member "severity" |> U.to_string in
           let right_severity = right |> U.member "severity" |> U.to_string in
           Int.compare (severity_sort left_severity) (severity_sort right_severity))
  in
  let present_lanes = List.filter (fun (lane : lane) -> lane.present) lanes in
  let moving_lanes =
    List.length
      (List.filter (fun (lane : lane) -> String.equal lane.motion_state "moving") lanes)
  in
  let stalled_lanes =
    List.length
      (List.filter (fun (lane : lane) -> String.equal lane.motion_state "stalled") lanes)
  in
  let projected_lanes =
    List.length
      (List.filter (fun (lane : lane) -> String.equal lane.kind "projected" && lane.present) lanes)
  in
  let last_movement_at =
    lanes
    |> List.filter_map (fun (lane : lane) ->
           match lane.last_movement_at with
           | Some timestamp -> (
               match Command_plane_v2.parse_iso_timestamp timestamp with
               | Some ts -> Some (ts, timestamp)
               | None -> None)
           | None -> None)
    |> List.sort (fun (left, _) (right, _) -> Float.compare right left)
    |> function
    | (_, timestamp) :: _ -> Some timestamp
    | [] -> None
  in
  let recommendation = choose_recommendation lanes in
  `Assoc
    [
      ("generated_at", `String (Types.now_iso ()));
      ( "overview",
        `Assoc
          [
            ("active_lanes", `Int (List.length present_lanes));
            ("moving_lanes", `Int moving_lanes);
            ("stalled_lanes", `Int stalled_lanes);
            ("projected_lanes", `Int projected_lanes);
            ("last_movement_at", string_option_to_json last_movement_at);
          ] );
      ("lanes", `List (List.map lane_to_json lanes));
      ("timeline", `List (List.map timeline_event_to_json timeline));
      ( "gaps",
        `Assoc
          [
            ("count", `Int (List.length gap_groups));
            ("items", `List gap_groups);
          ] );
      ("recommended_next_action", recommendation_to_json recommendation);
    ]

let build_json_from_snapshot ?(timeline_limit_override = timeline_limit)
    (config : Room_utils.config) snapshot =
  build_json_from_inputs
    ~timeline_limit_override
    ~now:(Time_compat.now ())
    ~operations:(operation_infos_of_snapshot snapshot)
    ~detachments:(detachment_infos_of_snapshot snapshot)
    ~alerts:(alert_infos_of_snapshot snapshot)
    ~decisions:(decision_infos_of_snapshot snapshot)
    ~traces:(trace_infos_of_snapshot snapshot)
    ~sessions:(read_session_infos config)

let build_json ?(timeline_limit_override = timeline_limit)
    (config : Room_utils.config) =
  build_json_from_inputs
    ~timeline_limit_override
    ~now:(Time_compat.now ())
    ~operations:(read_operation_infos config)
    ~detachments:(read_detachment_infos config)
    ~alerts:(read_alert_infos config)
    ~decisions:(read_decision_infos config)
    ~traces:(read_trace_infos ~limit:timeline_limit_override config)
    ~sessions:(read_session_infos config)

let empty_json =
  let lane kind =
    {
      lane_id = lane_id kind;
      label = lane_label kind;
      kind = lane_kind_string kind;
      present = false;
      phase = "forming";
      motion_state = "waiting";
      source_of_truth = source_of_truth kind;
      last_movement_at = None;
      movement_reason = "no_active_data";
      current_step = lane_current_step kind ~present:false ~phase:"forming"
          ~motion_state:"waiting" ~approvals:0 ~detachments:0 ~workers:0;
      blockers = [];
      operations = 0;
      detachments = 0;
      workers = 0;
      approvals = 0;
      alerts = 0;
      hard_flags = [];
    }
  in
  `Assoc
    [
      ("generated_at", `String (Types.now_iso ()));
      ( "overview",
        `Assoc
          [
            ("active_lanes", `Int 0);
            ("moving_lanes", `Int 0);
            ("stalled_lanes", `Int 0);
            ("projected_lanes", `Int 0);
            ("last_movement_at", `Null);
          ] );
      ("lanes", `List (List.map lane_to_json [ lane Managed; lane Supervised; lane Projected ]));
      ("timeline", `List []);
      ("gaps", `Assoc [ ("count", `Int 0); ("items", `List []) ]);
      ( "recommended_next_action",
        recommendation_to_json
          {
            tool = "masc_operator_snapshot";
            label = "Read operator state";
            reason = "No active swarm lane is visible yet.";
            lane_id = None;
          } );
    ]
