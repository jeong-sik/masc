module U = Yojson.Safe.Util

type session_context = {
  session_id : string;
  goal : string;
  room : string option;
  status : string;
  health : string;
  member_names : string list;
  started_at : string option;
  elapsed_sec : int option;
  operation_id : string option;
  blocker_summary : string option;
  last_event_at : string option;
  last_event_ts : float;
  last_event_summary : string;
  communication_summary : string;
  active_count : int;
  seen_count : int;
  planned_count : int;
  required_count : int;
  counts_basis : string;
  top_attention : Yojson.Safe.t option;
  top_recommendation : Yojson.Safe.t option;
}

type attention_context = {
  severity : string;
  has_action : bool;
  last_seen_ts : float;
  related_session_ids : string list;
  related_agent_names : string list;
  json : Yojson.Safe.t;
}

type agent_context = {
  status_rank : int;
  related_attention_count : int;
  last_seen_ts : float;
  json : Yojson.Safe.t;
}

type keeper_context = {
  pressure_rank : int;
  last_seen_ts : float;
  json : Yojson.Safe.t;
}

type operation_context = {
  operation_id : string;
  linked_session_id : string option;
  status : string;
  stage : string option;
  detachment_status : string option;
  objective : string option;
  updated_at : string option;
}

type archived_agent_meta = {
  last_event_at : string option;
}

let json_string_option value =
  match value with
  | Some text when String.trim text <> "" -> `String (String.trim text)
  | _ -> `Null

let option_to_json f = function
  | Some value -> f value
  | None -> `Null

let member_assoc key json =
  match json with
  | `Assoc fields -> (match List.assoc_opt key fields with Some value -> value | None -> `Null)
  | _ -> `Null

let int_field ?(default = 0) key json =
  match member_assoc key json with
  | `Int value -> value
  | `Intlit raw -> (try int_of_string raw with Failure _ -> default)
  | `Float value -> int_of_float value
  | _ -> default

let string_field ?(default = "") key json =
  match member_assoc key json with
  | `String value -> value
  | _ -> default

let list_field key json =
  match member_assoc key json with
  | `List items -> items
  | _ -> []

let severity_rank = function
  | "bad" | "risk" | "critical" -> 2
  | "warn" | "watch" | "interrupted" | "degraded" -> 1
  | _ -> 0

let status_rank = function
  | "busy" -> 4
  | "active" -> 3
  | "listening" -> 2
  | "idle" -> 1
  | _ -> 0

let rec take n items =
  if n <= 0 then []
  else
    match items with
    | [] -> []
    | x :: xs -> x :: take (n - 1) xs

let trim_to_option = Dashboard_utils.trim_to_option

let compact_text ?(max_len = 160) raw =
  let normalized =
    String.trim raw
    |> String.split_on_char '\n'
    |> List.map String.trim
    |> List.filter (fun value -> value <> "")
    |> String.concat " "
    |> String.trim
  in
  if normalized = "" then ""
  else if String.length normalized <= max_len then normalized
  else String.sub normalized 0 (max_len - 1) ^ "…"

let string_list_json values =
  `List (List.map (fun value -> `String value) values)

let keeper_tool_audit_json_fields keeper agent_name =
  let fallback_allowed =
    Dashboard_utils.string_list_of_json (member_assoc "allowed_tool_names" keeper)
  in
  let fallback_latest =
    Dashboard_utils.string_list_of_json (member_assoc "latest_tool_names" keeper)
  in
  let fallback_count =
    match member_assoc "latest_tool_call_count" keeper with
    | `Int value -> Some value
    | `Intlit raw -> (try Some (int_of_string raw) with Failure _ -> None)
    | _ -> None
  in
  let fallback_source =
    match trim_to_option (string_field "tool_audit_source" keeper) with
    | Some _ as value -> value
    | None when fallback_allowed <> [] -> Some "keeper_policy"
    | None -> None
  in
  let fallback_at =
    trim_to_option (string_field "tool_audit_at" keeper)
  in
  let allowed_tool_names, latest_tool_names, latest_tool_call_count,
      tool_audit_source, tool_audit_at =
    match A2a_tools.latest_heartbeat_task agent_name,
          A2a_tools.latest_heartbeat_result agent_name with
    | Some task, Some result ->
        if task.seq > result.seq then
          ( task.allowed_tools,
            result.tool_names,
            Some result.tool_call_count,
            Some "heartbeat_task_pending_result",
            Some task.created_at )
        else
          ( task.allowed_tools,
            result.tool_names,
            Some result.tool_call_count,
            Some "heartbeat_result",
            Some result.updated_at )
    | Some task, None ->
        (task.allowed_tools, [], None, Some "heartbeat_task", Some task.created_at)
    | None, Some result ->
        ( fallback_allowed,
          result.tool_names,
          Some result.tool_call_count,
          Some "heartbeat_result",
          Some result.updated_at )
    | None, None ->
        (fallback_allowed, fallback_latest, fallback_count, fallback_source, fallback_at)
  in
  [
    ("allowed_tool_names", string_list_json allowed_tool_names);
    ("latest_tool_names", string_list_json latest_tool_names);
    ( "latest_tool_call_count",
      option_to_json (fun value -> `Int value) latest_tool_call_count );
    ("tool_audit_source", json_string_option tool_audit_source);
    ("tool_audit_at", json_string_option tool_audit_at);
  ]

let parse_iso_opt = Dashboard_utils.parse_iso_opt
let string_list_of_json = Dashboard_utils.string_list_of_json

let dedup_strings items =
  List.sort_uniq String.compare
    (List.filter_map trim_to_option items)

let normalized_text_key text =
  compact_text ~max_len:512 text |> String.trim |> String.lowercase_ascii

