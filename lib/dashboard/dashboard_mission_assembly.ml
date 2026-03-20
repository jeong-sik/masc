(** Dashboard_mission_assembly — agent briefs, keeper briefs, operation contexts,
    session assembly, and timeline rendering for the mission dashboard.

    Extracted from dashboard_mission.ml to reduce file size. *)

include Dashboard_utils

let dedup_strings items =
  List.sort_uniq String.compare
    (List.filter_map trim_to_option items)

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
        (Printf.sprintf "%s%s" (match actor with Some value -> value ^ " \xc2\xb7 " | None -> "") title)
  | None, Some value, _ -> value
  | None, None, Some value -> value
  | None, None, None -> String.map (fun ch -> if ch = '_' then ' ' else ch) event_type

let session_recent_events session_json = list_field "recent_events" session_json

(* Types duplicated from Dashboard_mission to avoid circular dependency. *)
type session_context = {
  session_id : string;
  goal : string;
  created_by : string option;
  origin_kind : string;
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

let keeper_tool_audit_json_fields keeper agent_name =
  let fallback_allowed =
    string_list_of_json (member_assoc "allowed_tool_names" keeper)
  in
  let fallback_latest =
    string_list_of_json (member_assoc "latest_tool_names" keeper)
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

let is_internal_attention incident =
  String.equal (string_field "target_type" incident) "room"

let is_internal_action action =
  String.equal (string_field "target_type" action) "room"

let incident_action_types kind =
  match kind with
  | "spawn_failure_present" -> [ "team_task_inject" ]
  | "detached_actor_present"
  | "empty_note_turn_present"
  | "low_confidence_routing"
  | "routing_escalation_present" -> [ "team_note" ]
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
  | "intent_handoff_ready" -> [ "broadcast" ]
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
      let content = Fs_compat.load_file path in
      String.split_on_char '\n' content
      |> List.filter (fun s -> s <> "")
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

let keeper_alias_by_agent_name (keepers : Yojson.Safe.t list) =
  let table = Hashtbl.create 8 in
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

let build_agent_briefs config sessions attention_queue _room_json (keepers : Yojson.Safe.t list) =
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
  let keeper_aliases = keeper_alias_by_agent_name keepers in
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

let build_keeper_briefs (keepers : Yojson.Safe.t list) =
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
               ("created_by", json_string_option session.created_by);
               ("origin_kind", `String session.origin_kind);
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
