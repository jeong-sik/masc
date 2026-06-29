let schedule_projection_request_limit = 20

let unix_iso_json ts = `String (Masc_domain.iso8601_of_unix_seconds ts)

let unix_iso_option_json = function
  | None -> `Null
  | Some ts -> unix_iso_json ts
;;

let schedule_status_count schedules status =
  List.fold_left
    (fun count (request : Schedule_domain.schedule_request) ->
      if request.status = status then count + 1 else count)
    0 schedules
;;

let schedule_counts_json schedules =
  `Assoc
    (List.map
       (fun status ->
         ( Schedule_domain.schedule_status_to_string status
         , `Int (schedule_status_count schedules status) ))
       Schedule_domain.all_schedule_statuses)
;;

let schedule_supported_payload_kinds =
  List.sort_uniq String.compare Server_schedule_consumers.supported_payload_kinds
;;

let schedule_payload_kind_supported kind =
  List.exists (String.equal kind) schedule_supported_payload_kinds
;;

let schedule_payload_support_status (request : Schedule_domain.schedule_request) =
  match Schedule_payload_projection.kind request with
  | Some kind when schedule_payload_kind_supported kind -> "supported"
  | Some _ -> "unsupported"
  | None -> "unknown"
;;

let schedule_payload_support_json schedules =
  let bump kind counts =
    let rec loop acc = function
      | [] -> List.rev ((kind, 1) :: acc)
      | (existing, count) :: rest when String.equal existing kind ->
        List.rev_append acc ((existing, count + 1) :: rest)
      | item :: rest -> loop (item :: acc) rest
    in
    loop [] counts
  in
  let unsupported_request_count, unknown_request_count, unsupported_kinds =
    List.fold_left
      (fun (unsupported_count, unknown_count, kind_counts)
        (request : Schedule_domain.schedule_request) ->
         match Schedule_payload_projection.kind request with
         | Some kind when schedule_payload_kind_supported kind ->
           unsupported_count, unknown_count, kind_counts
         | Some kind -> unsupported_count + 1, unknown_count, bump kind kind_counts
         | None -> unsupported_count, unknown_count + 1, kind_counts)
      (0, 0, []) schedules
  in
  let unsupported_kinds =
    unsupported_kinds
    |> List.sort (fun (left_kind, left_count) (right_kind, right_count) ->
      match compare right_count left_count with
      | 0 -> String.compare left_kind right_kind
      | order -> order)
    |> List.map (fun (kind, count) ->
      `Assoc [ "kind", `String kind; "count", `Int count ])
  in
  `Assoc
    [ ( "supported_kinds"
      , `List (List.map (fun kind -> `String kind) schedule_supported_payload_kinds) )
    ; "unsupported_request_count", `Int unsupported_request_count
    ; "unsupported_kinds", `List unsupported_kinds
    ; "unknown_request_count", `Int unknown_request_count
    ]
;;

let schedule_request_active (request : Schedule_domain.schedule_request) =
  not (Schedule_domain.is_terminal request.status)
;;

let schedule_effectively_expired ~now (request : Schedule_domain.schedule_request) =
  match request.status, request.expires_at with
  | (Schedule_domain.Pending_approval | Schedule_domain.Scheduled | Schedule_domain.Due), Some expires_at
    when expires_at <= now -> true
  | _ -> false
;;

let schedule_request_effectively_active ~now request =
  schedule_request_active request && not (schedule_effectively_expired ~now request)
;;

let schedule_effectively_due ~now (request : Schedule_domain.schedule_request) =
  (not (schedule_effectively_expired ~now request))
  &&
  match request.status with
  | Schedule_domain.Due -> true
  | Schedule_domain.Scheduled -> request.due_at <= now
  | Schedule_domain.Pending_approval
  | Schedule_domain.Running
  | Schedule_domain.Succeeded
  | Schedule_domain.Failed
  | Schedule_domain.Rejected
  | Schedule_domain.Cancelled
  | Schedule_domain.Expired ->
    false
;;

let schedule_due_candidate (request : Schedule_domain.schedule_request) =
  match request.status with
  | Schedule_domain.Pending_approval | Schedule_domain.Scheduled | Schedule_domain.Due ->
    true
  | Schedule_domain.Running
  | Schedule_domain.Succeeded
  | Schedule_domain.Failed
  | Schedule_domain.Rejected
  | Schedule_domain.Cancelled
  | Schedule_domain.Expired ->
    false
;;

let schedule_next_due_at ~now schedules =
  schedules
  |> List.filter (fun request ->
    schedule_due_candidate request && not (schedule_effectively_expired ~now request))
  |> List.fold_left
       (fun acc (request : Schedule_domain.schedule_request) ->
         match acc with
         | None -> Some request.due_at
         | Some ts -> Some (min ts request.due_at))
       None
;;

let schedule_blocked_approval ~now state (request : Schedule_domain.schedule_request) =
  (not (schedule_effectively_expired ~now request))
  && request.due_at <= now
  && Schedule_domain.requires_separate_human_grant request
  &&
  match request.status with
  | Schedule_domain.Pending_approval -> true
  | Schedule_domain.Due -> not (Schedule_store.has_current_approved_grant state request)
  | Schedule_domain.Scheduled
  | Schedule_domain.Running
  | Schedule_domain.Succeeded
  | Schedule_domain.Failed
  | Schedule_domain.Rejected
  | Schedule_domain.Cancelled
  | Schedule_domain.Expired ->
    false
;;

let schedule_effective_status ~now state (request : Schedule_domain.schedule_request) =
  if schedule_effectively_expired ~now request
  then "expired"
  else
    match request.status with
    | Schedule_domain.Pending_approval when request.due_at <= now -> "blocked_approval"
    | Pending_approval -> "pending_approval"
    | Scheduled when request.due_at <= now -> "due"
    | Scheduled -> "scheduled"
    | Due when schedule_blocked_approval ~now state request -> "blocked_approval"
    | Due -> "ready"
    | Running -> "running"
    | Succeeded -> "succeeded"
    | Failed -> "failed"
    | Rejected -> "rejected"
    | Cancelled -> "cancelled"
    | Expired -> "expired"
;;

let schedule_execution_readiness ~now state (request : Schedule_domain.schedule_request) =
  if schedule_effectively_expired ~now request
  then Schedule_projection.Expired
  else if Schedule_domain.is_terminal request.status
  then Schedule_projection.Terminal
  else if request.status = Schedule_domain.Running
  then Schedule_projection.Running
  else if schedule_blocked_approval ~now state request
  then Schedule_projection.Blocked_approval
  else if Schedule_store.has_current_approved_grant state request
  then Schedule_projection.Approved
  else
    match request.status with
    | Schedule_domain.Pending_approval -> Schedule_projection.Awaiting_approval
    | Schedule_domain.Scheduled when request.due_at <= now ->
      Schedule_projection.Due_pending_refresh
    | Schedule_domain.Scheduled -> Schedule_projection.Scheduled
    | Schedule_domain.Due -> Schedule_projection.Ready
    | Schedule_domain.Running -> Schedule_projection.Running
    | Schedule_domain.Succeeded
    | Schedule_domain.Failed
    | Schedule_domain.Rejected
    | Schedule_domain.Cancelled
    | Schedule_domain.Expired ->
      Schedule_projection.Terminal
;;

let schedule_operator_action readiness =
  match Schedule_projection.operator_action_for_execution_readiness readiness with
  | Some action -> `String action
  | None -> `Null
;;

let tool_projection_surfaces_for tool_name =
  let surfaces = ref [] in
  let add_surface surface =
    if not (List.exists (String.equal surface) !surfaces)
    then surfaces := surface :: !surfaces
  in
  if Tool_catalog.is_public_mcp tool_name then add_surface "public_mcp";
  Capability_registry.all_projection_seeds_from Config.raw_all_tool_schemas
  |> List.iter (fun (seed : Capability_registry.capability_seed) ->
    let surface = Capability_registry.surface_to_string seed.projection.surface in
    if
      (not (String.equal surface "public_mcp"))
      && (String.equal seed.projection.tool_name tool_name
          || String.equal seed.projection.backend_tool_name tool_name)
    then add_surface surface);
  List.sort String.compare !surfaces
;;

let schedule_keeper_next_tool_status_json = function
  | None -> `Null
  | Some tool_name ->
    let registered_schema =
      List.exists
        (fun (schema : Masc_domain.tool_schema) -> String.equal schema.name tool_name)
        Config.raw_all_tool_schemas
    in
    let dispatch_registered = Option.is_some (Tool_dispatch.lookup_tag tool_name) in
    let metadata = Tool_catalog.metadata tool_name in
    let surfaces = tool_projection_surfaces_for tool_name in
    let effect_domain =
      match metadata.effect_domain with
      | None -> `Null
      | Some domain -> `String (Tool_catalog.effect_domain_to_string domain)
    in
    `Assoc
      [ "name", `String tool_name
      ; "registered_schema", `Bool registered_schema
      ; "dispatch_registered", `Bool dispatch_registered
      ; "direct_call_allowed", `Bool (Tool_catalog.allow_direct_call tool_name)
      ; "visibility", `String (Tool_catalog.visibility_to_string metadata.visibility)
      ; ( "surfaces"
        , `List (List.map (fun surface -> `String surface) surfaces) )
      ; "surface_count", `Int (List.length surfaces)
      ; "effect_domain", effect_domain
      ; ( "read_only"
        , match metadata.readonly with
          | None -> `Null
          | Some read_only -> `Bool read_only )
      ; ( "requires_actor_binding"
        , match metadata.requires_actor_binding with
          | None -> `Null
          | Some requires_actor_binding -> `Bool requires_actor_binding )
      ]
;;

let schedule_keeper_next_action readiness =
  match Schedule_projection.keeper_next_action_for_execution_readiness readiness with
  | Some action -> `String action
  | None -> `Null
;;

let schedule_fsm_state ~now state schedules =
  let count status = schedule_status_count schedules status in
  let count_non_expired status =
    List.fold_left
      (fun count (request : Schedule_domain.schedule_request) ->
         if request.status = status && not (schedule_effectively_expired ~now request)
         then count + 1
         else count)
      0 schedules
  in
  let due_effective_count =
    List.fold_left
      (fun count request -> if schedule_effectively_due ~now request then count + 1 else count)
      0 schedules
  in
  let blocked_approval_count =
    List.fold_left
      (fun count request ->
         if schedule_blocked_approval ~now state request then count + 1 else count)
      0 schedules
  in
  if count Schedule_domain.Running > 0
  then "running"
  else if blocked_approval_count > 0
  then "blocked_approval"
  else if due_effective_count > 0
  then "due"
  else if count_non_expired Schedule_domain.Pending_approval > 0
  then "pending_approval"
  else if count_non_expired Schedule_domain.Scheduled > 0
  then "scheduled"
  else if
    List.exists (fun request -> schedule_effectively_expired ~now request) schedules
  then "expired"
  else "idle"
;;

let execution_record_dashboard_json (execution : Schedule_domain.execution_record) =
  match Schedule_domain.execution_record_to_yojson execution with
  | `Assoc fields ->
    `Assoc
      (fields
       @ [ "started_at_iso", unix_iso_json execution.started_at
         ; "finished_at_iso", unix_iso_option_json execution.finished_at
         ])
  | other -> other
;;

let schedule_signal_projection_limit = 20

let schedule_signal_payload_kind_json (signal : Schedule_runner.wake_signal) =
  match signal.payload with
  | `Assoc fields ->
    (match List.assoc_opt "kind" fields with
     | Some (`String kind) -> `String kind
     | _ -> `Null)
  | _ -> `Null
;;

let schedule_signal_dashboard_json (signal : Schedule_runner.wake_signal) =
  let kind = Schedule_runner.signal_kind_to_string signal.kind in
  `Assoc
    [ "signal_id", `String signal.signal_id
    ; "kind", `String kind
    ; "event_type", `String kind
    ; "schedule_id", `String signal.schedule_id
    ; "emitted_at", `Float signal.emitted_at
    ; "emitted_at_iso", unix_iso_json signal.emitted_at
    ; "due_at", `Float signal.due_at
    ; "due_at_iso", unix_iso_json signal.due_at
    ; "risk_class", `String (Schedule_domain.risk_class_to_string signal.risk_class)
    ; "payload_digest", `String signal.payload_digest
    ; "payload_kind", schedule_signal_payload_kind_json signal
    ]
;;

let schedule_request_dashboard_json
  ~now
  ~state
  ?last_execution
  (request : Schedule_domain.schedule_request)
  =
  let next_due_at =
    if Schedule_domain.is_terminal request.status then None else Some request.due_at
  in
  let requires_grant = Schedule_domain.requires_separate_human_grant request in
  let payload_target, payload_summary =
    Schedule_payload_projection.target_summary request
  in
  let execution_readiness = schedule_execution_readiness ~now state request in
  let keeper_next_tool =
    Schedule_projection.keeper_next_tool_for_execution_readiness execution_readiness
  in
  `Assoc
    [ "schedule_id", `String request.schedule_id
    ; "status", `String (Schedule_domain.schedule_status_to_string request.status)
    ; "effective_status", `String (schedule_effective_status ~now state request)
    ; ( "execution_readiness"
      , `String (Schedule_projection.execution_readiness_to_string execution_readiness) )
    ; "operator_action", schedule_operator_action execution_readiness
    ; ( "keeper_next_tool"
      , match keeper_next_tool with
        | None -> `Null
        | Some tool -> `String tool )
    ; "keeper_next_tool_status", schedule_keeper_next_tool_status_json keeper_next_tool
    ; "keeper_next_action", schedule_keeper_next_action execution_readiness
    ; "risk_class", `String (Schedule_domain.risk_class_to_string request.risk_class)
    ; "approval_required", `Bool request.approval_required
    ; "source", `String (Schedule_domain.schedule_source_to_string request.source)
    ; "requested_by", Schedule_domain.actor_to_yojson request.requested_by
    ; "scheduled_by", Schedule_domain.actor_to_yojson request.scheduled_by
    ; "requested_at", `Float request.requested_at
    ; "requested_at_iso", unix_iso_json request.requested_at
    ; "due_at", `Float request.due_at
    ; "due_at_iso", unix_iso_json request.due_at
    ; ( "next_due_at"
      , match next_due_at with
        | None -> `Null
        | Some ts -> `Float ts )
    ; "next_due_at_iso", unix_iso_option_json next_due_at
    ; "expires_at", (match request.expires_at with None -> `Null | Some ts -> `Float ts)
    ; "expires_at_iso", unix_iso_option_json request.expires_at
    ; "recurrence", Schedule_domain.recurrence_to_yojson request.recurrence
    ; "recurrence_kind", `String (Schedule_domain.recurrence_kind_to_string request.recurrence)
    ; "recurrence_summary", `String (Schedule_domain.recurrence_summary request.recurrence)
    ; ( "requires_separate_human_grant", `Bool requires_grant )
    ; ( "approval_policy"
      , `String
          (if requires_grant
           then "separate_human_grant_required"
           else "no_separate_grant_required") )
    ; "payload_digest", `String (Schedule_domain.payload_digest request.payload)
    ; ( "payload_kind"
      , match Schedule_payload_projection.kind request with
        | None -> `Null
        | Some kind -> `String kind )
    ; "payload_support", `String (schedule_payload_support_status request)
    ; ( "payload_target"
      , match payload_target with
        | None -> `Null
        | Some target -> `String target )
    ; ( "payload_summary"
      , match payload_summary with
        | None -> `Null
        | Some summary -> `String summary )
    ; ( "last_execution"
      , match last_execution with
        | None -> `Null
        | Some execution -> execution_record_dashboard_json execution )
    ]
