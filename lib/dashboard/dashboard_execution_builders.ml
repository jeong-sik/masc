include Dashboard_execution_helpers

let task_assignee (task : Types.task) =
  match task.task_status with
  | Claimed { assignee; _ } | InProgress { assignee; _ } | Done { assignee; _ } ->
      Some assignee
  | Todo | Cancelled _ -> None

let last_message_map messages =
  let table = Hashtbl.create 32 in
  List.iter
    (fun (message : Types.message) ->
      let key = String.lowercase_ascii (String.trim message.from_agent) in
      let ts = Types.parse_iso8601 message.timestamp in
      match Hashtbl.find_opt table key with
      | Some (existing_ts, _) when existing_ts >= ts -> ()
      | _ -> Hashtbl.replace table key (ts, message))
    messages;
  table

let active_task_count tasks agent_name =
  List.fold_left
    (fun acc (task : Types.task) ->
      match task.task_status, task_assignee task with
      | (Claimed _ | InProgress _), Some assignee when assignee = agent_name -> acc + 1
      | _ -> acc)
    0 tasks

let worker_state_of_agent
    ~(now_ts : float)
    ~(messages_by_agent : (string, float * Types.message) Hashtbl.t)
    ~(tasks : Types.task list)
    ?related_session_id ?related_operation_id
    (agent : Types.agent) : worker_context =
  let key = String.lowercase_ascii (String.trim agent.name) in
  let message_opt = Hashtbl.find_opt messages_by_agent key in
  let last_seen_ts =
    parse_iso_opt (trim_to_option agent.last_seen) |> Option.value ~default:0.0
  in
  let last_message_ts =
    match message_opt with
    | Some (ts, _) -> ts
    | None -> 0.0
  in
  let last_signal_ts = Float.max last_seen_ts last_message_ts in
  let last_signal_at =
    if last_signal_ts <= 0.0 then None
    else if last_message_ts >= last_seen_ts then
      match message_opt with
      | Some (_, message) -> trim_to_option message.timestamp
      | None -> trim_to_option agent.last_seen
    else
      trim_to_option agent.last_seen
  in
  let signal_age_s =
    if last_signal_ts > 0.0 then max 0.0 (now_ts -. last_signal_ts)
    else infinity
  in
  let signal_truth =
    if last_signal_ts <= 0.0 then
      "absent"
    else if signal_age_s <= 300.0 then
      "live"
    else
      "stale"
  in
  let evidence_source =
    if last_message_ts > 0.0 && last_message_ts >= last_seen_ts then
      "message"
    else if last_seen_ts > 0.0 then
      "presence"
    else
      "none"
  in
  let active_task_count = active_task_count tasks agent.name in
  let recent_output_preview =
    match message_opt with
    | Some (_, message) -> trim_to_option (compact_text message.content)
    | None -> None
  in
  let has_work =
    Option.is_some (trim_to_option (Option.value ~default:"" agent.current_task))
    || active_task_count > 0
  in
  let status_string = Types.string_of_agent_status agent.status in
  let (state, tone, note) =
    match agent.status with
    | Types.Inactive ->
        ( "offline",
          "bad",
          if last_signal_ts > 0.0 then "Offline or inactive" else "No recent presence" )
    | Types.Busy | Types.Active | Types.Listening ->
        if signal_age_s > 1200.0 then
          ( "quiet",
            "bad",
            if has_work then "Working without a fresh signal" else "No fresh agent signal" )
        else if has_work then
          if signal_age_s > 600.0 then
            ("quiet", "warn", "Execution looks quiet for too long")
          else
            ("working", "ok", "Task and live signal aligned")
        else if signal_age_s > 600.0 then
          ("quiet", "warn", "Quiet but still reachable")
        else
          ("watching", "ok", "Standing by for the next task")
  in
  let focus =
    match trim_to_option (Option.value ~default:"" agent.current_task) with
    | Some value -> value
    | None ->
        if active_task_count > 0 then
          Printf.sprintf "%d claimed tasks waiting for explicit current_task"
            active_task_count
        else
          Option.value ~default:"Idle / waiting for assignment" recent_output_preview
  in
  let (emoji, korean_name) = get_agent_identity agent.name in
  {
    tone_rank = tone_rank tone;
    last_signal_ts;
    related_session_id;
    json =
      `Assoc
        [
          ("name", `String agent.name);
          ("agent_name", `String agent.name);
          ("status", `String status_string);
          ("tone", `String tone);
          ("state", `String state);
          ("note", `String note);
          ("focus", `String focus);
          ("last_signal_at", json_string_option last_signal_at);
          ("last_signal_age_sec", if Float.is_finite signal_age_s then `Int (int_of_float signal_age_s) else `Null);
          ("signal_truth", `String signal_truth);
          ("evidence_source", `String evidence_source);
          ("active_task_count", `Int active_task_count);
          ("related_session_id", json_string_option related_session_id);
          ("related_operation_id", json_string_option related_operation_id);
          ("emoji", `String emoji);
          ("korean_name", `String korean_name);
          ("model", `Null);
          ("recent_output_preview", json_string_option recent_output_preview);
          ("recent_event", json_string_option recent_output_preview);
        ];
  }