let top_item items =
  match items with
  | item :: _ -> item
  | [] -> `Null

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
      | None -> trim_to_option (string_field "status" session_json) |> Option.value ~default:"unknown")

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
        (Printf.sprintf "%s%s" (match actor with Some value -> value ^ " · " | None -> "") title)
  | None, Some value, _ -> value
  | None, None, Some value -> value
  | None, None, None -> String.map (fun ch -> if ch = '_' then ' ' else ch) event_type

let build_session_context session_json session_cards =
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
      |> List.sort (fun a b ->
             let left =
               parse_iso_opt (trim_to_option (string_field "ts_iso" b))
               |> Option.value ~default:0.0
             in
             let right =
               parse_iso_opt (trim_to_option (string_field "ts_iso" a))
               |> Option.value ~default:0.0
             in
             Float.compare left right)
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
    let operation_id = trim_to_option (string_field "operation_id" meta) in
    let mode =
      trim_to_option (string_field "mode" communication)
      |> Option.value ~default:"mode n/a"
    in
    let broadcast_count = int_field "broadcast_count" communication in
    let portal_count = int_field "portal_count" communication in
    let member_names =
      dedup_strings
        (string_list_of_json (member_assoc "agent_names" meta)
        @ string_list_of_json (member_assoc "active_agents" summary)
        @ string_list_of_json (member_assoc "planned_participants" summary))
    in
    let seen_count = int_field "seen_agents_count" summary in
    let planned_count =
      let planned = string_list_of_json (member_assoc "planned_participants" summary) in
      let explicit = List.length planned in
      if explicit > 0 then explicit else List.length member_names
    in
    let counts_basis =
      if List.length (string_list_of_json (member_assoc "planned_participants" summary)) > 0 then
        "live=recent_turns · planned=planned_participants"
      else
        "live=recent_turns · planned=known_members"
    in
    let blocker_summary =
      match top_attention with
      | Some attention ->
          trim_to_option (string_field "summary" attention)
      | None ->
          if int_field "active_agents_count" team_health < int_field ~default:1 "required_agents" team_health
          then
            Some
              (Printf.sprintf "active %d / required %d"
                 (int_field "active_agents_count" team_health)
                 (int_field ~default:1 "required_agents" team_health))
          else
            Option.bind top_recommendation (fun action ->
                trim_to_option (string_field "reason" action))
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
        started_at = trim_to_option (string_field "created_at_iso" meta);
        elapsed_sec =
          (match member_assoc "elapsed_sec" summary with
          | `Int value -> Some value
          | `Float value -> Some (int_of_float value)
          | _ -> None);
        operation_id;
        blocker_summary;
        last_event_at =
          Option.bind last_event (fun json -> trim_to_option (string_field "ts_iso" json));
        last_event_ts =
          Option.bind last_event (fun json -> parse_iso_opt (trim_to_option (string_field "ts_iso" json)))
          |> Option.value ~default:0.0;
        last_event_summary =
          (match last_event with Some value -> event_summary value | None -> "최근 session event가 없습니다.");
        communication_summary =
          Printf.sprintf "%s · broadcast %d · portal %d" mode broadcast_count
            portal_count;
        active_count = int_field "active_agents_count" team_health;
        seen_count;
        planned_count;
        required_count = int_field ~default:1 "required_agents" team_health;
        counts_basis;
        top_attention;
        top_recommendation;
      }

let matching_action target_type target_id actions =
  List.find_opt
    (fun action ->
      let action_target_type = string_field "target_type" action in
      let action_target_id = trim_to_option (string_field "target_id" action) in
      String.equal action_target_type target_type
      &&
      match target_id, action_target_id with
      | Some left, Some right -> String.equal left right
      | None, None -> true
      | _ -> false)
    actions

let action_identity action =
  String.concat "|"
    [
      string_field "action_type" action;
      string_field "target_type" action;
      Option.value ~default:"none" (trim_to_option (string_field "target_id" action));
      normalized_text_key (string_field "reason" action);
    ]

let incident_identity incident =
  String.concat "|"
    [
      string_field "kind" incident;
      string_field "target_type" incident;
      Option.value ~default:"none" (trim_to_option (string_field "target_id" incident));
      normalized_text_key (string_field "summary" incident);
    ]

let identity_digest prefix identity =
  Printf.sprintf "%s:%s" prefix (Digest.to_hex (Digest.string identity))

let incident_action_types kind =
  match kind with
  | "spawn_failure_present" -> [ "team_task_inject" ]
  | "detached_actor_present"
  | "empty_note_turn_present"
  | "low_confidence_routing"
  | "routing_escalation_present" ->
      [ "team_note" ]
  | "planned_worker_without_turn" -> [ "team_worker_spawn_batch"; "team_note" ]
  | "local64_role_gap" -> [ "team_worker_spawn_batch" ]
  | "stalled_session" -> [ "team_stop" ]
  | "command_issue_pressure"
  | "command_routing_confidence"
  | "command_quality_per_token"
  | "command_verification_gate_failures"
  | "command_rework_rate"
  | "command_artifact_scope_drift"
  | "command_cache_contention"
  | "command_speculative_posture"
  | "intent_blocked"
  | "intent_handoff_ready" ->
      [ "broadcast" ]
  | _ -> []

let action_matches_incident incident action =
  let target_type = string_field "target_type" incident in
  let target_id = trim_to_option (string_field "target_id" incident) in
  let action_target_type = string_field "target_type" action in
  let action_target_id = trim_to_option (string_field "target_id" action) in
  let same_target =
    String.equal action_target_type target_type
    &&
    match target_id, action_target_id with
    | Some left, Some right -> String.equal left right
    | None, None -> true
    | _ -> false
  in
  if not same_target then false
  else
    let incident_summary = normalized_text_key (string_field "summary" incident) in
    let action_reason = normalized_text_key (string_field "reason" action) in
    let reason_matches =
      incident_summary <> "" && action_reason <> ""
      && String.equal incident_summary action_reason
    in
    if reason_matches then true
    else
      let action_type = string_field "action_type" action in
      List.mem action_type (incident_action_types (string_field "kind" incident))

let matching_action_for_incident incident actions =
  let target_type = string_field "target_type" incident in
  let target_id = trim_to_option (string_field "target_id" incident) in
  let candidates =
    actions
    |> List.filter (fun action ->
           let action_target_type = string_field "target_type" action in
           let action_target_id = trim_to_option (string_field "target_id" action) in
           String.equal action_target_type target_type
           &&
           match target_id, action_target_id with
           | Some left, Some right -> String.equal left right
           | None, None -> true
           | _ -> false)
  in
  match List.find_opt (action_matches_incident incident) candidates with
  | Some action -> Some action
  | None -> (match candidates with action :: _ -> Some action | [] -> None)

let rec evidence_preview_strings json =
  match json with
  | `String value ->
      let compact = compact_text value in
      if compact = "" then [] else [ compact ]
  | `List items ->
      items |> List.concat_map evidence_preview_strings |> dedup_strings |> take 4
  | `Assoc fields ->
      fields |> List.map snd |> List.concat_map evidence_preview_strings |> dedup_strings |> take 4
  | _ -> []

