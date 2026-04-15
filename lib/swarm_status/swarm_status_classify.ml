
open Swarm_status_types
open Swarm_status_json

let operation_active (operation : operation_info) =
  match operation.status with
  | SOp_completed | SOp_cancelled | SOp_failed -> false
  | SOp_active | SOp_planned | SOp_paused -> true

let operation_terminal (operation : operation_info) = not (operation_active operation)

let detachment_active (detachment : detachment_info) =
  match detachment.status with
  | SDet_completed | SDet_cancelled | SDet_failed | SDet_stopped -> false
  | SDet_active | SDet_awaiting_approval | SDet_stalled -> true

let decision_pending (decision : decision_info) =
  decision.status = SDec_pending

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
    | Some "supervised" -> Supervised
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
        | Some "supervised" -> Supervised
        | _ -> Managed)

let classify_trace operations_by_id (trace : trace_info) =
  if String.equal trace.source "supervised" || String.equal trace.source "operator" then
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
  | Flag_bad -> 0
  | Flag_warn -> 1

(** String-based severity sort for gap_groups in build.ml where severity
    comes from JSON extraction, not from the typed [flag.severity] field. *)
let severity_sort_string = function
  | "bad" -> 0
  | "warn" -> 1
  | _ -> 2

let compare_flag (left : flag) (right : flag) =
  let by_severity =
    Int.compare (severity_sort left.severity) (severity_sort right.severity)
  in
  if by_severity <> 0 then by_severity
  else
    Int.compare
      (Swarm_status_json.flag_code_order left.code)
      (Swarm_status_json.flag_code_order right.code)

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
    |> List.filter (fun (decision : decision_info) -> decision.status = SDec_pending)
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
    Waiting
  else if phase = Lane_completed then
    Terminal
  else
    match parse_timestamp last_movement_at with
    | Some ts when now -. ts <= moving_window_sec -> Moving
    | Some ts when now -. ts <= stale_window_sec ->
        if approvals > 0 then Waiting else Waiting
    | Some _ -> Stalled
    | None ->
        if approvals > 0 then Waiting else Stalled

let lane_phase ~present ~active_operations ~detachments ~workers ~approvals ~motion_state ~terminal =
  if not present then
    Forming
  else if terminal && approvals = 0 then
    Lane_completed
  else if approvals > 0 then
    Awaiting_approval
  else if active_operations > 0 && detachments = 0 then
    Dispatching
  else if motion_state = Stalled then
    Blocked
  else if detachments > 0 || workers > 0 then
    Executing
  else
    Forming

let lane_current_step kind ~present ~(phase : lane_phase) ~(motion_state : lane_motion)
    ~approvals ~detachments ~workers =
  match kind with
  | Managed ->
      if not present then "Start a managed operation"
      else if approvals > 0 then "Resolve pending policy approval"
      else if phase = Dispatching then "Materialize detachments with dispatch tick"
      else if motion_state = Stalled then "Inspect traces or run dispatch tick"
      else if detachments > 0 then "Observe active detachments"
      else "Track managed execution"
  | Projected ->
      if not present then "No projected swarm is active"
      else if approvals > 0 then "Resolve manual approval before converting projection"
      else "Convert projection into managed runtime"
  | Supervised ->
      if not present then "No supervised execution session is active"
      else if approvals > 0 then "Confirm the pending operator action"
      else if workers = 0 then "Bind runtime workers to the session"
      else if motion_state = Stalled then "Inspect session status and recent events"
      else "Observe session progress"

let lane_blockers kind ~(phase : lane_phase) ~(motion_state : lane_motion)
    ~approvals ~workers ~flags =
  let base = [] in
  let base =
    if approvals > 0 then
      "Manual approval is still blocking this lane." :: base
    else base
  in
  let base =
    if motion_state = Stalled then
      "No recent progress is visible inside the freshness window." :: base
    else base
  in
  let base =
    match kind with
    | Supervised when workers = 0 && phase <> Lane_completed ->
        "No worker binding is visible for the supervised session." :: base
    | Projected when List.exists (fun (flag : flag) -> flag.code = Projected_only) flags ->
        "This lane is projection-only and has no managed runtime backing." :: base
    | _ -> base
  in
  List.rev base

let append_flag flags (code : flag_code) (severity : flag_severity) summary =
  if List.exists (fun (flag : flag) -> flag.code = code) flags then
    flags
  else
    { code; severity; summary } :: flags

let lane_flags kind ~present ~approvals ~workers ~trace_count ~last_movement_at
    ~mixed_runtime_sources =
  let flags = [] in
  let flags =
    match kind with
    | Projected when present ->
        append_flag flags Projected_only Flag_warn
          "Projected state is visible without managed runtime backing."
    | _ -> flags
  in
  let flags =
    if present && trace_count = 0 then
      append_flag flags Missing_trace_events Flag_warn
        "No trace events are attached to this lane."
    else flags
  in
  let flags =
    if present && approvals > 0 then
      append_flag flags Pending_manual_confirmation Flag_warn
        "Manual approval or confirmation is still pending."
    else flags
  in
  let flags =
    match kind with
    | Supervised when present && workers = 0 ->
        append_flag flags Missing_worker_binding Flag_bad
          "The supervised lane has no visible worker binding."
    | _ -> flags
  in
  let flags =
    if present && last_movement_at = None then
      append_flag flags Missing_runtime_progress Flag_warn
        "Runtime progress is missing for this lane."
    else flags
  in
  let flags =
    match parse_timestamp last_movement_at with
    | Some ts when present && Time_compat.now () -. ts > stale_window_sec ->
        append_flag flags Stale_data Flag_warn
          "The most recent movement is older than the freshness window."
    | _ -> flags
  in
  let flags =
    if mixed_runtime_sources then
      append_flag flags Dashboard_source_split Flag_warn
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
                   title = humanize_identifier trace.event_type;
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
             title =
               Printf.sprintf "Session %s" (humanize_identifier session.status);
             detail =
               Printf.sprintf "%s (session %s)"
                 session.goal session.session_id;
             tone =
               if String.equal session.status "running" then "ok" else "warn";
             source = "supervised";
           })
  in
  let approval_events =
    decisions
    |> List.filter (fun (decision : decision_info) -> decision.status = SDec_pending)
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
                     Option.value ~default:"Pending approval"
                       (Option.map humanize_identifier decision.requested_action);
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
           match parse_iso_timestamp timestamp with
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
