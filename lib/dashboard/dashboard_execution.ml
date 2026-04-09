include Dashboard_execution_helpers
include Dashboard_execution_fixture
include Dashboard_execution_builders

let room_status_json (config : Room.config) : Yojson.Safe.t =
  let room_state_opt =
    if Room.is_initialized config then Some (Room.read_state config) else None
  in
  let current_namespace = "default" in
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
  `Assoc
    [
      ("namespace_id", `String current_namespace);
      ("current_namespace", `String current_namespace);
      ("namespace_base_path", `String config.base_path);
      ("coordination_root", `String config.base_path);
      ("workspace_path", `String config.workspace_path);
      ("workspace_differs", `Bool (config.workspace_path <> config.base_path));
      ("cluster", `String (Env_config_core.cluster_name ()));
      ("project", `String project);
      ("namespace", `String current_namespace);
      ("namespace_mode", `String "flattened");
      ("tempo_interval_s", `Float tempo.current_interval_s);
      ("paused", `Bool paused);
      ("version", `String Version.version);
    ]

let tasks_safe config =
  if Room.is_initialized config then Room.get_tasks_safe config
  else []

let agents_safe config =
  if Room.is_initialized config then Room.get_active_agents config
  else []

let messages_safe config =
  if Room.is_initialized config then
    Room.get_messages_raw config ~since_seq:0 ~limit:50
  else []