let is_internal_attention incident =
  String.equal (string_field "target_type" incident) "room"

let is_internal_action action =
  String.equal (string_field "target_type" action) "room"

let related_sessions_for_attention incident sessions =
  let direct_session =
    if String.equal (string_field "target_type" incident) "team_session" then
      trim_to_option (string_field "target_id" incident)
      |> Option.to_list
    else
      []
  in
  let actor = trim_to_option (string_field "actor" incident) in
  let by_actor =
    match actor with
    | None -> []
    | Some actor_name ->
        sessions
        |> List.filter_map (fun (session : session_context) ->
               if List.mem actor_name session.member_names then Some session.session_id
               else None)
  in
  dedup_strings (direct_session @ by_actor)

let session_by_id sessions session_id =
  List.find_opt (fun (session : session_context) -> String.equal session.session_id session_id) sessions

let build_attention_queue incidents actions sessions =
  let public_incidents =
    incidents
    |> List.filter (fun incident -> not (is_internal_attention incident))
  in
  public_incidents
  |> List.filter_map (fun incident ->
         let kind = string_field "kind" incident in
         let severity = string_field ~default:"warn" "severity" incident in
         let summary = string_field "summary" incident in
         if kind = "" || summary = "" then None
         else
           let target_type = string_field "target_type" incident in
           let target_id = trim_to_option (string_field "target_id" incident) in
           let related_session_ids = related_sessions_for_attention incident sessions in
           let related_agent_names =
             let from_sessions =
               related_session_ids
               |> List.filter_map (session_by_id sessions)
               |> List.concat_map (fun session -> session.member_names)
             in
             dedup_strings
               (from_sessions
               @
               match trim_to_option (string_field "actor" incident) with
               | Some actor -> [ actor ]
               | None -> [])
           in
           let top_action = matching_action_for_incident incident actions in
           let last_seen_at =
             related_session_ids
             |> List.filter_map (fun session_id ->
                    match session_by_id sessions session_id with
                    | Some session -> session.last_event_at
                    | None -> None)
             |> List.sort (fun left right ->
                    Float.compare
                      (parse_iso_opt (Some right) |> Option.value ~default:0.0)
                      (parse_iso_opt (Some left) |> Option.value ~default:0.0))
             |> function
             | value :: _ -> Some value
             | [] -> None
           in
           let id =
             Printf.sprintf "%s:%s:%s" kind target_type
               (match target_id with Some value -> value | None -> "none")
           in
           Some
             {
               severity;
               has_action = Option.is_some top_action;
               last_seen_ts =
                 parse_iso_opt last_seen_at |> Option.value ~default:0.0;
               related_session_ids;
               related_agent_names;
               json =
                 `Assoc
                   [
                     ("id", `String id);
                     ("kind", `String kind);
                     ("severity", `String severity);
                     ("summary", `String summary);
                     ("target_type", `String target_type);
                     ("target_id", json_string_option target_id);
                     ("top_action", option_to_json (fun value -> value) top_action);
                     ("related_session_ids", `List (List.map (fun value -> `String value) related_session_ids));
                     ("related_agent_names", `List (List.map (fun value -> `String value) related_agent_names));
                     ("evidence_preview", `List (List.map (fun value -> `String value) (evidence_preview_strings (member_assoc "evidence" incident))));
                     ("last_seen_at", json_string_option last_seen_at);
                   ];
             })
  |> List.sort (fun left right ->
         let by_severity = Int.compare (severity_rank right.severity) (severity_rank left.severity) in
         if by_severity <> 0 then by_severity
         else
           let by_action = Bool.compare right.has_action left.has_action in
           if by_action <> 0 then by_action
           else Float.compare right.last_seen_ts left.last_seen_ts)

let build_session_briefs sessions attention_queue actions =
  let attention_for_session session_id =
    attention_queue
    |> List.filter (fun attention -> List.mem session_id attention.related_session_ids)
  in
  sessions
  |> List.map (fun (session : session_context) ->
         let related_attentions = attention_for_session session.session_id in
         let top_attention_json =
           match related_attentions with
           | attention :: _ -> Some (member_assoc "severity" attention.json |> ignore; attention.json)
           | [] -> session.top_attention
         in
         let top_recommendation_json =
           match session.top_recommendation with
           | Some value -> Some value
           | None -> (
               match top_attention_json with
               | Some attention -> matching_action_for_incident attention actions
               | None ->
                   matching_action "team_session" (Some session.session_id) actions)
         in
         let health_tone =
           match top_attention_json with
           | Some attention -> string_field ~default:session.health "severity" attention
           | None -> session.health
         in
         let related_attention_count = List.length related_attentions in
         let sort_severity = severity_rank health_tone in
         ( sort_severity,
           related_attention_count,
           session.last_event_ts,
           `Assoc
             [
               ("session_id", `String session.session_id);
               ("goal", `String session.goal);
               ("room", json_string_option session.room);
               ("status", `String session.status);
               ("health", `String session.health);
               ("member_names", `List (List.map (fun value -> `String value) session.member_names));
               ("started_at", json_string_option session.started_at);
               ("elapsed_sec", option_to_json (fun value -> `Int value) session.elapsed_sec);
               ("operation_id", json_string_option session.operation_id);
               ("blocker_summary", json_string_option session.blocker_summary);
               ("last_event_at", json_string_option session.last_event_at);
               ("last_event_summary", `String session.last_event_summary);
               ("communication_summary", `String session.communication_summary);
               ("active_count", `Int session.active_count);
               ("seen_count", `Int session.seen_count);
               ("planned_count", `Int session.planned_count);
               ("required_count", `Int session.required_count);
               ("counts_basis", `String session.counts_basis);
               ("related_attention_count", `Int related_attention_count);
               ("top_attention", option_to_json (fun value -> value) top_attention_json);
               ("top_recommendation", option_to_json (fun value -> value) top_recommendation_json);
             ] ) )
  |> List.sort (fun (left_sev, left_count, left_ts, _) (right_sev, right_count, right_ts, _) ->
         let by_count = Int.compare right_count left_count in
         if by_count <> 0 then by_count
         else
           let by_severity = Int.compare right_sev left_sev in
           if by_severity <> 0 then by_severity else Float.compare right_ts left_ts)
  |> List.map (fun (_, _, _, json) -> json)