let continuity_row_of_keeper ~(now_ts : float) ?related_session_id keeper :
    continuity_context =
  let name = string_field "name" keeper in
  let agent_name =
    match trim_to_option (string_field "agent_name" keeper) with
    | Some value -> value
    | None -> name
  in
  let audit = tool_audit_snapshot agent_name in
  let status = string_field ~default:"unknown" "status" keeper in
  let context_ratio =
    match member_assoc "context_ratio" keeper with
    | `Float value -> Some value
    | `Int value -> Some (float_of_int value)
    | _ -> None
  in
  (* last_autonomous_action_at = actual keeper action (not heartbeat).
     updated_at is polluted by heartbeat — only use as last_heartbeat_at. *)
  let last_action_at =
    trim_to_option (string_field "last_autonomous_action_at" keeper)
  in
  let last_heartbeat_at =
    trim_to_option (string_field "updated_at" keeper)
  in
  (* last_signal_at: prefer autonomous action, fall back to heartbeat *)
  let last_signal_at =
    match last_action_at with
    | Some _ -> last_action_at
    | None -> last_heartbeat_at
  in
  let last_action_ts = parse_iso_opt last_action_at |> Option.value ~default:0.0 in
  let last_signal_ts = parse_iso_opt last_signal_at |> Option.value ~default:0.0 in
  let last_action_age_s =
    if last_action_ts > 0.0 then max 0.0 (now_ts -. last_action_ts)
    else infinity
  in
  let autonomous_action_count = int_field "autonomous_action_count" keeper in
  let turn_count = int_field "turn_count" keeper in
  let generation = int_field "generation" keeper in
  let goal_count = List.length (list_field "active_goal_ids" keeper) in
  let lifecycle =
    if List.mem status [ "offline"; "inactive"; "error" ] then "offline"
    else if Option.value ~default:0.0 context_ratio >= 0.85 then "handoff-imminent"
    else if Option.value ~default:0.0 context_ratio >= 0.70 then "preparing"
    else if Option.value ~default:0.0 context_ratio >= 0.50 then "compacting"
    else if last_action_ts > 0.0 then "active"
    else if last_signal_ts > 0.0 then "idle"
    else "idle"
  in
  let (state, tone, note) =
    if List.mem status [ "offline"; "inactive"; "error" ] then
      ("critical", "bad", "keeper 오프라인")
    else if lifecycle = "handoff-imminent" then
      ("critical", "bad", "핸드오프 임박")
    else if lifecycle = "preparing" || lifecycle = "compacting" then
      ("warning", "warn", "연속성 압력이 높습니다")
    else if autonomous_action_count = 0 && turn_count > 0 then
      ("warning", "warn",
       Printf.sprintf "자율 행동 없음 (턴 %d회 수행)" turn_count)
    else if last_action_age_s >= 3600.0 then
      ("warning", "warn",
       Printf.sprintf "마지막 행동 %.0f시간 전" (last_action_age_s /. 3600.0))
    else
      ("healthy", "ok", "정상 동작 중")
  in
  let continuity =
    Printf.sprintf "Gen %d · Turns %d · Actions %d · Goals %d"
      generation turn_count autonomous_action_count goal_count
  in
  let focus =
    match trim_to_option (string_field "short_goal" keeper) with
    | Some value -> value
    | None -> (
        match trim_to_option (string_field "goal" keeper) with
        | Some value -> value
        | None -> "현재 포커스 없음")
  in
  let recent_input_preview =
    trim_to_option (string_field "recent_input_preview" keeper)
  in
  let recent_output_preview =
    trim_to_option (string_field "recent_output_preview" keeper)
    |> option_or_else (fun () -> trim_to_option (string_field "last_proactive_preview" keeper))
  in
  let recent_tool_names =
    let keeper_tools = string_list_of_field "recent_tool_names" keeper in
    if keeper_tools <> [] then keeper_tools else audit.latest_tool_names
  in
  let allowed_tool_names =
    let keeper_tools = string_list_of_field "allowed_tool_names" keeper in
    if keeper_tools <> [] then keeper_tools else audit.allowed_tool_names
  in
  let latest_tool_names =
    let keeper_tools = string_list_of_field "latest_tool_names" keeper in
    if keeper_tools <> [] then keeper_tools else audit.latest_tool_names
  in
  let skill_route_summary = skill_route_summary_of_keeper keeper in
  let (emoji, korean_name) = get_agent_identity name in
  {
    tone_rank = tone_rank tone;
    last_signal_ts;
    related_session_id;
    json =
      `Assoc
        [
          ("name", `String name);
          ("agent_name", member_assoc "agent_name" keeper);
          ("status", `String status);
          ("tone", `String tone);
          ("state", `String state);
          ("note", `String note);
          ("focus", `String focus);
          ("last_signal_at", json_string_option last_signal_at);
          ("last_autonomous_action_at", json_string_option last_signal_at);
          ("generation", member_assoc "generation" keeper);
          ("turn_count", member_assoc "turn_count" keeper);
          ("context_ratio", option_to_json (fun value -> `Float value) context_ratio);
          ("continuity", `String continuity);
          ("lifecycle", `String lifecycle);
          ("related_session_id", json_string_option related_session_id);
          ("recent_input_preview", json_string_option recent_input_preview);
          ("recent_output_preview", json_string_option recent_output_preview);
          ("recent_tool_names", string_list_json recent_tool_names);
          ("allowed_tool_names", string_list_json allowed_tool_names);
          ("latest_tool_names", string_list_json latest_tool_names);
          ("latest_tool_call_count", option_to_json (fun value -> `Int value) audit.latest_tool_call_count);
          ("tool_audit_source", json_string_option audit.tool_audit_source);
          ("tool_audit_at", json_string_option audit.tool_audit_at);
          ("autonomous_action_count", `Int autonomous_action_count);
          ("last_heartbeat_at", json_string_option last_heartbeat_at);
          ("last_proactive_preview", member_assoc "last_proactive_preview" keeper);
          ("continuity_summary", `String (
            match trim_to_option (string_field "continuity_summary" keeper) with
            | Some s -> s
            | None ->
              if autonomous_action_count = 0 && turn_count = 0 then
                "아직 활동 기록이 없습니다"
              else if autonomous_action_count = 0 then
                Printf.sprintf "대기 중 (턴 %d회, 자율 행동 0회)" turn_count
              else
                Printf.sprintf "행동 %d회, 턴 %d회, 세대 %d"
                  autonomous_action_count turn_count generation));
          ("skill_route_summary", json_string_option skill_route_summary);
          ( "model",
            match trim_to_option (string_field "active_model" keeper) with
            | Some value -> `String value
            | None -> `Null );
          ("emoji", `String emoji);
          ("korean_name", `String korean_name);
          ("skill_reason", json_string_option (trim_to_option (string_field "goal" keeper)));
        ];
  }

let session_payload_json session_json =
  match member_assoc "status" session_json with
  | `Assoc _ as payload -> payload
  | _ -> session_json

let session_meta_json session_json =
  session_payload_json session_json |> member_assoc "session"

let session_summary_json session_json =
  session_payload_json session_json |> member_assoc "summary"

let session_team_health_json session_json =
  session_payload_json session_json |> member_assoc "team_health"

let session_communication_json session_json =
  session_payload_json session_json |> member_assoc "communication_metrics"

let session_status_string session_json =
  let summary = session_summary_json session_json in
  let meta = session_meta_json session_json in
  match trim_to_option (string_field "status" summary) with
  | Some value -> value
  | None -> (
      match trim_to_option (string_field "status" meta) with
      | Some value -> value
      | None ->
          trim_to_option (string_field "status" session_json)
          |> Option.value ~default:"unknown")

let session_recent_events session_json =
  list_field "recent_events" session_json

let event_detail_json event_json =
  member_assoc "detail" event_json

let event_summary event_json =
  let detail = event_detail_json event_json in
  let event_type =
    trim_to_option (string_field "event_type" event_json)
    |> Option.value ~default:"event"
  in
  let actor = trim_to_option (string_field "actor" detail) in
  let task_title =
    match trim_to_option (string_field "task_title" detail) with
    | Some value -> Some value
    | None -> trim_to_option (string_field "title" detail)
  in
  let result = trim_to_option (compact_text (string_field "result" detail)) in
  let reason = trim_to_option (compact_text (string_field "reason" detail)) in
  match task_title, result, reason with
  | Some title, _, _ ->
      compact_text
        (Printf.sprintf "%s%s"
           (match actor with Some value -> value ^ " · " | None -> "")
           title)
  | None, Some value, _ -> value
  | None, None, Some value -> value
  | None, None, None -> String.map (fun ch -> if ch = '_' then ' ' else ch) event_type

let session_severity ~health ~status ~runtime_blocker =
  if status = "completed" then
    if List.mem health [ "bad"; "critical" ] then "warn"
    else if List.mem health [ "warn"; "degraded" ] then "warn"
    else "ok"
  else if List.mem health [ "bad"; "critical" ]
          || List.mem status [ "failed"; "cancelled"; "interrupted" ]
  then
    "bad"
  else if List.mem health [ "warn"; "degraded" ]
          || List.mem status [ "paused" ]
          || Option.is_some runtime_blocker
  then
    "warn"
  else
    "ok"

let build_session_seed session_json session_cards =
  let session_id = string_field "session_id" session_json in
  if session_id = "" then None
  else
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
    let session_card =
      List.find_opt
        (fun json -> String.equal (string_field "session_id" json) session_id)
        session_cards
    in
    let top_attention =
      match session_card with
      | Some card -> (
          match member_assoc "top_attention" card with
          | `Null -> None
          | value -> Some value)
      | None -> None
    in
    let top_recommendation =
      match session_card with
      | Some card -> (
          match member_assoc "top_recommendation" card with
          | `Null -> None
          | value -> Some value)
      | None -> None
    in
    let attention_summary =
      Option.bind top_attention (fun json ->
          trim_to_option (string_field "summary" json))
    in
    let attention_kind =
      Option.bind top_attention (fun json -> trim_to_option (string_field "kind" json))
    in
    let runtime_blocker =
      match attention_kind, attention_summary with
      | Some ("spawn_failure_present" | "local64_role_gap" | "stalled_session" | "planned_worker_without_turn"), Some summary ->
          Some summary
      | _ -> attention_summary
    in
    let worker_gap_summary =
      match attention_kind, attention_summary with
      | Some ("spawn_failure_present" | "local64_role_gap" | "planned_worker_without_turn" | "detached_actor_present"), Some summary ->
          Some summary
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
      let planned =
        string_list_of_json (member_assoc "planned_participants" summary)
      in
      let explicit = List.length planned in
      if explicit > 0 then explicit else List.length member_names
    in
    let counts_basis =
      if List.length (string_list_of_json (member_assoc "planned_participants" summary)) > 0 then
        "live=recent_turns · planned=planned_participants"
      else
        "live=recent_turns · planned=known_members"
    in
    Some
      {
        session_id;
        goal =
          trim_to_option (string_field "goal" meta)
          |> Option.value ~default:session_id;
        room = trim_to_option (string_field "room_id" meta);
        status = session_status_string session_json;
        health =
          (match session_card with
          | Some card ->
              trim_to_option (string_field "health" card)
              |> Option.value ~default:"ok"
          | None ->
              trim_to_option (string_field "status" team_health)
              |> Option.value ~default:"ok");
        member_names;
        last_activity_at =
          Option.bind last_event (fun json ->
              trim_to_option (string_field "ts_iso" json));
        last_activity_ts =
          Option.bind last_event (fun json ->
              parse_iso_opt (trim_to_option (string_field "ts_iso" json)))
          |> Option.value ~default:0.0;
        last_activity_summary =
          (match last_event with
          | Some value -> event_summary value
          | None -> "최근 session event가 없습니다.");
        communication_summary =
          Printf.sprintf "%s · broadcast %d · portal %d" mode broadcast_count
            portal_count;
        active_count = int_field "active_agents_count" team_health;
        seen_count;
        planned_count;
        required_count = int_field ~default:1 "required_agents" team_health;
        counts_basis;
        runtime_blocker;
        worker_gap_summary;
        top_attention;
        top_recommendation;
      }

let detachment_index command_plane_json =
  let table = Hashtbl.create 32 in
  let detachments =
    member_assoc "detachments" command_plane_json
    |> member_assoc "detachments"
    |> function
    | `List items -> items
    | _ -> []
  in
  List.iter
    (fun detachment_card ->
      let detachment = member_assoc "detachment" detachment_card in
      let operation_id = string_field "operation_id" detachment in
      if operation_id <> "" then
        let session_id =
          trim_to_option (string_field "session_id" detachment)
        in
        let detachment_id =
          trim_to_option (string_field "detachment_id" detachment)
        in
        Hashtbl.replace table operation_id (session_id, detachment_id))
    detachments;
  table

let operation_severity ~status ~blocker_summary =
  if List.mem status [ "failed"; "cancelled" ] then
    "bad"
  else if List.mem status [ "paused" ] || Option.is_some blocker_summary then
    "warn"
  else
    "ok"

let build_operation_contexts command_plane_json =
  let operations =
    member_assoc "operations" command_plane_json
    |> member_assoc "operations"
    |> function
    | `List items -> items
    | _ -> []
  in
  let detachments = detachment_index command_plane_json in
  operations
  |> List.filter_map (fun operation_card ->
         let operation = member_assoc "operation" operation_card in
         let operation_id = string_field "operation_id" operation in
         if operation_id = "" then None
         else
           let search = member_assoc "search" operation_card in
           let blockers = list_field "dependency_blockers" search in
           let blocker_summary =
             match blockers with
             | blocker :: _ ->
                 trim_to_option (string_field "reason" blocker)
             | [] ->
                 if string_field "readiness" search = "blocked" then
                   Some "operation search is blocked"
                 else
                   None
           in
           let status = string_field ~default:"active" "status" operation in
           let severity = operation_severity ~status ~blocker_summary in
           let linked_session_id, linked_detachment_id =
             match Hashtbl.find_opt detachments operation_id with
             | Some (session_id, detachment_id) -> (session_id, detachment_id)
             | None ->
                 ( trim_to_option (string_field "detachment_session_id" operation),
                   None )
           in
           let command_handoff =
             handoff_json
               ~surface:"command"
               ~command_surface:"operations"
               ~operation_id
               ~label:"작전 원인 보기"
               ~target_type:"operation"
               ~target_id:operation_id
               ~focus_kind:"operation"
               ()
           in
           let updated_at =
             trim_to_option (string_field "updated_at" operation)
           in
           Some
             {
               operation_id;
               severity;
               last_seen_ts =
                 parse_iso_opt updated_at |> Option.value ~default:0.0;
               linked_session_id;
               linked_detachment_id;
               json =
                 `Assoc
                   [
                     ("operation_id", `String operation_id);
                     ("objective", member_assoc "objective" operation);
                     ("status", `String status);
                     ("stage", member_assoc "stage" operation);
                     ("assigned_unit_id", member_assoc "assigned_unit_id" operation);
                     ("assigned_unit_label", member_assoc "assigned_unit_label" operation_card);
                     ("linked_session_id", json_string_option linked_session_id);
                     ("linked_detachment_id", json_string_option linked_detachment_id);
                     ("blocker_summary", json_string_option blocker_summary);
                     ("search_status", member_assoc "readiness" search);
                     ( "next_tool",
                       if Option.is_some blocker_summary then `String "masc_operation_status"
                       else `String "masc_observe_operations" );
                     ("updated_at", json_string_option updated_at);
                     ("top_handoff", command_handoff);
                     ("command_handoff", command_handoff);
                   ];
             })
  |> List.sort (fun left right ->
         let by_severity =
           Int.compare
             (severity_rank right.severity)
             (severity_rank left.severity)
         in
         if by_severity <> 0 then by_severity
         else Float.compare right.last_seen_ts left.last_seen_ts)

let session_operation_links operation_contexts =
  let table = Hashtbl.create 32 in
  List.iter
    (fun (operation : operation_context) ->
      match operation.linked_session_id with
      | Some session_id when not (Hashtbl.mem table session_id) ->
          Hashtbl.add table session_id
            (Some operation.operation_id, operation.linked_detachment_id)
      | _ -> ())
    operation_contexts;
  table

let build_session_contexts seeds operation_contexts : session_context list =
  let links = session_operation_links operation_contexts in
  seeds
  |> List.map (fun (seed : session_seed) : session_context ->
         let linked_operation_id, linked_detachment_id =
           match Hashtbl.find_opt links seed.session_id with
           | Some value -> value
           | None -> (None, None)
         in
         let severity =
           session_severity ~health:seed.health ~status:seed.status
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
             ~target_type:"team_session"
             ~target_id:seed.session_id
             ~focus_kind:"team_session"
             ()
         in
         let command_handoff =
           handoff_json
             ~surface:"command"
             ~command_surface:
               (if Option.is_some linked_operation_id then "operations" else "swarm")
             ?operation_id:linked_operation_id
             ~label:"세션 원인 보기"
             ~target_type:"team_session"
             ~target_id:seed.session_id
             ~focus_kind:
               (if Option.is_some linked_operation_id then "operation" else "team_session")
             ()
         in
         let top_handoff =
           match seed.top_recommendation with
           | Some _ -> intervene_handoff
           | None ->
               if severity <> "ok" && Option.is_some linked_operation_id then
                 command_handoff
               else
                 intervene_handoff
         in
         {
           session_id = seed.session_id;
           severity;
           last_seen_ts = seed.last_activity_ts;
           linked_operation_id;
           member_names = seed.member_names;
           json =
             `Assoc
               [
                 ("session_id", `String seed.session_id);
                 ("goal", `String seed.goal);
                 ("room", json_string_option seed.room);
                 ("status", `String seed.status);
                 ("health", `String seed.health);
                 ( "member_names",
                   `List (List.map (fun value -> `String value) seed.member_names) );
                 ("linked_operation_id", json_string_option linked_operation_id);
                 ("linked_detachment_id", json_string_option linked_detachment_id);
                 ("runtime_blocker", json_string_option seed.runtime_blocker);
                 ("worker_gap_summary", json_string_option seed.worker_gap_summary);
                 ("last_activity_at", json_string_option seed.last_activity_at);
                 ("last_activity_summary", `String seed.last_activity_summary);
                 ("communication_summary", `String seed.communication_summary);
                 ("active_count", `Int seed.active_count);
                 ("seen_count", `Int seed.seen_count);
                 ("planned_count", `Int seed.planned_count);
                 ("required_count", `Int seed.required_count);
                 ("counts_basis", `String seed.counts_basis);
                 ("top_handoff", top_handoff);
                 ("intervene_handoff", intervene_handoff);
                 ("command_handoff", command_handoff);
                 ( "top_attention",
                   match seed.top_attention with
                   | Some value -> value
                   | None -> `Null );
                 ( "top_recommendation",
                   match seed.top_recommendation with
                   | Some value -> value
                   | None -> `Null );
               ];
         })
  |> List.sort (fun (left : session_context) (right : session_context) ->
         let by_severity =
           Int.compare
             (severity_rank right.severity)
             (severity_rank left.severity)
         in
         if by_severity <> 0 then by_severity
         else Float.compare right.last_seen_ts left.last_seen_ts)

let queue_summary_of_session (session_context : session_context) =
  match trim_to_option (string_field "runtime_blocker" session_context.json) with
  | Some summary -> summary
  | None -> (
      match trim_to_option (string_field "worker_gap_summary" session_context.json) with
      | Some summary -> summary
      | None ->
          trim_to_option (string_field "last_activity_summary" session_context.json)
          |> Option.value ~default:(string_field "goal" session_context.json))

let build_execution_queue session_contexts operation_contexts =
  let blocked_session_ids =
    session_contexts
    |> List.filter (fun (session : session_context) -> session.severity <> "ok")
    |> List.map (fun (session : session_context) -> session.session_id)
  in
  let session_items =
    session_contexts
    |> List.filter (fun (session : session_context) -> session.severity <> "ok")
    |> List.map (fun (session : session_context) ->
           {
             severity_rank = severity_rank session.severity;
             last_seen_ts = session.last_seen_ts;
             json =
               `Assoc
                 [
                   ("id", `String ("session-" ^ session.session_id));
                   ("kind", `String "session");
                   ("severity", `String session.severity);
                   ("status", member_assoc "status" session.json);
                   ("summary", `String (queue_summary_of_session session));
                   ("target_type", `String "team_session");
                   ("target_id", `String session.session_id);
                   ("linked_session_id", `String session.session_id);
                   ("linked_operation_id", option_to_json (fun value -> `String value) session.linked_operation_id);
                   ("last_seen_at", member_assoc "last_activity_at" session.json);
                   ("top_handoff", member_assoc "top_handoff" session.json);
                   ("intervene_handoff", member_assoc "intervene_handoff" session.json);
                   ("command_handoff", member_assoc "command_handoff" session.json);
                 ];
           })
  in
  let operation_items =
    operation_contexts
    |> List.filter (fun (operation : operation_context) ->
           operation.severity <> "ok"
           &&
           match operation.linked_session_id with
           | Some session_id -> not (List.mem session_id blocked_session_ids)
           | None -> true)
    |> List.map (fun (operation : operation_context) ->
           {
             severity_rank = severity_rank operation.severity;
             last_seen_ts = operation.last_seen_ts;
             json =
               `Assoc
                 [
                   ("id", `String ("operation-" ^ operation.operation_id));
                   ("kind", `String "operation");
                   ("severity", `String operation.severity);
                   ("status", member_assoc "status" operation.json);
                   ( "summary",
                     match trim_to_option (string_field "blocker_summary" operation.json) with
                     | Some summary -> `String summary
                     | None -> member_assoc "objective" operation.json );
                   ("target_type", `String "operation");
                   ("target_id", `String operation.operation_id);
                   ("linked_session_id", json_string_option operation.linked_session_id);
                   ("linked_operation_id", `String operation.operation_id);
                   ("last_seen_at", member_assoc "updated_at" operation.json);
                   ("top_handoff", member_assoc "top_handoff" operation.json);
                   ("intervene_handoff", `Null);
                   ("command_handoff", member_assoc "command_handoff" operation.json);
                 ];
           })
  in
  (session_items @ operation_items)
  |> List.sort (fun left right ->
         let by_severity = Int.compare right.severity_rank left.severity_rank in
         if by_severity <> 0 then by_severity
         else Float.compare right.last_seen_ts left.last_seen_ts)

let related_session_for_member session_contexts name =
  let normalized = String.lowercase_ascii (String.trim name) in
  session_contexts
  |> List.find_opt (fun (session : session_context) ->
         session.member_names
         |> List.exists (fun member ->
                String.equal
                  (String.lowercase_ascii (String.trim member))
                  normalized))

let build_worker_support_briefs ~(now_ts : float) ~(tasks : Types.task list)
    ~(agents : Types.agent list) ~(messages : Types.message list) session_contexts :
    worker_context list =
  let messages_by_agent = last_message_map messages in
  agents
  |> List.map (fun (agent : Types.agent) ->
         let related =
           related_session_for_member session_contexts agent.name
         in
         let related_session_id =
           match related with
           | Some session -> Some session.session_id
           | None -> None
         in
         let related_operation_id =
           match related with
           | Some session -> session.linked_operation_id
           | None -> None
         in
         worker_state_of_agent ~now_ts ~messages_by_agent ~tasks ?related_session_id
           ?related_operation_id agent)
  |> List.filter (fun (row : worker_context) ->
         row.related_session_id <> None || string_field "tone" row.json <> "ok")
  |> List.sort (fun (left : worker_context) (right : worker_context) ->
         let by_tone = Int.compare right.tone_rank left.tone_rank in
         if by_tone <> 0 then by_tone
         else Float.compare right.last_signal_ts left.last_signal_ts)

let build_continuity_briefs ~(now_ts : float) keepers session_contexts :
    continuity_context list =
  keepers
  |> List.filter_map (fun keeper ->
         let name = string_field "name" keeper in
         if name = "" then None
         else
           let related_session =
             related_session_for_member session_contexts name
           in
           let related_session_id =
             match related_session with
             | Some session -> Some session.session_id
             | None -> (
                 match trim_to_option (string_field "agent_name" keeper) with
                 | Some agent_name -> (
                     match related_session_for_member session_contexts agent_name with
                     | Some session -> Some session.session_id
                     | None -> None)
                 | None -> None)
           in
           let row =
             continuity_row_of_keeper ~now_ts ?related_session_id keeper
           in
           Some row)
  |> List.sort (fun (left : continuity_context) (right : continuity_context) ->
         let by_tone = Int.compare right.tone_rank left.tone_rank in
         if by_tone <> 0 then by_tone
         else Float.compare right.last_signal_ts left.last_signal_ts)

