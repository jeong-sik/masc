(** Tool_agent_timeline - Unified agent activity timeline.

    Collects events from multiple data sources and merges them into
    a single chronological timeline for a given agent.

    Data sources:
    - Agent join status (Room.get_agents_raw)
    - Task state transitions (Room.get_tasks_raw)
    - Broadcast messages (Room.get_messages_raw)
*)

open Tool_args

type result = bool * string

type context = {
  config : Room.config;
  agent_name : string;
}

(* ISO timestamp parsing (reuses Dashboard logic) *)
let parse_iso_timestamp (s : string) : float option =
  try
    let open Scanf in
    sscanf s "%d-%d-%dT%d:%d:%d" (fun y m d h min sec ->
        let tm =
          {
            Unix.tm_sec = sec;
            tm_min = min;
            tm_hour = h;
            tm_mday = d;
            tm_mon = m - 1;
            tm_year = y - 1900;
            tm_wday = 0;
            tm_yday = 0;
            tm_isdst = false;
          }
        in
        let (local_t, _) = Unix.mktime tm in
        let utc_tm = Unix.gmtime local_t in
        let (utc_as_local, _) = Unix.mktime utc_tm in
        let tz_offset = local_t -. utc_as_local in
        Some (local_t -. tz_offset))
  with Scanf.Scan_failure _ | Failure _ | End_of_file -> None

(* Event type for the unified timeline *)
type timeline_event = {
  ts : float;
  ts_iso : string;
  event_type : string;
  detail : Yojson.Safe.t;
}

let event_to_json (e : timeline_event) : Yojson.Safe.t =
  `Assoc
    [
      ("ts", `String e.ts_iso);
      ("type", `String e.event_type);
      ("detail", e.detail);
    ]

(* Collect agent join/status events *)
let agent_events (config : Room.config) ~agent_name :
    timeline_event list =
  let agents = Room.get_active_agents config in
  agents
  |> List.filter (fun (a : Types.agent) -> String.equal a.name agent_name)
  |> List.filter_map (fun (a : Types.agent) ->
         match parse_iso_timestamp a.joined_at with
         | Some ts ->
             Some
               {
                 ts;
                 ts_iso = a.joined_at;
                 event_type = "joined";
                 detail =
                   `Assoc
                     [
                       ("room", `String "default");
                       ( "status",
                         `String (Types.agent_status_to_string a.status) );
                       ( "current_task",
                         match a.current_task with
                         | Some t -> `String t
                         | None -> `Null );
                     ];
               }
         | None -> None)

(* Collect task-related events for an agent *)
let task_events (config : Room.config) ~agent_name :
    timeline_event list =
  let tasks = Room.get_tasks_safe config in
  tasks
  |> List.filter_map (fun (task : Types.task) ->
         match task.task_status with
         | Types.Claimed { assignee; claimed_at }
           when String.equal assignee agent_name -> (
             match parse_iso_timestamp claimed_at with
             | Some ts ->
                 Some
                   {
                     ts;
                     ts_iso = claimed_at;
                     event_type = "task_claimed";
                     detail =
                       `Assoc
                         [
                           ("task_id", `String task.id);
                           ("title", `String task.title);
                           ("priority", `Int task.priority);
                         ];
                   }
             | None -> None)
         | Types.InProgress { assignee; started_at }
           when String.equal assignee agent_name -> (
             match parse_iso_timestamp started_at with
             | Some ts ->
                 Some
                   {
                     ts;
                     ts_iso = started_at;
                     event_type = "task_started";
                     detail =
                       `Assoc
                         [
                           ("task_id", `String task.id);
                           ("title", `String task.title);
                           ("priority", `Int task.priority);
                         ];
                   }
             | None -> None)
         | Types.Done { assignee; completed_at; notes }
           when String.equal assignee agent_name -> (
             match parse_iso_timestamp completed_at with
             | Some ts ->
                 Some
                   {
                     ts;
                     ts_iso = completed_at;
                     event_type = "task_completed";
                     detail =
                       `Assoc
                         [
                           ("task_id", `String task.id);
                           ("title", `String task.title);
                           ("priority", `Int task.priority);
                           ( "notes",
                             match notes with
                             | Some n -> `String n
                             | None -> `Null );
                         ];
                   }
             | None -> None)
         | Types.Cancelled { cancelled_by; cancelled_at; reason }
           when String.equal cancelled_by agent_name -> (
             match parse_iso_timestamp cancelled_at with
             | Some ts ->
                 Some
                   {
                     ts;
                     ts_iso = cancelled_at;
                     event_type = "task_cancelled";
                     detail =
                       `Assoc
                         [
                           ("task_id", `String task.id);
                           ("title", `String task.title);
                           ( "reason",
                             match reason with
                             | Some r -> `String r
                             | None -> `Null );
                         ];
                   }
             | None -> None)
         | _ -> None)

(* Collect broadcast messages from agent *)
let message_events (config : Room.config) ~agent_name ~limit :
    timeline_event list =
  let messages =
    Room.get_messages_raw config ~since_seq:0 ~limit
  in
  messages
  |> List.filter (fun (m : Types.message) ->
         String.equal m.from_agent agent_name)
  |> List.filter_map (fun (m : Types.message) ->
         match parse_iso_timestamp m.timestamp with
         | Some ts ->
             Some
               {
                 ts;
                 ts_iso = m.timestamp;
                 event_type = "broadcast";
                 detail =
                   `Assoc
                     [
                       ("content", `String m.content);
                       ("type", `String m.msg_type);
                       ( "mention",
                         match m.mention with
                         | Some target -> `String target
                         | None -> `Null );
                     ];
               }
         | None -> None)