let build_task_lookup config =
  if not (Room.is_initialized config) then
    []
  else
    Room.get_tasks_raw config
    |> List.filter_map (fun (task : Types.task) ->
           if String.trim task.id = "" then None
           else Some (task.id, Printf.sprintf "%s · %s" task.id (compact_text task.title)))

let latest_message_from agent_name messages =
  let lowered = String.lowercase_ascii (String.trim agent_name) in
  List.fold_left
    (fun best (message : Types.message) ->
      if not (String.equal (String.lowercase_ascii (String.trim message.from_agent)) lowered) then
        best
      else
        match best with
        | None -> Some message
        | Some current ->
            if message.seq >= current.seq then Some message else best)
    None messages

let latest_message_to agent_name messages =
  let lowered = String.lowercase_ascii (String.trim agent_name) in
  List.fold_left
    (fun best (message : Types.message) ->
      let content = String.lowercase_ascii message.content in
      let from_self = String.equal (String.lowercase_ascii (String.trim message.from_agent)) lowered in
      let mentioned =
        String.contains content '@'
        && (String.contains content (String.get lowered 0)
            || String.contains content (String.get lowered (String.length lowered - 1)))
      in
      if from_self || not mentioned
      then best
      else
        match best with
        | None -> Some message
        | Some current ->
            if message.seq >= current.seq then Some message else best)
    None messages

let read_recent_room_event_lines config ~limit =
  let events_dir = Filename.concat (Room.masc_dir config) "events" in
  if not (Sys.file_exists events_dir) then []
  else
    let month_dirs =
      Sys.readdir events_dir |> Array.to_list |> List.sort compare |> List.rev
    in
    let collected = ref [] in
    let remaining = ref limit in
    let read_lines path =
      let ic = open_in path in
      Fun.protect
        ~finally:(fun () -> close_in_noerr ic)
        (fun () ->
          let rec loop acc =
            match input_line ic with
            | line -> loop (line :: acc)
            | exception End_of_file -> List.rev acc
          in
          loop [])
    in
    let add_lines path =
      if !remaining <= 0 then ()
      else
        let lines = read_lines path in
        let rec take lines_rev =
          match lines_rev with
          | [] -> ()
          | line :: rest ->
              if !remaining > 0 then (
                collected := line :: !collected;
                decr remaining;
                take rest)
        in
        take (List.rev lines)
    in
    List.iter
      (fun month ->
        if !remaining > 0 then
          let month_path = Filename.concat events_dir month in
          if Sys.file_exists month_path && Sys.is_directory month_path then
            let files =
              Sys.readdir month_path |> Array.to_list |> List.sort compare |> List.rev
            in
            List.iter
              (fun file ->
                if !remaining > 0 then
                  let path = Filename.concat month_path file in
                  if Sys.file_exists path then add_lines path)
              files)
      month_dirs;
    List.rev !collected

let status_of_archived_session (session : session_context option) =
  match session with
  | Some session ->
      if List.mem session.status [ "completed"; "interrupted"; "cancelled" ]
      then "inactive"
      else "offline"
  | None -> "unknown"

let archived_reason_for_session (session : session_context option) =
  match session with
  | Some session ->
      Some
        (if List.mem session.status [ "completed"; "interrupted"; "cancelled" ]
         then "not in current room state"
         else "missing from current room state")
  | None -> None

let archived_agent_meta_map config agent_names =
  let wanted = Hashtbl.create (List.length agent_names) in
  List.iter (fun agent_name -> Hashtbl.replace wanted agent_name ()) agent_names;
  let table = Hashtbl.create (List.length agent_names) in
  let ensure_row agent_name =
    match Hashtbl.find_opt table agent_name with
    | Some row -> row
    | None ->
        let row =
          {
            last_event_at = None;
          }
        in
        Hashtbl.add table agent_name row;
        row
  in
  read_recent_room_event_lines config ~limit:2000
  |> List.rev
  |> List.iter (fun line ->
         try
           let json = Yojson.Safe.from_string line in
           let agent_name = string_field "agent" json in
           if agent_name <> "" && Hashtbl.mem wanted agent_name then (
             let row = ensure_row agent_name in
             let last_event_at =
               match trim_to_option (string_field "ts" json) with
               | Some _ as value -> value
               | None -> trim_to_option (string_field "timestamp" json)
             in
             let row =
               if row.last_event_at = None
               then { last_event_at }
               else row
             in
             Hashtbl.replace table agent_name row)
         with Yojson.Json_error _ -> ());
  table

