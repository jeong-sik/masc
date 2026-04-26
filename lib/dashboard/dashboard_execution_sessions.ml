(** Dashboard_execution_sessions — Session seed building, session context
    assembly, execution queue, and worker/continuity brief construction.

    Extracted from dashboard_execution_builders to reduce file size. *)

include Dashboard_execution_helpers

let session_payload_json session_json =
  match member_assoc "status" session_json with
  | `Assoc _ as payload -> payload
  | _ -> session_json
;;

let session_meta_json session_json =
  session_payload_json session_json |> member_assoc "session"
;;

let session_summary_json session_json =
  session_payload_json session_json |> member_assoc "summary"
;;

let session_team_health_json session_json =
  session_payload_json session_json |> member_assoc "team_health"
;;

let session_communication_json session_json =
  session_payload_json session_json |> member_assoc "communication_metrics"
;;

let session_status_string session_json =
  let summary = session_summary_json session_json in
  let meta = session_meta_json session_json in
  match trim_to_option (string_field "status" summary) with
  | Some value -> value
  | None ->
    (match trim_to_option (string_field "status" meta) with
     | Some value -> value
     | None ->
       trim_to_option (string_field "status" session_json)
       |> Option.value ~default:"unknown")
;;

let session_recent_events session_json = list_field "recent_events" session_json
let event_detail_json event_json = member_assoc "detail" event_json

let event_summary event_json =
  let detail = event_detail_json event_json in
  let event_type =
    trim_to_option (string_field "event_type" event_json) |> Option.value ~default:"event"
  in
  let actor =
    match trim_to_option (string_field "actor" detail) with
    | Some value -> Some value
    | None -> trim_to_option (string_field "agent" detail)
  in
  let task_title =
    match trim_to_option (string_field "task_title" detail) with
    | Some value -> Some value
    | None -> trim_to_option (string_field "title" detail)
  in
  let result = trim_to_option (compact_text (string_field "result" detail)) in
  let reason = trim_to_option (compact_text (string_field "reason" detail)) in
  let output_preview =
    trim_to_option (compact_text (string_field "output_preview" detail))
  in
  match task_title, result, reason, output_preview with
  | Some title, _, _, _ ->
    compact_text
      (Printf.sprintf
         "%s%s"
         (match actor with
          | Some value -> value ^ " · "
          | None -> "")
         title)
  | None, Some value, _, _ -> value
  | None, None, Some value, _ -> value
  | None, None, None, Some value -> value
  | None, None, None, None ->
    String.map (fun ch -> if ch = '_' then ' ' else ch) event_type
;;

let session_severity
      ~(health : Dashboard_utils.health_level)
      ~(status : Dashboard_utils.session_lifecycle)
      ~runtime_blocker
  =
  if status = SL_completed
  then
    if is_health_critical health || is_health_warning health then Tone_warn else Tone_ok
  else if is_health_critical health || is_session_blocked status
  then Tone_bad
  else if is_health_warning health || status = SL_paused || Option.is_some runtime_blocker
  then Tone_warn
  else Tone_ok
;;

let build_session_seed session_json _cards =
  let session_id = string_field "session_id" session_json in
  if session_id = ""
  then None
  else (
    let meta = session_meta_json session_json in
    let summary = session_summary_json session_json in
    let team_health = session_team_health_json session_json in
    let communication = session_communication_json session_json in
    let recent_events = session_recent_events session_json in
    let last_event =
      recent_events
      |> List.sort (fun left right ->
        let right_ts =
          parse_iso_opt (trim_to_option (string_field "ts_iso" right))
          |> Option.value ~default:0.0
        in
        let left_ts =
          parse_iso_opt (trim_to_option (string_field "ts_iso" left))
          |> Option.value ~default:0.0
        in
        Float.compare right_ts left_ts)
      |> function
      | item :: _ -> Some item
      | [] -> None
    in
    let session_card = None in
    let top_attention =
      match session_card with
      | Some card ->
        (match member_assoc "top_attention" card with
         | `Null -> None
         | value -> Some value)
      | None -> None
    in
    let top_recommendation =
      match session_card with
      | Some card ->
        (match member_assoc "top_recommendation" card with
         | `Null -> None
         | value -> Some value)
      | None -> None
    in
    let attention_summary =
      Option.bind top_attention (fun json -> trim_to_option (string_field "summary" json))
    in
    let attention_kind =
      Option.bind top_attention (fun json -> trim_to_option (string_field "kind" json))
    in
    let runtime_blocker =
      match attention_kind, attention_summary with
      | ( Some
            ( "spawn_failure_present"
            | "local64_role_gap"
            | "stalled_session"
            | "planned_worker_without_turn" )
        , Some summary ) -> Some summary
      | _ -> attention_summary
    in
    let worker_gap_summary =
      match attention_kind, attention_summary with
      | ( Some
            ( "spawn_failure_present"
            | "local64_role_gap"
            | "planned_worker_without_turn"
            | "detached_actor_present" )
        , Some summary ) -> Some summary
      | _ -> None
    in
    let mode =
      trim_to_option (string_field "mode" communication)
      |> Option.value ~default:"mode n/a"
    in
    let broadcast_count = int_field "broadcast_count" communication in
    let portal_count = int_field "portal_count" communication in
    let seen_count = int_field "seen_agents_count" summary in
    let member_names =
      dedup_strings
        (string_list_of_json (member_assoc "agent_names" meta)
         @ string_list_of_json (member_assoc "active_agents" summary)
         @ string_list_of_json (member_assoc "planned_participants" summary))
    in
    let planned_count =
      let planned = string_list_of_json (member_assoc "planned_participants" summary) in
      let explicit = List.length planned in
      if explicit > 0 then explicit else List.length member_names
    in
    let counts_basis =
      if string_list_of_json (member_assoc "planned_participants" summary) <> []
      then "live=recent_turns · planned=planned_participants"
      else "live=recent_turns · planned=known_members"
    in
    Some
      { session_id
      ; goal =
          trim_to_option (string_field "goal" meta) |> Option.value ~default:session_id
      ; namespace =
          (match trim_to_option (string_field "project" meta) with
           | Some _ as value -> value
           | None -> trim_to_option (string_field "room_id" meta))
      ; status = session_status_string session_json
      ; health =
          (match session_card with
           | Some card ->
             trim_to_option (string_field "health" card) |> Option.value ~default:"ok"
           | None ->
             trim_to_option (string_field "status" team_health)
             |> Option.value ~default:"ok")
      ; member_names
      ; last_activity_at =
          Option.bind last_event (fun json -> trim_to_option (string_field "ts_iso" json))
      ; last_activity_ts =
          Option.bind last_event (fun json ->
            parse_iso_opt (trim_to_option (string_field "ts_iso" json)))
          |> Option.value ~default:0.0
      ; last_activity_summary =
          (match last_event with
           | Some value -> event_summary value
           | None -> "최근 session event가 없습니다.")
      ; communication_summary =
          Printf.sprintf "%s · broadcast %d · portal %d" mode broadcast_count portal_count
      ; active_count = int_field "active_agents_count" team_health
      ; seen_count
      ; planned_count
      ; required_count = int_field ~default:1 "required_agents" team_health
      ; counts_basis
      ; runtime_blocker
      ; worker_gap_summary
      ; top_attention
      ; top_recommendation
      })
;;

let session_operation_links operation_contexts =
  let table = Hashtbl.create 32 in
  List.iter
    (fun (operation : operation_context) ->
       match operation.linked_session_id with
       | Some session_id when not (Hashtbl.mem table session_id) ->
         Hashtbl.add
           table
           session_id
           (Some operation.operation_id, operation.linked_detachment_id)
       | Some _ | None -> ())
    operation_contexts;
  table
;;

let build_session_contexts seeds operation_contexts : session_context list =
  let links = session_operation_links operation_contexts in
  seeds
  |> List.map (fun (seed : session_seed) : session_context ->
    let linked_operation_id, linked_detachment_id =
      match Hashtbl.find_opt links seed.session_id with
      | Some value -> value
      | None -> None, None
    in
    let severity =
      session_severity
        ~health:(Dashboard_utils.health_level_of_string seed.health)
        ~status:(Dashboard_utils.session_lifecycle_of_string seed.status)
        ~runtime_blocker:seed.runtime_blocker
    in
    let intervene_label =
      match seed.status with
      | "completed" -> "세션 결과 보기"
      | "interrupted" -> "중단 원인 보기"
      | "failed" | "cancelled" -> "실패 원인 보기"
      | _ -> "세션 개입 열기"
    in
    let intervene_handoff =
      handoff_json
        ~surface:"intervene"
        ~label:intervene_label
        ~target_type:"operation"
        ~target_id:seed.session_id
        ~focus_kind:"operation"
        ()
    in
    let command_handoff =
      handoff_json
        ~surface:"command"
        ~command_surface:
          (if Option.is_some linked_operation_id then "operations" else "swarm")
        ?operation_id:linked_operation_id
        ~label:"세션 원인 보기"
        ~target_type:"operation"
        ~target_id:seed.session_id
        ~focus_kind:"operation"
        ()
    in
    let top_handoff =
      match seed.top_recommendation with
      | Some _ -> intervene_handoff
      | None ->
        if severity <> Tone_ok && Option.is_some linked_operation_id
        then command_handoff
        else intervene_handoff
    in
    { session_id = seed.session_id
    ; severity
    ; last_seen_ts = seed.last_activity_ts
    ; linked_operation_id
    ; member_names = seed.member_names
    ; json =
        `Assoc
          [ "session_id", `String seed.session_id
          ; "goal", `String seed.goal
          ; "namespace", json_string_option seed.namespace
          ; (* Legacy room alias now mirrors the flattened namespace. *)
            "room", json_string_option seed.namespace
          ; "status", `String seed.status
          ; "health", `String seed.health
          ; ( "member_names"
            , `List (List.map (fun value -> `String value) seed.member_names) )
          ; "linked_operation_id", json_string_option linked_operation_id
          ; "linked_detachment_id", json_string_option linked_detachment_id
          ; "runtime_blocker", json_string_option seed.runtime_blocker
          ; "worker_gap_summary", json_string_option seed.worker_gap_summary
          ; "last_activity_at", json_string_option seed.last_activity_at
          ; "last_activity_summary", `String seed.last_activity_summary
          ; "communication_summary", `String seed.communication_summary
          ; "active_count", `Int seed.active_count
          ; "seen_count", `Int seed.seen_count
          ; "planned_count", `Int seed.planned_count
          ; "required_count", `Int seed.required_count
          ; "counts_basis", `String seed.counts_basis
          ; "top_handoff", top_handoff
          ; "intervene_handoff", intervene_handoff
          ; "command_handoff", command_handoff
          ; ( "top_attention"
            , match seed.top_attention with
              | Some value -> value
              | None -> `Null )
          ; ( "top_recommendation"
            , match seed.top_recommendation with
              | Some value -> value
              | None -> `Null )
          ]
    })
  |> List.sort (fun (left : session_context) (right : session_context) ->
    let by_severity = Int.compare (tone_rank right.severity) (tone_rank left.severity) in
    if by_severity <> 0
    then by_severity
    else Float.compare right.last_seen_ts left.last_seen_ts)
;;

let queue_summary_of_session (session_context : session_context) =
  match trim_to_option (string_field "runtime_blocker" session_context.json) with
  | Some summary -> summary
  | None ->
    (match trim_to_option (string_field "worker_gap_summary" session_context.json) with
     | Some summary -> summary
     | None ->
       trim_to_option (string_field "last_activity_summary" session_context.json)
       |> Option.value ~default:(string_field "goal" session_context.json))
;;

let build_execution_queue session_contexts operation_contexts =
  let blocked_session_ids =
    session_contexts
    |> List.filter (fun (session : session_context) -> session.severity <> Tone_ok)
    |> List.map (fun (session : session_context) -> session.session_id)
  in
  let session_items =
    session_contexts
    |> List.filter (fun (session : session_context) -> session.severity <> Tone_ok)
    |> List.map (fun (session : session_context) ->
      { severity_rank = tone_rank session.severity
      ; last_seen_ts = session.last_seen_ts
      ; json =
          `Assoc
            [ "id", `String ("session-" ^ session.session_id)
            ; "kind", `String "session"
            ; "severity", `String (string_of_tone session.severity)
            ; "status", member_assoc "status" session.json
            ; "summary", `String (queue_summary_of_session session)
            ; "target_type", `String "operation"
            ; "target_id", `String session.session_id
            ; "linked_session_id", `String session.session_id
            ; ( "linked_operation_id"
              , option_to_json (fun value -> `String value) session.linked_operation_id )
            ; "last_seen_at", member_assoc "last_activity_at" session.json
            ; "top_handoff", member_assoc "top_handoff" session.json
            ; "intervene_handoff", member_assoc "intervene_handoff" session.json
            ; "command_handoff", member_assoc "command_handoff" session.json
            ]
      })
  in
  let operation_items =
    operation_contexts
    |> List.filter (fun (operation : operation_context) ->
      operation.severity <> Tone_ok
      &&
      match operation.linked_session_id with
      | Some session_id -> not (List.mem session_id blocked_session_ids)
      | None -> true)
    |> List.map (fun (operation : operation_context) ->
      { severity_rank = tone_rank operation.severity
      ; last_seen_ts = operation.last_seen_ts
      ; json =
          `Assoc
            [ "id", `String ("operation-" ^ operation.operation_id)
            ; "kind", `String "operation"
            ; "severity", `String (string_of_tone operation.severity)
            ; "status", member_assoc "status" operation.json
            ; ( "summary"
              , match trim_to_option (string_field "blocker_summary" operation.json) with
                | Some summary -> `String summary
                | None -> member_assoc "objective" operation.json )
            ; "target_type", `String "operation"
            ; "target_id", `String operation.operation_id
            ; "linked_session_id", json_string_option operation.linked_session_id
            ; "linked_operation_id", `String operation.operation_id
            ; "last_seen_at", member_assoc "updated_at" operation.json
            ; "top_handoff", member_assoc "top_handoff" operation.json
            ; "intervene_handoff", `Null
            ; "command_handoff", member_assoc "command_handoff" operation.json
            ]
      })
  in
  session_items @ operation_items
  |> List.sort (fun left right ->
    let by_severity = Int.compare right.severity_rank left.severity_rank in
    if by_severity <> 0
    then by_severity
    else Float.compare right.last_seen_ts left.last_seen_ts)
;;

let related_session_for_member session_contexts name =
  let normalized = String.lowercase_ascii (String.trim name) in
  session_contexts
  |> List.find_opt (fun (session : session_context) ->
    session.member_names
    |> List.exists (fun member ->
      String.equal (String.lowercase_ascii (String.trim member)) normalized))
;;
