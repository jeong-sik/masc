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
  last_event_at : string option;
  last_event_ts : float;
  last_event_summary : string;
  communication_summary : string;
  active_count : int;
  required_count : int;
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

let float_field ?(default = 0.0) key json =
  match member_assoc key json with
  | `Float value -> value
  | `Int value -> float_of_int value
  | `Intlit raw -> (try float_of_string raw with Failure _ -> default)
  | _ -> default

let bool_field ?(default = false) key json =
  match member_assoc key json with
  | `Bool value -> value
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

let trim_to_option text =
  let trimmed = String.trim text in
  if trimmed = "" then None else Some trimmed

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

let parse_iso_opt value =
  match value with
  | Some text when String.trim text <> "" -> Some (Types.parse_iso8601 text)
  | _ -> None

let string_list_of_json json =
  match json with
  | `List items ->
      items
      |> List.filter_map (function
             | `String value -> trim_to_option value
             | _ -> None)
  | _ -> []

let dedup_strings items =
  List.sort_uniq String.compare
    (List.filter_map trim_to_option items)

let top_item items =
  match items with
  | item :: _ -> item
  | [] -> `Null

let keeper_pressure_count snapshot_json =
  let keepers = member_assoc "keepers" snapshot_json |> member_assoc "items" |> function
    | `List items -> items
    | _ -> []
  in
  List.fold_left
    (fun acc keeper ->
      let status = string_field ~default:"unknown" "status" keeper in
      let context_ratio = float_field "context_ratio" keeper in
      let last_turn_ago_s = float_field "last_turn_ago_s" keeper in
      if List.mem status [ "offline"; "inactive"; "error" ]
         || context_ratio >= 0.80
         || last_turn_ago_s >= 3600.0
      then acc + 1
      else acc)
    0 keepers

let active_agent_count config =
  if not (Room.is_initialized config) then
    0
  else
    Room.get_agents_raw config
    |> List.fold_left
         (fun acc (agent : Types.agent) ->
           match agent.status with
           | Types.Active | Types.Busy | Types.Listening -> acc + 1
           | Types.Inactive -> acc)
         0

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
    let mode =
      trim_to_option (string_field "mode" communication)
      |> Option.value ~default:"mode n/a"
    in
    let broadcast_count = int_field "broadcast_count" communication in
    let portal_count = int_field "portal_count" communication in
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
        member_names = string_list_of_json (member_assoc "agent_names" meta);
        started_at = trim_to_option (string_field "created_at_iso" meta);
        elapsed_sec =
          (match member_assoc "elapsed_sec" summary with
          | `Int value -> Some value
          | `Float value -> Some (int_of_float value)
          | _ -> None);
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
        required_count = int_field ~default:1 "required_agents" team_health;
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
           let top_action = matching_action target_type target_id actions in
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
           | None ->
               matching_action "team_session" (Some session.session_id) actions
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
               ("last_event_at", json_string_option session.last_event_at);
               ("last_event_summary", `String session.last_event_summary);
               ("communication_summary", `String session.communication_summary);
               ("active_count", `Int session.active_count);
               ("required_count", `Int session.required_count);
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

let build_agent_briefs config sessions attention_queue room_json =
  let task_lookup = build_task_lookup config in
  let messages =
    if Room.is_initialized config then
      Room.get_messages_raw config ~since_seq:0 ~limit:200
    else
      []
  in
  let current_room =
    trim_to_option (string_field "current_room" room_json)
    |> Option.value ~default:"room"
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
         let where =
           match related_session with
           | Some session ->
               compact_text
                 (session.goal
                 ^
                 match session.room with
                 | Some room -> " · " ^ room
                 | None -> "")
           | None -> current_room
         in
         let with_whom =
           match related_session with
           | Some session ->
               session.member_names
               |> List.filter (fun name -> not (String.equal name agent_name))
           | None -> []
         in
         let current_work =
           task_label (Option.bind agent (fun value -> value.current_task))
         in
         let recent_output_preview =
           latest_out |> Option.map (fun (message : Types.message) -> compact_text message.content)
         in
         let recent_input_preview =
           latest_in |> Option.map (fun (message : Types.message) -> compact_text message.content)
         in
         let recent_event =
           related_session |> Option.map (fun session -> session.last_event_summary)
         in
         let status =
           match agent with
           | Some value -> Types.agent_status_to_string value.status
           | None ->
               if Option.is_some related_session then "active" else "unknown"
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
         ({
           status_rank = status_rank status;
           related_attention_count;
           last_seen_ts;
           json =
             `Assoc
               [
                 ("agent_name", `String agent_name);
                 ("status", `String status);
                 ("where", `String where);
                 ("with_whom", `List (List.map (fun value -> `String value) with_whom));
                 ("current_work", json_string_option current_work);
                 ("related_session_id", json_string_option (Option.map (fun s -> s.session_id) related_session));
                 ("related_attention_count", `Int related_attention_count);
                 ("recent_output_preview", json_string_option recent_output_preview);
                 ("recent_input_preview", json_string_option recent_input_preview);
                 ("recent_event", json_string_option recent_event);
                 ("recent_tool_names", `List []);
               ];
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
                   [
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
                   ];
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
           let target_type = string_field "target_type" incident in
           let target_id = trim_to_option (string_field "target_id" incident) in
           let action = matching_action target_type target_id actions in
           let kind = string_field "kind" incident in
           let id =
             Printf.sprintf "attention:%s:%s:%s" kind target_type
               (match target_id with Some value -> value | None -> "none")
           in
           {
             pressure_rank = severity_rank (string_field ~default:"warn" "severity" incident);
             last_seen_ts = 0.0;
             json =
               `Assoc
                 [
                   ("id", `String id);
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
  let internal_incident_targets =
    internal_incidents
    |> List.map (fun row ->
           let attention = member_assoc "attention" row.json in
           ( string_field "target_type" attention,
             trim_to_option (string_field "target_id" attention) ))
  in
  let internal_actions =
    actions
    |> List.filter is_internal_action
    |> List.filter (fun action ->
           let target_id = trim_to_option (string_field "target_id" action) in
           not
             (List.exists
                (fun (incident_target_type, incident_target_id) ->
                  String.equal incident_target_type (string_field "target_type" action)
                  &&
                  match target_id, incident_target_id with
                  | Some left, Some right -> String.equal left right
                  | None, None -> true
                  | _ -> false)
                internal_incident_targets))
    |> List.map (fun action ->
           let action_type = string_field "action_type" action in
           let target_id = trim_to_option (string_field "target_id" action) in
           {
             pressure_rank = severity_rank (string_field ~default:"warn" "severity" action);
             last_seen_ts = 0.0;
             json =
               `Assoc
                 [
                   ("id", `String (Printf.sprintf "action:%s:%s" action_type (Option.value ~default:"none" target_id)));
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

let summarize_queue_counts attention_queue =
  let session_count =
    attention_queue
    |> List.concat_map (fun item -> item.related_session_ids)
    |> dedup_strings
    |> List.length
  in
  let agent_count =
    attention_queue
    |> List.concat_map (fun item -> item.related_agent_names)
    |> dedup_strings
    |> List.length
  in
  `Assoc
    [
      ("count", `Int (List.length attention_queue));
      ("session_count", `Int session_count);
      ("agent_count", `Int agent_count);
    ]