let keeper_alias_by_agent_name snapshot_json =
  let table = Hashtbl.create 8 in
  let keepers =
    match member_assoc "keepers" snapshot_json |> member_assoc "items" with
    | `List items -> items
    | _ -> []
  in
  List.iter
    (fun keeper ->
      let keeper_name = trim_to_option (string_field "name" keeper) in
      let agent_name = trim_to_option (string_field "agent_name" keeper) in
      match keeper_name, agent_name with
      | Some keeper_name, Some agent_name ->
          Hashtbl.replace table agent_name keeper_name
      | _ -> ())
    keepers;
  table

let build_agent_briefs config sessions attention_queue _room_json snapshot_json =
  let now_ts = Time_compat.now () in
  let task_lookup = build_task_lookup config in
  let messages =
    if Room.is_initialized config then
      Room.get_messages_raw config ~since_seq:0 ~limit:200
    else
      []
  in
  let task_label task_id =
    match task_id with
    | None -> None
    | Some id -> (
        match List.assoc_opt id task_lookup with
        | Some label -> Some label
        | None -> Some id)
  in
  let room_agents =
    if Room.is_initialized config then Room.get_agents_raw config else []
  in
  let room_agent_by_name =
    room_agents
    |> List.map (fun (agent : Types.agent) -> (agent.name, agent))
  in
  let agent_names =
    dedup_strings
      (List.map (fun (agent : Types.agent) -> agent.name) room_agents
      @ List.concat_map (fun (session : session_context) -> session.member_names) sessions)
  in
  let archived_meta_by_name = archived_agent_meta_map config agent_names in
  let keeper_aliases = keeper_alias_by_agent_name snapshot_json in
  agent_names
  |> List.map (fun agent_name ->
         let agent = List.assoc_opt agent_name room_agent_by_name in
         let related_session =
           List.find_opt
             (fun (session : session_context) -> List.mem agent_name session.member_names)
             sessions
         in
         let related_attention_count =
           attention_queue
           |> List.fold_left
                (fun acc attention ->
                  if List.mem agent_name attention.related_agent_names then acc + 1
                  else
                    match related_session with
                    | Some session when List.mem session.session_id attention.related_session_ids ->
                        acc + 1
                    | _ -> acc)
                0
         in
         let latest_out = latest_message_from agent_name messages in
         let latest_in = latest_message_to agent_name messages in
         let current_work =
           task_label (Option.bind agent (fun value -> value.current_task))
         in
         let archived_meta = Hashtbl.find_opt archived_meta_by_name agent_name in
         let display_name =
           Hashtbl.find_opt keeper_aliases agent_name |> Option.value ~default:agent_name
         in
         let recent_output_preview =
           latest_out |> Option.map (fun (message : Types.message) -> compact_text message.content)
         in
         let recent_input_preview =
           latest_in |> Option.map (fun (message : Types.message) -> compact_text message.content)
         in
         let status =
           match agent with
           | Some value -> Types.agent_status_to_string value.status
           | None -> status_of_archived_session related_session
         in
         let last_activity_at =
           match agent with
           | Some value -> trim_to_option value.last_seen
            | None ->
               (match archived_meta with
               | Some meta when meta.last_event_at <> None -> meta.last_event_at
               | _ ->
                   match related_session with
                   | Some session -> session.last_event_at
                   | None -> None)
         in
         let last_seen_ts =
           match agent with
            | Some value ->
                parse_iso_opt (trim_to_option value.last_seen) |> Option.value ~default:0.0
            | None ->
                (match related_session with
                | Some session -> session.last_event_ts
                | None -> 0.0)
         in
         let last_activity_age_sec =
           if last_seen_ts > 0.0 then Some (max 0 (int_of_float (now_ts -. last_seen_ts)))
           else None
         in
         let signal_truth =
           match agent, last_activity_age_sec with
           | None, _ -> "archived"
           | Some _, Some age when age <= 300 -> "live"
           | Some _, Some _ -> "stale"
           | Some _, None -> "unknown"
         in
         let evidence_source =
           if Option.is_some latest_out || Option.is_some latest_in then
             "message"
           else if Option.is_some agent then
             "presence"
           else if Option.is_some related_session then
             "session"
           else
             "none"
         in
         ({
           status_rank = status_rank status;
           related_attention_count;
           last_seen_ts;
           json =
              `Assoc
                ([
                   ("agent_name", `String agent_name);
                  ("display_name", `String display_name);
                  ("is_live", `Bool (Option.is_some agent));
                  ( "archived_reason",
                    json_string_option
                      (if Option.is_some agent
                       then None
                       else archived_reason_for_session related_session) );
                  ("status", `String status);
                  ("current_work", json_string_option current_work);
                  ("related_session_id", json_string_option (Option.map (fun s -> s.session_id) related_session));
                  ("last_activity_at", json_string_option last_activity_at);
                  ("last_activity_age_sec", option_to_json (fun value -> `Int value) last_activity_age_sec);
                  ("signal_truth", `String signal_truth);
                  ("evidence_source", `String evidence_source);
                  ("recent_output_preview", json_string_option recent_output_preview);
                  ("recent_input_preview", json_string_option recent_input_preview);
                ]);
         } : agent_context))
  |> List.sort (fun (left : agent_context) (right : agent_context) ->
         let by_attention = Int.compare right.related_attention_count left.related_attention_count in
         if by_attention <> 0 then by_attention
         else
           let by_status = Int.compare right.status_rank left.status_rank in
           if by_status <> 0 then by_status
           else Float.compare right.last_seen_ts left.last_seen_ts)
  |> List.map (fun (row : agent_context) -> row.json)

let build_keeper_briefs snapshot_json =
  let keepers = member_assoc "keepers" snapshot_json |> member_assoc "items" |> function
    | `List items -> items
    | _ -> []
  in
  keepers
  |> List.filter_map (fun keeper ->
         let name = string_field "name" keeper in
         if name = "" then None
         else
           let status = string_field ~default:"unknown" "status" keeper in
           let context_ratio =
             match member_assoc "context_ratio" keeper with
             | `Float value -> Some value
             | `Int value -> Some (float_of_int value)
             | _ -> None
           in
           let pressure_rank =
             if List.mem status [ "offline"; "inactive"; "error" ] then 3
             else if Option.value ~default:0.0 context_ratio >= 0.80 then 2
             else if status = "idle" then 1
             else 0
           in
           Some
             {
               pressure_rank;
               last_seen_ts =
                 parse_iso_opt
                   (trim_to_option
                      (match trim_to_option (string_field "last_autonomous_action_at" keeper) with
                      | Some value -> value
                      | None -> string_field "updated_at" keeper))
                 |> Option.value ~default:0.0;
               json =
                 `Assoc
                   ([
                      ("name", `String name);
                      ("agent_name", member_assoc "agent_name" keeper);
                      ("status", `String status);
                      ("generation", member_assoc "generation" keeper);
                      ("context_ratio", option_to_json (fun value -> `Float value) context_ratio);
                      ("last_turn_ago_s", member_assoc "last_turn_ago_s" keeper);
                      ( "current_work",
                        json_string_option
                          (match trim_to_option (string_field "short_goal" keeper) with
                           | Some value -> Some value
                           | None -> trim_to_option (string_field "goal" keeper)) );
                      ("last_autonomous_action_at", member_assoc "last_autonomous_action_at" keeper);
                    ]
                    @ keeper_tool_audit_json_fields keeper
                        (match trim_to_option (string_field "agent_name" keeper) with
                         | Some agent_name -> agent_name
                         | None -> name));
             })
  |> List.sort (fun left right ->
         let by_pressure = Int.compare right.pressure_rank left.pressure_rank in
         if by_pressure <> 0 then by_pressure
         else Float.compare right.last_seen_ts left.last_seen_ts)
  |> List.map (fun (row : keeper_context) -> row.json)