(* Collect tool call events from Activity Graph *)
let tool_call_events (config : Room.config) ~agent_name ~limit :
    timeline_event list =
  let rec take n xs =
    match (n, xs) with
    | n, _ when n <= 0 -> []
    | _, [] -> []
    | n, x :: rest -> x :: take (n - 1) rest
  in
  (* `list_events` limits globally before we filter by actor, so fetch a
     wider bounded window to reduce the chance that busy-room activity from
     other agents crowds out this agent's tool events. *)
  let scan_limit =
    let expanded = if limit <= 0 then 0 else limit * 10 in
    min 1000 (max limit expanded)
  in
  let all_events =
    Activity_graph.list_events config
      ~kinds:["tool.called"] ~after_seq:0 ~limit:scan_limit ()
  in
  all_events
  |> List.filter (fun (e : Activity_graph.event) ->
       match e.actor with
       | Some a -> String.equal a.id agent_name
       | None -> false)
  |> List.filter_map (fun (e : Activity_graph.event) ->
       let ts = Float.of_int e.ts_ms /. 1000.0 in
       let open Yojson.Safe.Util in
       let tool_name =
         try e.payload |> member "tool_name" |> to_string
         with Eio.Cancel.Cancelled _ as e -> raise e | _ -> "unknown"
       in
       let success =
         try e.payload |> member "success" |> to_bool
         with Eio.Cancel.Cancelled _ as e -> raise e | _ -> true
       in
       let duration_ms =
         try e.payload |> member "duration_ms" |> to_int
         with Eio.Cancel.Cancelled _ as e -> raise e | _ -> 0
       in
       let error_str =
         try match e.payload |> member "error" with
             | `String s -> Some s | _ -> None
         with Eio.Cancel.Cancelled _ as e -> raise e | _ -> None
       in
       Some
         {
           ts;
           ts_iso = e.ts_iso;
           event_type = "tool_call";
           detail =
             `Assoc
               [
                 ("tool_name", `String tool_name);
                 ("success", `Bool success);
                 ("duration_ms", `Int duration_ms);
                 ("error", match error_str with
                           | Some s -> `String s | None -> `Null);
               ];
         })
  |> take limit

(* Build the full timeline *)
let build_timeline (config : Room.config) ~agent_name ~since_hours ~limit
    ~include_tasks ~include_board:_ ~include_tool_calls =
  let now = Time_compat.now () in
  let cutoff = now -. (since_hours *. 3600.0) in
  (* Collect events from the default namespace. *)
  let all_events =
    let agent_evts = agent_events config ~agent_name in
    let task_evts =
      if include_tasks then task_events config ~agent_name
      else []
    in
    let msg_evts = message_events config ~agent_name ~limit:200 in
    let tool_evts =
      if include_tool_calls then tool_call_events config ~agent_name ~limit:200
      else []
    in
    agent_evts @ task_evts @ msg_evts @ tool_evts
  in
  (* Filter by time cutoff and sort chronologically *)
  let filtered =
    all_events
    |> List.filter (fun e -> e.ts >= cutoff)
    |> List.sort (fun a b -> compare a.ts b.ts)
  in
  (* Truncate to limit — keep the most recent events (tail of sorted list) *)
  let events =
    let len = List.length filtered in
    if len > limit then
      let drop = len - limit in
      let rec skip n = function
        | [] -> []
        | _ :: rest when n > 0 -> skip (n - 1) rest
        | remaining -> remaining
      in
      skip drop filtered
    else filtered
  in
  (* Compute summary *)
  let tasks_completed =
    List.length
      (List.filter
         (fun e -> String.equal e.event_type "task_completed")
         events)
  in
  let tasks_claimed =
    List.length
      (List.filter
         (fun e -> String.equal e.event_type "task_claimed")
         events)
  in
  let messages_sent =
    List.length
      (List.filter (fun e -> String.equal e.event_type "broadcast") events)
  in
  let tool_calls =
    List.length
      (List.filter (fun e -> String.equal e.event_type "tool_call") events)
  in
  (* Active duration: time between first and last event *)
  let active_duration_minutes =
    match (events, List.rev events) with
    | first :: _, last :: _ ->
        let diff = last.ts -. first.ts in
        Float.round (diff /. 60.0)
    | _ -> 0.0
  in
  let since_iso =
    let tm = Unix.gmtime cutoff in
    Printf.sprintf "%04d-%02d-%02dT%02d:%02d:%02dZ"
      (tm.Unix.tm_year + 1900)
      (tm.Unix.tm_mon + 1) tm.Unix.tm_mday tm.Unix.tm_hour tm.Unix.tm_min
      tm.Unix.tm_sec
  in
  let now_iso = Types.now_iso () in
  `Assoc
    [
      ("agent", `String agent_name);
      ( "period",
        `Assoc [ ("from", `String since_iso); ("to", `String now_iso) ] );
      ("events", `List (List.map event_to_json events));
      ( "summary",
        `Assoc
          [
            ("tasks_completed", `Int tasks_completed);
            ("tasks_claimed", `Int tasks_claimed);
            ("messages_sent", `Int messages_sent);
            ("tool_calls", `Int tool_calls);
            ("active_duration_minutes", `Float active_duration_minutes);
            ("total_events", `Int (List.length events));
          ] );
    ]

(* Schema for MCP tool registration *)
let schemas : Types.tool_schema list =
  [
    {
      name = "masc_agent_timeline";
      description =
        "Unified timeline of an agent's activity in the currently selected room \
         across tasks, messages, and joins.";
      input_schema =
        `Assoc
          [
            ("type", `String "object");
            ( "properties",
              `Assoc
                [
                  ( "agent_name",
                    `Assoc
                      [
                        ("type", `String "string");
                        ("description", `String "Agent name to query");
                      ] );
                  ( "since_hours",
                    `Assoc
                      [
                        ("type", `String "number");
                        ( "description",
                          `String "Look back N hours (default: 24)" );
                      ] );
                  ( "limit",
                    `Assoc
                      [
                        ("type", `String "integer");
                        ( "description",
                          `String "Max events to return (default: 50)" );
                      ] );
                  ( "include_tasks",
                    `Assoc
                      [
                        ("type", `String "boolean");
                        ( "description",
                          `String
                            "Include task state changes (default: true)" );
                      ] );
                  ( "include_board",
                    `Assoc
                      [
                        ("type", `String "boolean");
                        ( "description",
                          `String
                            "Include board activity (default: false, \
                             reserved)" );
                      ] );
                  ( "include_tool_calls",
                    `Assoc
                      [
                        ("type", `String "boolean");
                        ( "description",
                          `String
                            "Include tool call events from Activity Graph \
                             (default: true)" );
                      ] );
                ] );
            ("required", `List [ `String "agent_name" ]);
          ];
    };
  ]

(* Handler *)
let handle_agent_timeline (ctx : context) args : result =
  let agent_name = get_string args "agent_name" "" in
  if String.length agent_name = 0 then
    (false, "agent_name is required")
  else
    let since_hours = get_float args "since_hours" 24.0 in
    let limit = get_int args "limit" 50 in
    let include_tasks = get_bool args "include_tasks" true in
    let include_board = get_bool args "include_board" false in
    let include_tool_calls = get_bool args "include_tool_calls" true in
    let json =
      build_timeline ctx.config ~agent_name ~since_hours ~limit ~include_tasks
        ~include_board ~include_tool_calls
    in
    (true, Yojson.Safe.to_string json)

(* Dispatch *)
let dispatch (ctx : context) ~name ~args : result option =
  match name with
  | "masc_agent_timeline" -> Some (handle_agent_timeline ctx args)
  | _ -> None

(* ================================================================ *)
(* Tool_spec registration                                           *)
(* ================================================================ *)

let () =
  List.iter
    (fun (s : Types.tool_schema) ->
      Tool_spec.register
        (Tool_spec.create
           ~name:s.name
           ~description:s.description
           ~module_tag:Tool_dispatch.Mod_agent_timeline
           ~input_schema:s.input_schema
           ~handler_binding:Tag_dispatch
           ()))
    schemas
