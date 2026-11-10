(** Dashboard_briefing_agents — Agent brief construction and message lookup
    helpers for the dashboard.

    Extracted from dashboard_briefing_assembly to reduce file size. *)

include Dashboard_utils

type attention_context = {
  severity : string;
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

module String_map = Set_util.StringMap

let build_task_lookup config =
  if not (Workspace.is_initialized config) then
    String_map.empty
  else
    Workspace.get_tasks_raw config
    |> List.fold_left
         (fun acc (task : Masc_domain.task) ->
            if String.trim task.id = "" || String_map.mem task.id acc
            then acc
            else
              String_map.add
                task.id
                (Printf.sprintf "%s · %s" task.id (compact_text task.title))
                acc)
         String_map.empty

let latest_message_to agent_name messages =
  let lowered = String.lowercase_ascii (String.trim agent_name) in
  List.fold_left
    (fun best (message : Masc_domain.message) ->
      let from_self = String.equal (String.lowercase_ascii (String.trim message.from_agent)) lowered in
      let mentioned =
        (* Mention identity comes from the message's own mention surface —
           the typed [mention] field plus @word tokens in the body, both via
           {!Dashboard_workspace.mentions_of_message} (the one extractor the
           workspace read model already uses). The [lowered <> ""] guard
           keeps a degenerate agent record with an empty/whitespace name
           (agent_of_yojson accepts "name":"") from matching anything. *)
        String.length lowered > 0
        && List.exists
             (fun target -> String.equal (String.lowercase_ascii target) lowered)
             (Dashboard_workspace.mentions_of_message message)
      in
      if from_self || not mentioned
      then best
      else
        match best with
        | None -> Some message
        | Some current ->
            if message.seq >= current.seq then Some message else best)
    None messages

let index_messages_by_lowered_agent (messages : Masc_domain.message list) =
  let update_newer (message : Masc_domain.message) = function
    | None -> Some message
    | Some (current : Masc_domain.message) ->
      if message.seq >= current.seq then Some message else Some current
  in
  List.fold_left
    (fun (out_by_sender, in_by_target) (message : Masc_domain.message) ->
       let sender_lower = String.lowercase_ascii (String.trim message.from_agent) in
       let out_by_sender =
         String_map.update sender_lower (update_newer message) out_by_sender
       in
       let mentions = Dashboard_workspace.mentions_of_message message in
       let in_by_target =
         List.fold_left
           (fun acc raw_target ->
              let target_lower = String.lowercase_ascii raw_target in
              if String.length target_lower = 0
                 || String.equal target_lower sender_lower
              then acc
              else String_map.update target_lower (update_newer message) acc)
           in_by_target
           mentions
       in
       out_by_sender, in_by_target)
    (String_map.empty, String_map.empty)
    messages

type agent_briefs_observation = {
  json : Yojson.Safe.t list;
  next_deadline_unix : float option;
}

let build_agent_briefs_observation ~now_ts config attention_queue (_keepers : Yojson.Safe.t list) =
  let task_lookup = build_task_lookup config in
  let messages =
    if Workspace.is_initialized config then
      Workspace.get_messages_raw config ~since_seq:0 ~limit:200
    else
      []
  in
  let task_label task_id =
    match task_id with
    | None -> None
    | Some id -> (
        match String_map.find_opt id task_lookup with
        | Some label -> Some label
        | None -> Some id)
  in
  let workspace_agents =
    if Workspace.is_initialized config then Workspace.get_agents_raw config else []
  in
  let workspace_agent_by_name =
    List.fold_left
      (fun acc (agent : Masc_domain.agent) ->
         if String_map.mem agent.name acc
         then acc
         else String_map.add agent.name agent acc)
      String_map.empty
      workspace_agents
  in
  let agent_names =
    dedup_strings (List.map (fun (agent : Masc_domain.agent) -> agent.name) workspace_agents)
  in
  let attention_counts =
    List.fold_left
      (fun acc (attention : attention_context) ->
         let unique_names = dedup_strings attention.related_agent_names in
         List.fold_left
           (fun acc name ->
              let prev = Option.value ~default:0 (String_map.find_opt name acc) in
              String_map.add name (prev + 1) acc)
           acc
           unique_names)
      String_map.empty
      attention_queue
  in
  let latest_out_by_lower, latest_in_by_lower =
    index_messages_by_lowered_agent messages
  in
  let next_deadline_unix = ref None in
  let json = agent_names
  |> List.map (fun agent_name ->
         let agent = String_map.find_opt agent_name workspace_agent_by_name in
         let related_attention_count =
           Option.value ~default:0 (String_map.find_opt agent_name attention_counts)
         in
         let lowered = String.lowercase_ascii (String.trim agent_name) in
         let latest_out = String_map.find_opt lowered latest_out_by_lower in
         let latest_in =
           if String.length lowered = 0
           then None
           else String_map.find_opt lowered latest_in_by_lower
         in
         let current_work =
           task_label (Option.bind agent (fun value -> value.current_task))
         in
         let display_name = agent_name in
         let recent_output_preview =
           latest_out |> Option.map (fun (message : Masc_domain.message) -> compact_text message.content)
         in
         let recent_input_preview =
           latest_in |> Option.map (fun (message : Masc_domain.message) -> compact_text message.content)
         in
         let status =
           match agent with
           | Some value -> Masc_domain.agent_status_to_string value.status
           | None -> ""
         in
         let last_activity_at =
           match agent with
           | Some value -> String_util.trim_nonempty value.last_seen
            | None -> None
         in
         let last_seen_ts =
           match agent with
            | Some value ->
                Dashboard_utils.parse_iso_opt (String_util.trim_nonempty value.last_seen) |> Option.value ~default:0.0
            | None -> 0.0
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
         (match last_activity_age_sec with
          | Some age when age <= 300 ->
              (* The existing truth compares the integer age to 300. Its
                 first different row is at 301, not just above 300. *)
              let deadline = last_seen_ts +. 301.0 in
              if Float.is_finite deadline then
                next_deadline_unix := Some (match !next_deadline_unix with
                  | None -> deadline | Some old -> Float.min old deadline)
          | Some _ | None -> ());
         let evidence_source =
           if Option.is_some latest_out || Option.is_some latest_in then
             "message"
           else if Option.is_some agent then
             "presence"
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
                    Json_util.string_opt_to_json
                      (if Option.is_some agent
                       then None
                       else Some "missing from current workspace state") );
                  ("status", `String status);
                  ("current_work", Json_util.string_opt_to_json current_work);
                  ("last_activity_at", Json_util.string_opt_to_json last_activity_at);
                  ("last_activity_age_sec", Json_util.option_to_yojson (fun value -> `Int value) last_activity_age_sec);
                  ("signal_truth", `String signal_truth);
                  ("evidence_source", `String evidence_source);
                  ("recent_output_preview", Json_util.string_opt_to_json recent_output_preview);
                  ("recent_input_preview", Json_util.string_opt_to_json recent_input_preview);
                ]);
         } : agent_context))
  |> List.sort (fun (left : agent_context) (right : agent_context) ->
         let by_attention = Int.compare right.related_attention_count left.related_attention_count in
         if by_attention <> 0 then by_attention
         else
           let by_status = Int.compare right.status_rank left.status_rank in
           if by_status <> 0 then by_status
           else Float.compare right.last_seen_ts left.last_seen_ts)
  |> List.map (fun (row : agent_context) -> row.json) in
  {json; next_deadline_unix = !next_deadline_unix}

let build_agent_briefs config attention_queue keepers =
  (build_agent_briefs_observation ~now_ts:(Time_compat.now ()) config attention_queue keepers).json