let build_internal_signals incidents actions =
  let internal_incidents =
    incidents
    |> List.filter is_internal_attention
    |> List.map (fun incident ->
           let action = List.find_opt (action_matches_incident incident) actions in
           {
             pressure_rank = severity_rank (string_field ~default:"warn" "severity" incident);
             last_seen_ts = 0.0;
             json =
               `Assoc
                 [
                   ("id", `String (identity_digest "attention" (incident_identity incident)));
                   ("signal_type", `String "attention");
                   ("severity", member_assoc "severity" incident);
                   ("summary", member_assoc "summary" incident);
                   ("target_type", member_assoc "target_type" incident);
                   ("target_id", member_assoc "target_id" incident);
                   ("attention", incident);
                   ("action", option_to_json (fun value -> value) action);
                 ];
           })
  in
  let matched_internal_action_keys =
    internal_incidents
    |> List.filter_map (fun row ->
           match member_assoc "action" row.json with
           | `Assoc _ as action -> Some (action_identity action)
           | _ -> None)
  in
  let internal_actions =
    actions
    |> List.filter is_internal_action
    |> List.filter (fun action ->
           not (List.mem (action_identity action) matched_internal_action_keys))
    |> List.map (fun action ->
           {
             pressure_rank = severity_rank (string_field ~default:"warn" "severity" action);
             last_seen_ts = 0.0;
             json =
               `Assoc
                 [
                   ("id", `String (identity_digest "action" (action_identity action)));
                   ("signal_type", `String "action");
                   ("severity", member_assoc "severity" action);
                   ("summary", member_assoc "reason" action);
                   ("target_type", member_assoc "target_type" action);
                   ("target_id", member_assoc "target_id" action);
                   ("attention", `Null);
                   ("action", action);
                 ];
           })
  in
  (internal_incidents @ internal_actions)
  |> List.sort (fun left right -> Int.compare right.pressure_rank left.pressure_rank)
  |> List.map (fun (row : keeper_context) -> row.json)

let detachment_index command_plane_json =
  let table = Hashtbl.create 16 in
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
        Hashtbl.replace table operation_id
          ( trim_to_option (string_field "session_id" detachment),
            trim_to_option (string_field "status" detachment) ))
    detachments;
  table

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
           let linked_session_id, detachment_status =
             match Hashtbl.find_opt detachments operation_id with
             | Some (session_id, status) -> (session_id, status)
             | None ->
                 (trim_to_option (string_field "detachment_session_id" operation), None)
           in
           Some
             {
               operation_id;
               linked_session_id;
               status = string_field ~default:"unknown" "status" operation;
               stage = trim_to_option (string_field "stage" operation);
               detachment_status;
               objective = trim_to_option (string_field "objective" operation);
               updated_at = trim_to_option (string_field "updated_at" operation);
             })

let operation_badge_json (operation : operation_context) =
  `Assoc
    [
      ("operation_id", `String operation.operation_id);
      ("status", `String operation.status);
      ("stage", json_string_option operation.stage);
      ("detachment_status", json_string_option operation.detachment_status);
      ("objective", json_string_option operation.objective);
      ("updated_at", json_string_option operation.updated_at);
    ]

let operation_badges_for_session session operation_contexts =
  let linked_operation_ids =
    operation_contexts
    |> List.filter_map (fun (operation : operation_context) ->
           match operation.linked_session_id with
           | Some session_id when String.equal session_id session.session_id -> Some operation.operation_id
           | _ -> None)
  in
  let session_operation_ids =
    dedup_strings (Option.to_list session.operation_id @ linked_operation_ids)
  in
  let from_contexts =
    operation_contexts
    |> List.filter (fun (operation : operation_context) ->
           List.mem operation.operation_id session_operation_ids)
    |> List.map operation_badge_json
  in
  match from_contexts, session.operation_id with
  | [], Some operation_id ->
      [
        `Assoc
          [
            ("operation_id", `String operation_id);
            ("status", `String "unknown");
            ("stage", `Null);
            ("detachment_status", `Null);
            ("objective", `Null);
            ("updated_at", `Null);
          ];
      ]
  | _ -> from_contexts

let participant_preview_json session_id member_names agent_briefs =
  let member_set = List.sort_uniq String.compare member_names in
  agent_briefs
  |> List.filter_map (fun row ->
         let related_session_id = trim_to_option (string_field "related_session_id" row) in
         let agent_name = string_field "agent_name" row in
         let belongs =
           String.equal (Option.value ~default:"" related_session_id) session_id
           || List.mem agent_name member_set
         in
         if not belongs || agent_name = "" then None
         else
           Some
             (`Assoc
               [
                 ("agent_name", `String agent_name);
                 ("display_name", member_assoc "display_name" row);
                 ("is_live", member_assoc "is_live" row);
                 ("current_work", member_assoc "current_work" row);
                  ("recent_input_preview", member_assoc "recent_input_preview" row);
                  ("recent_output_preview", member_assoc "recent_output_preview" row);
                  ("last_activity_at", member_assoc "last_activity_at" row);
               ]))