let task_json (task : Types.task) =
  let base =
    [
      ("id", `String task.id);
      ("title", `String task.title);
      ("description", `String task.description);
      ("status", `String (Types.string_of_task_status task.task_status));
      ("priority", `Int task.priority);
      ("assignee", Json_util.string_opt_to_json (task_assignee task));
      ("created_at", `String task.created_at);
    ]
  in
  let extra = match task.task_status with
    | Types.Done { completed_at; _ } ->
      [("completed_at", `String completed_at)]
    | Types.Cancelled { cancelled_at; _ } ->
      [("completed_at", `String cancelled_at)]
    | _ -> []
  in
  `Assoc (base @ extra)

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


(** Maximum wall-clock time for a single dashboard render.
    Keep a real guard for PG stalls, but allow slow cold-start projections
    to finish at least once so cached surfaces can hydrate. *)
let render_timeout_s =
  Dashboard_http_helpers.float_of_env_default
    "MASC_DASHBOARD_EXECUTION_RENDER_TIMEOUT_S"
    ~default:60.0 ~min_v:10.0 ~max_v:300.0

let session_list_timeout_s =
  Dashboard_http_helpers.dashboard_session_list_timeout_s ()

let json_render ~effective_actor ~light ~config ~sw ~clock ~proc_mgr () =
      let ctx : _ Operator_control.context =
        {
          config;
          agent_name = effective_actor;
          sw;
          clock;
          proc_mgr;
          net = None;
          mcp_session_id = None;
        }
      in
      (* Yield between heavy phases so SSE / health-check fibers can progress *)
      Eio.Fiber.yield ();
      let t_start = Time_compat.now () in
      (* Load sessions once; pass to snapshot_json to avoid repeated filesystem scans.
         Only include active (Running/Paused) sessions plus recently finished ones
         (last 24h) to avoid loading all historical sessions on every poll. *)
      (* Pre-filter at filesystem level: only load sessions modified in last 24h.
         This avoids reading all 1400+ historical session files on each poll.
         Active sessions are preserved by list_sessions ~since_unix which does a
         lightweight status check on mtime-excluded dirs (avoids full JSON load). *)
      let cutoff_unix = Time_compat.now () -. Masc_time_constants.day in
      let _session_list_timeout = session_list_timeout_s in
      let all_sessions =
        (* Team_session_store removed — return empty *)
        ignore (config : Room.config);
        ignore _session_list_timeout;
        ([] : Team_session_types.session list)
      in
      let cutoff_iso =
        let tm = Unix.gmtime cutoff_unix in
        Printf.sprintf "%04d-%02d-%02dT%02d:%02d:%02dZ"
          (tm.Unix.tm_year + 1900) (tm.Unix.tm_mon + 1) tm.Unix.tm_mday
          tm.Unix.tm_hour tm.Unix.tm_min tm.Unix.tm_sec
      in
      let is_active_or_recent (s : Team_session_types.session) =
        match s.status with
        | Running | Paused -> true
        | _ -> s.updated_at_iso >= cutoff_iso
      in
      let sessions = List.filter is_active_or_recent all_sessions in
      let t_sessions = Time_compat.now () in
      Eio.Fiber.yield ();
      (* Compute directly without Dashboard_cache to avoid nested
         get_or_compute deadlock — the caller (dashboard_execution_http_json)
         already wraps this entire function in a cache entry. *)
      let snapshot_json =
        Operator_control.snapshot_json
          ~actor:effective_actor
          ~view:"summary"
          ~include_messages:false
          ~include_sessions:true
          ~include_keepers:true
          ~include_summary_fields:false
          ~include_command_plane:false
          ~lightweight_summary:true
          ~sessions
          ctx
      in
      let t_snapshot = Time_compat.now () in
      Eio.Fiber.yield ();
      let session_cards =
        if light then []
        else
          let digest_json =
            match Operator_control.digest_json ~actor:effective_actor ~sessions ctx with
            | Ok json -> json
            | Error _message ->
                `Assoc
                  [
                    ("health", `String "warn");
                    ("attention_items", `List []);
                    ("recommended_actions", `List []);
                    ("session_cards", `List []);
                  ]
          in
          list_field "session_cards" digest_json
      in
      let session_seeds =
        member_assoc "sessions" snapshot_json |> member_assoc "items"
        |> function
        | `List items ->
            items
            |> List.filter_map (fun json -> build_session_seed json session_cards)
        | _ -> []
      in
      let command_plane_json =
        Command_plane_v2.dashboard_projection_json ~sessions config
      in
      (* Yield between heavy computation phases to prevent fiber starvation.
         Eio's cooperative scheduler needs explicit yields in CPU-bound paths
         so other fibers (SSE, health checks) can progress. *)
      Eio.Fiber.yield ();
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
      (* Load tasks/agents/messages — needed for worker_support_briefs.
         In light mode, tasks and messages are NOT serialized in the
         response payload (saves ~143KB) but are still loaded for
         worker_support_briefs computation. *)
      let tasks = tasks_safe config in
      let agents = agents_safe config in
      let messages = messages_safe config in
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
      (* --- Payload size reduction: filter + limit --- *)
      (* Sessions: running/paused first, then by severity, max 15 *)
      let sorted_sessions = List.sort (fun (a : session_context) (b : session_context) ->
        let status_ord (s : session_context) = match string_field_opt "status" s.json with
          | Some "running" -> 0 | Some "paused" -> 1 | _ -> 2 in
        let cmp = compare (status_ord a) (status_ord b) in
        if cmp <> 0 then cmp
        else compare (tone_rank b.severity) (tone_rank a.severity)
      ) session_contexts in
      let limited_sessions = take 15 sorted_sessions in
      (* Operations: only active/paused, max 20 *)
      let active_ops = List.filter (fun (op : operation_context) ->
        let status = string_field_opt "status" op.json in
        status = Some "active" || status = Some "paused"
      ) operation_contexts in
      let limited_ops = take 20 active_ops in
      (* Execution queue: top 10 priority items *)
      let limited_queue = take 10 execution_queue in
      let base_fields =
        [
          ("generated_at", `String (Types.now_iso ()));
          ("status", room_status_json config);
          ("execution_queue", `List (List.map (fun (row : queue_context) -> row.json) limited_queue));
          ("session_briefs", `List (List.map (fun (row : session_context) -> row.json) limited_sessions));
          ("operation_briefs", `List (List.map (fun (row : operation_context) -> row.json) limited_ops));
          ("worker_support_briefs", `List (List.map (fun (row : worker_context) -> row.json) worker_support_briefs));
          ("continuity_briefs", `List (List.map (fun (row : continuity_context) -> row.json) continuity_rows));
          ("offline_worker_briefs", `List (List.map (fun (row : worker_context) -> row.json) offline_worker_briefs));
          ("agents", `List (List.map agent_json agents));
          (* pipeline_stage is now included in the snapshot keepers_json,
             so no redundant read_meta + parse_agent_status needed here. *)
          ("keepers", `List keepers);
        ]
      in
      let now = Time_compat.now () in
      let recent_cutoff = now -. Masc_time_constants.day in (* 24 hours *)
      let active_tasks = List.filter (fun (t : Types.task) ->
        match t.task_status with
        | Types.Done _ | Types.Cancelled _ -> false
        | _ -> true
      ) tasks in
      let recent_done = tasks
        |> List.filter (fun (t : Types.task) ->
          match t.task_status with
          | Types.Done { completed_at; _ } ->
            (match Types.parse_iso8601_opt completed_at with
             | Some ts -> ts >= recent_cutoff
             | None -> false)
          | Types.Cancelled { cancelled_at; _ } ->
            (match Types.parse_iso8601_opt cancelled_at with
             | Some ts -> ts >= recent_cutoff
             | None -> false)
          | _ -> false)
        |> take 20
      in
      let all_visible = active_tasks @ recent_done in
      let limited_tasks = take 50 all_visible in
      let task_fields = [
        ("tasks", `List (List.map task_json limited_tasks));
        ("task_counts", `Assoc [
          ("active", `Int (List.length active_tasks));
          ("done_recent", `Int (List.length recent_done));
          ("total", `Int (List.length tasks));
          ("shown", `Int (List.length limited_tasks));
        ]);
      ] in
      let t_end = Time_compat.now () in
      let total_ms = (t_end -. t_start) *. 1000.0 in
      let sessions_ms = (t_sessions -. t_start) *. 1000.0 in
      let snapshot_ms = (t_snapshot -. t_sessions) *. 1000.0 in
      let render_ms = (t_end -. t_snapshot) *. 1000.0 in
      if total_ms > 10000.0 then
        Log.Dashboard.warn
          "[dashboard_execution] slow render: total=%.0fms sessions=%.0fms snapshot=%.0fms render=%.0fms (sessions=%d keepers=%d)"
          total_ms sessions_ms snapshot_ms render_ms
          (List.length sessions)
          (List.length keepers)
      else
        Log.Dashboard.debug
          "[dashboard_execution] timing: total=%.0fms sessions=%.0fms snapshot=%.0fms render=%.0fms"
          total_ms sessions_ms snapshot_ms render_ms;
      if light then
        `Assoc (base_fields @ task_fields)
      else
        (* Full mode: include messages in addition to tasks *)
        `Assoc
          (base_fields @ task_fields @ [
            ("messages", `List (List.map message_json messages));
          ])

let json ?actor ?fixture ?(light = true) ~config ~sw ~clock ~proc_mgr () =
  let effective_actor = Option.value ~default:"dashboard" actor in
  match dashboard_fixture_name ?fixture () with
  | Some "execution_smoke" -> execution_smoke_fixture_json ()
  | _ ->
    (* Guard: abort render if it exceeds render_timeout_s.
       PG connection failures during render can block fibers for hours
       (observed: 11,018s render on 2026-03-21). *)
    match Eio.Time.with_timeout clock render_timeout_s (fun () ->
      Ok (json_render ~effective_actor ~light ~config ~sw ~clock ~proc_mgr ())
    ) with
    | Ok result -> result
    | Error `Timeout ->
      Log.Dashboard.error "[dashboard_execution] render timed out after %.0fs" render_timeout_s;
      `Assoc [
        ("generated_at", `String (Types.now_iso ()));
        ("error", `String (Printf.sprintf "render timed out after %.0fs" render_timeout_s));
        ("status", room_status_json config);
      ]
