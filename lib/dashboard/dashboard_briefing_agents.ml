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

let build_task_lookup config =
  if not (Workspace.is_initialized config) then
    []
  else
    Workspace.get_tasks_raw config
    |> List.filter_map (fun (task : Masc_domain.task) ->
           if String.trim task.id = "" then None
           else Some (task.id, Printf.sprintf "%s · %s" task.id (compact_text task.title)))

let latest_message_from agent_name messages =
  let lowered = String.lowercase_ascii (String.trim agent_name) in
  List.fold_left
    (fun best (message : Masc_domain.message) ->
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

let keeper_alias_by_agent_name (keepers : Yojson.Safe.t list) =
  let table = Hashtbl.create 8 in
  List.iter
    (fun keeper ->
      match String_util.trim_nonempty (string_field "name" keeper) with
      | Some keeper_name -> Hashtbl.replace table keeper_name keeper_name
      | None -> ())
    keepers;
  table

let build_agent_briefs config attention_queue (keepers : Yojson.Safe.t list) =
  let now_ts = Time_compat.now () in
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
        match List.assoc_opt id task_lookup with
        | Some label -> Some label
        | None -> Some id)
  in
  let workspace_agents =
    if Workspace.is_initialized config then Workspace.get_agents_raw config else []
  in
  let workspace_agent_by_name =
    workspace_agents
    |> List.map (fun (agent : Masc_domain.agent) -> (agent.name, agent))
  in
  let agent_names =
    dedup_strings (List.map (fun (agent : Masc_domain.agent) -> agent.name) workspace_agents)
  in
  let keeper_aliases = keeper_alias_by_agent_name keepers in
  agent_names
  |> List.map (fun agent_name ->
         let agent = List.assoc_opt agent_name workspace_agent_by_name in
         let related_attention_count =
            attention_queue
            |> List.fold_left
                (fun acc attention ->
                  if List.mem agent_name attention.related_agent_names then acc + 1 else acc)
                0
         in
         let latest_out = latest_message_from agent_name messages in
         let latest_in = latest_message_to agent_name messages in
         let current_work =
           task_label (Option.bind agent (fun value -> value.current_task))
         in
         let display_name =
           Hashtbl.find_opt keeper_aliases agent_name |> Option.value ~default:agent_name
         in
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
  |> List.map (fun (row : agent_context) -> row.json)