let keeper_refs_for_session member_names keeper_briefs =
  let member_set = List.sort_uniq String.compare member_names in
  keeper_briefs
  |> List.filter_map (fun row ->
         let agent_name = trim_to_option (string_field "agent_name" row) in
         let name = string_field "name" row in
         let matches =
           (match agent_name with
           | Some value -> List.mem value member_set
           | None -> false)
           || List.mem name member_set
         in
         if not matches || name = "" then None
         else
           Some
             (`Assoc
               [
                 ("name", `String name);
                 ("agent_name", json_string_option agent_name);
                 ("status", member_assoc "status" row);
                 ("generation", member_assoc "generation" row);
                 ("context_ratio", member_assoc "context_ratio" row);
                 ("last_turn_ago_s", member_assoc "last_turn_ago_s" row);
                 ("current_work", member_assoc "current_work" row);
               ]))

let build_sessions sessions attention_queue agent_briefs keeper_briefs command_plane_json =
  let related_attention_count session_id =
    attention_queue
    |> List.fold_left
         (fun acc (attention : attention_context) ->
           if List.mem session_id attention.related_session_ids then acc + 1 else acc)
         0
  in
  let operation_contexts = build_operation_contexts command_plane_json in
  sessions
  |> List.map (fun (session : session_context) ->
         let attention_count = related_attention_count session.session_id in
         let top_attention = option_to_json (fun value -> value) session.top_attention in
         let top_recommendation =
           option_to_json (fun value -> value) session.top_recommendation
         in
         ( attention_count,
           severity_rank
             (match session.top_attention with
             | Some attention -> string_field ~default:session.health "severity" attention
             | None -> session.health),
           session.last_event_ts,
           `Assoc
             [
               ("session_id", `String session.session_id);
               ("goal", `String session.goal);
               ("room", json_string_option session.room);
               ("status", `String session.status);
               ("health", `String session.health);
               ("member_names", string_list_json session.member_names);
               ("started_at", json_string_option session.started_at);
               ("elapsed_sec", option_to_json (fun value -> `Int value) session.elapsed_sec);
               ("operation_id", json_string_option session.operation_id);
               ("blocker_summary", json_string_option session.blocker_summary);
               ("last_event_at", json_string_option session.last_event_at);
               ("last_event_summary", `String session.last_event_summary);
               ("communication_summary", `String session.communication_summary);
               ("active_count", `Int session.active_count);
               ("seen_count", `Int session.seen_count);
               ("planned_count", `Int session.planned_count);
               ("required_count", `Int session.required_count);
               ("counts_basis", `String session.counts_basis);
               ("related_attention_count", `Int attention_count);
               ("top_attention", top_attention);
               ("top_recommendation", top_recommendation);
               ( "member_previews",
                 `List
                   (participant_preview_json session.session_id session.member_names agent_briefs)
               );
               ( "operation_badges",
                 `List (operation_badges_for_session session operation_contexts) );
               ( "keeper_refs",
                 `List (keeper_refs_for_session session.member_names keeper_briefs) );
             ] ))
  |> List.sort (fun (left_count, left_sev, left_ts, _) (right_count, right_sev, right_ts, _) ->
         let by_count = Int.compare right_count left_count in
         if by_count <> 0 then by_count
         else
           let by_severity = Int.compare right_sev left_sev in
           if by_severity <> 0 then by_severity else Float.compare right_ts left_ts)
  |> List.map (fun (_, _, _, json) -> json)

let session_timeline_json session_json =
  session_recent_events session_json
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
  |> take 10
  |> List.mapi (fun idx event_json ->
         let detail = event_detail_json event_json in
         `Assoc
           [
             ("id", `String (Printf.sprintf "event-%d" idx));
             ("timestamp", member_assoc "ts_iso" event_json);
             ("event_type", member_assoc "event_type" event_json);
             ("actor", json_string_option (trim_to_option (string_field "actor" detail)));
             ("summary", `String (event_summary event_json));
           ])

type mission_projection = {
  generated_at : string;
  snapshot_json : Yojson.Safe.t;
  digest_json : Yojson.Safe.t;
  room_json : Yojson.Safe.t;
  command_json : Yojson.Safe.t;
  incidents : Yojson.Safe.t list;
  recommended_actions : Yojson.Safe.t list;
  attention_queue : attention_context list;
  sessions : session_context list;
  session_briefs : Yojson.Safe.t list;
  agent_briefs : Yojson.Safe.t list;
  keeper_briefs : Yojson.Safe.t list;
  internal_signals : Yojson.Safe.t list;
}

