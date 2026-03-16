include Dashboard_execution_helpers
include Dashboard_execution_fixture
include Dashboard_execution_builders

let room_status_json (config : Room.config) : Yojson.Safe.t =
  let room_state_opt =
    if Room.is_initialized config then Some (Room.read_state config) else None
  in
  let current_room = Room.current_room_id config in
  let project =
    match room_state_opt with
    | Some room_state -> room_state.project
    | None -> "default"
  in
  let paused =
    match room_state_opt with
    | Some room_state -> room_state.paused
    | None -> false
  in
  let tempo = Tempo.get_tempo config in
  let lodge_json = Lodge_heartbeat.(lodge_status () |> lodge_status_to_json) in
  let social_runtime_json = Social_runtime.status_json ~config in
  `Assoc
    [
      ("room", `String current_room);
      ("room_base_path", `String config.base_path);
      ("cluster", `String (Option.value ~default:"unknown" (Sys.getenv_opt "MASC_CLUSTER_NAME")));
      ("project", `String project);
      ("current_room", `String current_room);
      ("tempo_interval_s", `Float tempo.current_interval_s);
      ("paused", `Bool paused);
      ("lodge", lodge_json);
      ("social_runtime", social_runtime_json);
      ("version", `String Version.version);
    ]

let current_room_id config =
  Room.current_room_id config

let tasks_safe config =
  if Room.is_initialized config then Room.get_tasks_raw_in_room config (current_room_id config)
  else []

let agents_safe config =
  if Room.is_initialized config then Room.get_agents_raw_in_room config (current_room_id config)
  else []

let messages_safe config =
  if Room.is_initialized config then
    Room.get_messages_raw_in_room config ~room_id:(current_room_id config) ~since_seq:0
      ~limit:50
  else []


let task_json (task : Types.task) =
  `Assoc
    [
      ("id", `String task.id);
      ("title", `String task.title);
      ("description", `String task.description);
      ("status", `String (Types.string_of_task_status task.task_status));
      ("priority", `Int task.priority);
      ("assignee", (match task_assignee task with Some value -> `String value | None -> `Null));
      ("created_at", `String task.created_at);
    ]

let agent_json (agent : Types.agent) =
  let (emoji, korean_name) = get_agent_identity agent.name in
  `Assoc
    [
      ("name", `String agent.name);
      ("agent_type", `String agent.agent_type);
      ("status", `String (Types.string_of_agent_status agent.status));
      ( "current_task",
        match agent.current_task with
        | Some task -> `String task
        | None -> `Null );
      ("joined_at", `String agent.joined_at);
      ("last_seen", `String agent.last_seen);
      ("capabilities", `List (List.map (fun value -> `String value) agent.capabilities));
      ("emoji", `String emoji);
      ("koreanName", `String korean_name);
      ("model", `Null);
    ]

let message_json (message : Types.message) =
  `Assoc
    [
      ("from", `String message.from_agent);
      ("content", `String message.content);
      ("timestamp", `String message.timestamp);
      ("seq", `Int message.seq);
    ]


let json ?actor ?fixture ~config ~sw ~clock ~proc_mgr () =
  let effective_actor = Option.value ~default:"dashboard" actor in
  match dashboard_fixture_name ?fixture () with
  | Some "execution_smoke" -> execution_smoke_fixture_json ()
  | _ ->
      let tasks = tasks_safe config in
      let agents = agents_safe config in
      let messages = messages_safe config in
      let ctx : _ Operator_control.context =
        {
          config;
          agent_name = effective_actor;
          sw;
          clock;
          proc_mgr;
          mcp_session_id = None;
        }
      in
      (* Yield between heavy phases so SSE / health-check fibers can progress *)
      Eio.Fiber.yield ();
      (* Load sessions once; pass to snapshot_json to avoid repeated filesystem scans *)
      let sessions =
        if Room.is_initialized config then
          Team_session_store.list_sessions config
        else []
      in
      Eio.Fiber.yield ();
      let snapshot_json =
        Dashboard_cache.get_or_compute
          (Printf.sprintf "snapshot:%s" effective_actor)
          ~ttl:3.0
          (fun () ->
            Operator_control.snapshot_json
              ~actor:effective_actor
              ~view:"summary"
              ~include_messages:false
              ~include_sessions:true
              ~include_keepers:true
              ~sessions
              ctx)
      in
      Eio.Fiber.yield ();
      let digest_json =
        Dashboard_cache.get_or_compute
          (Printf.sprintf "digest:%s" effective_actor)
          ~ttl:5.0
          (fun () ->
            match Operator_control.digest_json ~actor:effective_actor ctx with
            | Ok json -> json
            | Error message ->
                `Assoc
                  [
                    ("health", `String "warn");
                    ("attention_items", `List []);
                    ("recommended_actions", `List []);
                    ("session_cards", `List []);
                    ("error", `String message);
                  ])
      in
      let session_cards = list_field "session_cards" digest_json in
      let session_seeds =
        member_assoc "sessions" snapshot_json |> member_assoc "items"
        |> function
        | `List items ->
            items
            |> List.filter_map (fun json -> build_session_seed json session_cards)
        | _ -> []
      in
      (* Yield between heavy computation phases to prevent fiber starvation.
         Eio's cooperative scheduler needs explicit yields in CPU-bound paths
         so other fibers (SSE, health checks) can progress. *)
      Eio.Fiber.yield ();
      let command_plane_json = member_assoc "command_plane" snapshot_json in
      let operation_contexts = build_operation_contexts command_plane_json in
      let session_contexts =
        build_session_contexts session_seeds operation_contexts
      in
      let execution_queue =
        build_execution_queue session_contexts operation_contexts
      in
      let keepers =
        member_assoc "keepers" snapshot_json |> member_assoc "items"
        |> function
        | `List items -> items
        | _ -> []
      in
      Eio.Fiber.yield ();
      let now_ts = Time_compat.now () in
      let worker_rows =
        build_worker_support_briefs ~now_ts ~tasks ~agents ~messages session_contexts
      in
      let offline_worker_briefs, worker_support_briefs =
        List.partition
          (fun (row : worker_context) ->
             string_field "state" row.json = "offline")
          worker_rows
      in
      let continuity_rows =
        build_continuity_briefs ~now_ts keepers session_contexts
      in
      let social_tick_json, social_checkins =
        Social_runtime.execution_json ~config
      in
      let social_tick_summary =
        social_tick_json |> member_assoc "summary"
      in
      `Assoc
        [
          ("generated_at", `String (Types.now_iso ()));
          ("status", room_status_json config);
          ("social_tick", social_tick_summary);
          ("social_checkins", `List social_checkins);
          ("lodge_tick", social_tick_summary);
          ("lodge_checkins", `List social_checkins);
          ("execution_queue", `List (List.map (fun (row : queue_context) -> row.json) execution_queue));
          ("priority_queue", `List (List.map (fun (row : queue_context) -> row.json) execution_queue));
          ("session_briefs", `List (List.map (fun (row : session_context) -> row.json) session_contexts));
          ("operation_briefs", `List (List.map (fun (row : operation_context) -> row.json) operation_contexts));
          ("worker_support_briefs", `List (List.map (fun (row : worker_context) -> row.json) worker_support_briefs));
          ("worker_briefs", `List (List.map (fun (row : worker_context) -> row.json) worker_support_briefs));
          ("continuity_briefs", `List (List.map (fun (row : continuity_context) -> row.json) continuity_rows));
          ("offline_worker_briefs", `List (List.map (fun (row : worker_context) -> row.json) offline_worker_briefs));
          ("agents", `List (List.map agent_json agents));
          ("tasks", `List (List.map task_json tasks));
          ("messages", `List (List.map message_json messages));
          ("keepers", `List keepers);
        ]