;;

let scheduled_automation_dashboard_json (config : Workspace.config) : Yojson.Safe.t =
  (* NDT-OK: dashboard read-model freshness clock; it derives display-only
     effective-due state and never mutates the schedule store or runs work. *)
  let now = Unix.gettimeofday () in
  let state = Schedule_store.read_state config in
  let schedules = state.schedules in
  let active_count =
    List.fold_left
      (fun count request ->
         if schedule_request_effectively_active ~now request then count + 1 else count)
      0 schedules
  in
  let terminal_count = List.length schedules - active_count in
  let expired_effective_count =
    List.fold_left
      (fun count request ->
         if schedule_effectively_expired ~now request then count + 1 else count)
      0 schedules
  in
  let due_effective_count =
    List.fold_left
      (fun count request -> if schedule_effectively_due ~now request then count + 1 else count)
      0 schedules
  in
  let blocked_approval_count =
    List.fold_left
      (fun count request ->
         if schedule_blocked_approval ~now state request then count + 1 else count)
      0 schedules
  in
  let due_execution_ready_count =
    state
    |> Schedule_store.due_execution_candidates
    |> List.filter (fun request -> not (schedule_effectively_expired ~now request))
    |> List.length
  in
  let payload_support = schedule_payload_support_json schedules in
  let unsupported_payload_kind_count, unknown_payload_kind_count =
    match payload_support with
    | `Assoc fields ->
      ( (match List.assoc_opt "unsupported_request_count" fields with
         | Some (`Int count) -> count
         | _ -> 0)
      , (match List.assoc_opt "unknown_request_count" fields with
         | Some (`Int count) -> count
         | _ -> 0) )
    | _ -> 0, 0
  in
  let sorted =
    schedules
    |> List.sort (fun left right ->
      match
        ( schedule_request_active left
        , schedule_request_active right
        , schedule_request_effectively_active ~now left
        , schedule_request_effectively_active ~now right
        , compare left.due_at right.due_at )
      with
      | _, _, true, false, _ -> -1
      | _, _, false, true, _ -> 1
      | true, false, _, _, _ -> -1
      | false, true, _, _, _ -> 1
      | _, _, _, _, due_cmp when due_cmp <> 0 -> due_cmp
      | _ -> String.compare left.schedule_id right.schedule_id)
  in
  let request_rows = Server_dashboard_http_runtime_info_json.take schedule_projection_request_limit sorted in
  let signal_rows =
    Schedule_runner.read_recent_signals config schedule_signal_projection_limit
  in
  `Assoc
    [ "schema", `String "masc.dashboard.scheduled_automation.v1"
    ; "source", `String "schedule_store"
    ; "generated_at", `String (Masc_domain.now_iso ())
    ; "request_count", `Int (List.length schedules)
    ; "request_limit", `Int schedule_projection_request_limit
    ; "truncated", `Bool (List.length schedules > schedule_projection_request_limit)
    ; "signal_source", `String "schedule_runner_signals"
    ; "signal_count", `Int (List.length signal_rows)
    ; "signal_limit", `Int schedule_signal_projection_limit
    ; "signals", `List (List.map schedule_signal_dashboard_json signal_rows)
    ; "counts", schedule_counts_json schedules
    ; ( "derived_counts"
      , `Assoc
          [ "due_effective", `Int due_effective_count
          ; "blocked_approval", `Int blocked_approval_count
          ; "due_execution_ready", `Int due_execution_ready_count
          ; "expired_effective", `Int expired_effective_count
          ; "unsupported_payload_kind", `Int unsupported_payload_kind_count
          ; "unknown_payload_kind", `Int unknown_payload_kind_count
          ] )
    ; "payload_support", payload_support
    ; ( "fsm"
      , `Assoc
          [ "state", `String (schedule_fsm_state ~now state schedules)
          ; "active_count", `Int active_count
          ; "terminal_count", `Int terminal_count
          ; "next_due_at", unix_iso_option_json (schedule_next_due_at ~now schedules)
          ] )
    ; ( "requests"
      , `List
          (List.map
             (fun (request : Schedule_domain.schedule_request) ->
                let last_execution =
                  Schedule_store.last_execution_for_schedule state
                    ~schedule_id:request.Schedule_domain.schedule_id
                in
                schedule_request_dashboard_json ~now ~state ?last_execution request)
             request_rows) )
    ]
;;