let build_projection ?actor ~config ~sw ~clock ~proc_mgr () =
  let actor_name =
    match actor with
    | Some value when String.trim value <> "" -> String.trim value
    | _ -> "dashboard"
  in
  let ctx : _ Operator_control.context =
    {
      config;
      agent_name = actor_name;
      sw;
      clock;
      proc_mgr;
      mcp_session_id = None;
    }
  in
  let snapshot_json =
    Dashboard_cache.get_or_compute
      (Printf.sprintf "snapshot:%s" actor_name)
      ~ttl:3.0
      (fun () ->
        Operator_control.snapshot_json
          ~actor:actor_name
          ~view:"summary"
          ~include_messages:false
          ~include_sessions:true
          ~include_keepers:true
          ctx)
  in
  let digest_json =
    Dashboard_cache.get_or_compute
      (Printf.sprintf "digest:%s" actor_name)
      ~ttl:5.0
      (fun () ->
        match Operator_control.digest_json ~actor:actor_name ctx with
        | Ok json -> json
        | Error message ->
            `Assoc
              [
                ("health", `String "warn");
                ("attention_items", `List []);
                ("recommended_actions", `List []);
                ("session_cards", `List []);
                ("swarm_status", Swarm_status.empty_json);
                ("command_plane", `Assoc []);
                ("error", `String message);
              ])
  in
  let room_json = member_assoc "room" snapshot_json in
  let command_json = member_assoc "command_plane" snapshot_json in
  let incidents =
    list_field "attention_items" digest_json
    |> List.sort (fun left right ->
           Int.compare
             (severity_rank (string_field ~default:"ok" "severity" right))
             (severity_rank (string_field ~default:"ok" "severity" left)))
  in
  let recommended_actions = list_field "recommended_actions" digest_json in
  let session_cards = list_field "session_cards" digest_json in
  let sessions =
    (match member_assoc "sessions" snapshot_json |> member_assoc "items" with
    | `List items -> items
    | _ -> [])
    |> List.filter_map (fun json -> build_session_context json session_cards)
  in
  let attention_queue = build_attention_queue incidents recommended_actions sessions in
  let session_briefs = build_session_briefs sessions attention_queue recommended_actions in
  let agent_briefs =
    build_agent_briefs config sessions attention_queue room_json snapshot_json
  in
  let keeper_briefs = build_keeper_briefs snapshot_json in
  let internal_signals = build_internal_signals incidents recommended_actions in
  {
    generated_at = Types.now_iso ();
    snapshot_json;
    digest_json;
    room_json;
    command_json;
    incidents;
    recommended_actions;
    attention_queue;
    sessions;
    session_briefs;
    agent_briefs;
    keeper_briefs;
    internal_signals;
  }

let json ?actor ~config ~sw ~clock ~proc_mgr () =
  let projection = build_projection ?actor ~config ~sw ~clock ~proc_mgr () in
  let operations_summary =
    member_assoc "operations" projection.command_json |> member_assoc "summary"
  in
  let decisions_summary =
    member_assoc "decisions" projection.command_json |> member_assoc "summary"
  in
  let session_cards = list_field "session_cards" projection.digest_json in
  let summary_json =
    `Assoc
      [
        ("room_health", `String (string_field ~default:"ok" "health" projection.digest_json));
        ("cluster", json_string_option (Some (string_field "cluster" projection.room_json)));
        ("project", json_string_option (Some (string_field "project" projection.room_json)));
        ("current_room", member_assoc "current_room" projection.room_json);
      ]
  in
  let command_focus_json =
    `Assoc
      [
        ("health", `String (string_field ~default:"ok" "health" projection.digest_json));
        ("active_operations", `Int (int_field "active" operations_summary));
        ("pending_approvals", `Int (int_field "pending" decisions_summary));
        ("swarm_overview", member_assoc "swarm_status" projection.digest_json |> member_assoc "overview");
        ("top_attention", top_item projection.incidents);
        ("top_action", top_item projection.recommended_actions);
        ("session_cards", `List (take 3 session_cards));
      ]
  in
  let operator_targets_json =
    `Assoc
      [
        ("sessions", member_assoc "sessions" projection.snapshot_json |> member_assoc "items");
        ("keepers", member_assoc "keepers" projection.snapshot_json |> member_assoc "items");
        ("pending_confirms", member_assoc "pending_confirms" projection.snapshot_json);
        ("available_actions", member_assoc "available_actions" projection.snapshot_json);
      ]
  in
  let sessions_json =
    build_sessions projection.sessions projection.attention_queue projection.agent_briefs
      projection.keeper_briefs projection.command_json
  in
  `Assoc
    [
      ("generated_at", `String projection.generated_at);
      ("summary", summary_json);
      ("incidents", `List projection.incidents);
      ("recommended_actions", `List projection.recommended_actions);
      ("command_focus", command_focus_json);
      ("operator_targets", operator_targets_json);
      ( "attention_queue",
        `List (List.map (fun (item : attention_context) -> item.json) projection.attention_queue)
      );
      ("sessions", `List sessions_json);
      ("session_briefs", `List projection.session_briefs);
      ("agent_briefs", `List projection.agent_briefs);
      ("keeper_briefs", `List projection.keeper_briefs);
      ("internal_signals", `List projection.internal_signals);
    ]

let session_json ?actor ~session_id ~config ~sw ~clock ~proc_mgr () =
  let projection = build_projection ?actor ~config ~sw ~clock ~proc_mgr () in
  let session_row_json =
    build_sessions projection.sessions projection.attention_queue projection.agent_briefs
      projection.keeper_briefs projection.command_json
    |> List.find_opt (fun json ->
           String.equal (string_field "session_id" json) session_id)
  in
  let session_source_json =
    member_assoc "sessions" projection.snapshot_json |> member_assoc "items"
    |> function
    | `List items ->
        List.find_opt
          (fun json -> String.equal (string_field "session_id" json) session_id)
          items
    | _ -> None
  in
  let session_context =
    List.find_opt
      (fun (session : session_context) -> String.equal session.session_id session_id)
      projection.sessions
  in
  let operation_contexts = build_operation_contexts projection.command_json in
  let operations_json =
    match session_context with
    | None -> []
    | Some session -> operation_badges_for_session session operation_contexts
  in
  let keepers_json =
    match session_context with
    | None -> []
    | Some session ->
        keeper_refs_for_session session.member_names projection.keeper_briefs
  in
  let participants_json =
    match session_context with
    | None -> []
    | Some session ->
        participant_preview_json session.session_id session.member_names projection.agent_briefs
  in
  `Assoc
    [
      ("generated_at", `String projection.generated_at);
      ("session_id", `String session_id);
      ("session", option_to_json (fun value -> value) session_row_json);
      ( "timeline",
        `List
          (match session_source_json with
          | Some json -> session_timeline_json json
          | None -> []) );
      ("participants", `List participants_json);
      ("operations", `List operations_json);
      ("keepers", `List keepers_json);
      ( "error",
        match session_row_json with
        | Some _ -> `Null
        | None -> `String "session not found" );
    ]