let json ?actor ~config ~sw ~clock ~proc_mgr () =
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
    Operator_control.snapshot_json
      ~actor:actor_name
      ~view:"summary"
      ~include_messages:false
      ~include_sessions:true
      ~include_keepers:true
      ctx
  in
  let digest_json =
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
          ]
  in
  let room_json = member_assoc "room" snapshot_json in
  let command_json = member_assoc "command_plane" digest_json in
  let operations_summary = member_assoc "operations" command_json |> member_assoc "summary" in
  let decisions_summary = member_assoc "decisions" command_json |> member_assoc "summary" in
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
  let agent_briefs = build_agent_briefs config sessions attention_queue room_json in
  let keeper_briefs = build_keeper_briefs snapshot_json in
  let internal_signals = build_internal_signals incidents recommended_actions in
  let summary_json =
    `Assoc
      [
        ("room_health", `String (string_field ~default:"ok" "health" digest_json));
        ("cluster", json_string_option (Some (string_field "cluster" room_json)));
        ("project", json_string_option (Some (string_field "project" room_json)));
        ("current_room", member_assoc "current_room" room_json);
        ("paused", `Bool (bool_field "paused" room_json));
        ("tempo_interval_s", member_assoc "tempo_interval_s" room_json);
        ("active_agents", `Int (active_agent_count config));
        ("keeper_pressure", `Int (keeper_pressure_count snapshot_json));
        ("active_operations", `Int (int_field "active" operations_summary));
        ("pending_approvals", `Int (int_field "pending" decisions_summary));
        ("incident_count", `Int (List.length incidents));
        ("recommended_action_count", `Int (List.length recommended_actions));
        ("top_attention", top_item incidents);
        ("top_action", top_item recommended_actions);
        ("attention_queue", summarize_queue_counts attention_queue);
      ]
  in
  let command_focus_json =
    `Assoc
      [
        ("health", `String (string_field ~default:"ok" "health" digest_json));
        ("active_operations", `Int (int_field "active" operations_summary));
        ("pending_approvals", `Int (int_field "pending" decisions_summary));
        ("swarm_overview", member_assoc "swarm_status" digest_json |> member_assoc "overview");
        ("top_attention", top_item incidents);
        ("top_action", top_item recommended_actions);
        ("session_cards", `List (take 3 session_cards));
      ]
  in
  let operator_targets_json =
    `Assoc
      [
        ("sessions", member_assoc "sessions" snapshot_json |> member_assoc "items");
        ("keepers", member_assoc "keepers" snapshot_json |> member_assoc "items");
        ("pending_confirms", member_assoc "pending_confirms" snapshot_json);
        ("available_actions", member_assoc "available_actions" snapshot_json);
      ]
  in
  `Assoc
    [
      ("generated_at", `String (Types.now_iso ()));
      ("summary", summary_json);
      ("incidents", `List incidents);
      ("recommended_actions", `List recommended_actions);
      ("command_focus", command_focus_json);
      ("operator_targets", operator_targets_json);
      ("attention_queue", `List (List.map (fun (item : attention_context) -> item.json) attention_queue));
      ("session_briefs", `List session_briefs);
      ("agent_briefs", `List agent_briefs);
      ("keeper_briefs", `List keeper_briefs);
      ("internal_signals", `List internal_signals);
    ]
