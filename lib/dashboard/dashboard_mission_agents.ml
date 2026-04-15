(** Dashboard_mission_agents — Agent brief construction, archived agent metadata,
    and message lookup helpers for the mission dashboard.

    Extracted from dashboard_mission_assembly to reduce file size. *)

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
        (Printf.sprintf "%s%s" (match actor with Some value -> value ^ " \xc2\xb7 " | None -> "") title)
  | None, Some value, _, _ -> value
  | None, None, Some value, _ -> value
  | None, None, None, Some value -> value
  | None, None, None, None -> String.map (fun ch -> if ch = '_' then ' ' else ch) event_type

let session_recent_events session_json = list_field "recent_events" session_json

(* Types duplicated from Dashboard_mission to avoid circular dependency. *)
type session_context = {
  session_id : string;
  goal : string;
  created_by : string option;
  origin_kind : string;
  namespace : string option;
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
  (** [None] when status field missing or unparseable ("unknown" in source). *)
  status : Cp_types.operation_status option;
  stage : string option;
  (** [None] when no detachment attached, or detachment status missing. *)
  detachment_status : Cp_types.detachment_status option;
  objective : string option;
  updated_at : string option;
}

type archived_agent_meta = {
  last_event_at : string option;
}

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

let is_session_concluded (status : string) =
  match Dashboard_utils.session_lifecycle_of_string status with
  | Dashboard_utils.SL_completed | SL_interrupted | SL_cancelled -> true
  | SL_active | SL_running | SL_paused | SL_failed | SL_stopped | SL_expired | SL_unknown -> false

let status_of_archived_session (session : session_context option) =
  match session with
  | Some session ->
      if is_session_concluded session.status then "inactive" else "offline"
  | None -> "unknown"

let archived_reason_for_session (session : session_context option) =
  match session with
  | Some session ->
      Some
        (if is_session_concluded session.status
         then "not in current namespace state"
         else "missing from current namespace state")
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
