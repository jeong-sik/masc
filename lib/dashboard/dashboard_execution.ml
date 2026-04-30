include Dashboard_execution_helpers
include Dashboard_execution_fixture
include Dashboard_execution_builders

let room_status_json (config : Coord.config) : Yojson.Safe.t =
  let room_state_opt =
    if Coord.is_initialized config then Some (Coord.read_state config) else None
  in
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
      ("coordination_root", `String config.base_path);
      ("workspace_path", `String config.workspace_path);
      ("workspace_differs", `Bool (config.workspace_path <> config.base_path));
      ("cluster", `String (Env_config_core.cluster_name ()));
      ("project", `String project);
      ("tempo_interval_s", `Float tempo.current_interval_s);
      ("paused", `Bool paused);
      ("version", `String Version.version);
    ]

let tasks_safe config =
  if Coord.is_initialized config then Coord.get_tasks_safe config
  else []

let agents_safe config =
  if Coord.is_initialized config then Coord.get_active_agents config
  else []

let messages_safe config =
  if Coord.is_initialized config then
    Coord.get_messages_raw config ~since_seq:0 ~limit:50
  else []

let assoc_upsert fields key value =
  (key, value) :: List.remove_assoc key fields

let compact_keeper_trust_json ~(config : Coord.config) ~(meta : Keeper_types.keeper_meta) =
  let runtime_trust =
    Keeper_runtime_trust_snapshot.snapshot_json ~config ~meta
  in
  let member key = Yojson.Safe.Util.member key runtime_trust in
  `Assoc
    [
      ("disposition", member "disposition");
      ("disposition_reason", member "disposition_reason");
      ("needs_attention", member "needs_attention");
      ("attention_reason", member "attention_reason");
      ("next_human_action", member "next_human_action");
      ("approval_state", member "approval");
      ("execution_summary", member "execution");
      ("latest_causal_event", member "latest_causal_event");
    ]

(* #10710: bound on the per-render enrich fan-out. Code constant per
   [feedback_no-hyperparameter-as-env-knob] — the calibrated value
   should not be operator-tunable. 8 is empirically just past the
   point of diminishing returns on disk-bound enrich workloads on
   laptop-class hardware (per-keeper enrich is ~70% I/O wait), and
   keeps the dashboard render's fd/fiber footprint within budget
   even under fleet expansion. Raise only with a benchmark. *)
let dashboard_enrich_max_fibers = 8

(** #9766: per-render phase timing record used to surface a breakdown
    in the [slow render] WARN.  Pure values so a unit test can pin
    the formatting / per-keeper averaging without booting Eio. *)
type render_phase_timings_ms = {
  total_ms : float;
  snapshot_ms : float;
  operations_ms : float;
  enrich_ms : float;
  data_load_ms : float;
  assemble_ms : float;
  n_keepers : int;
}

let per_keeper_enrich_ms (t : render_phase_timings_ms) =
  if t.n_keepers > 0 then t.enrich_ms /. float_of_int t.n_keepers else 0.0

let format_slow_render_timings (t : render_phase_timings_ms) =
  Printf.sprintf
    "total=%.0fms (keepers=%d) snapshot=%.0fms operations=%.0fms \
     enrich=%.0fms (per_keeper=%.0fms) data_load=%.0fms assemble=%.0fms"
    t.total_ms
    t.n_keepers
    t.snapshot_ms
    t.operations_ms
    t.enrich_ms
    (per_keeper_enrich_ms t)
    t.data_load_ms
    t.assemble_ms

let enrich_keeper_with_diagnostic ~(config : Coord.config) (keeper_json : Yojson.Safe.t) =
  let open Yojson.Safe.Util in
  match keeper_json with
  | `Assoc fields -> (
      match member "name" keeper_json with
      | `String name -> (
          match Keeper_types.read_meta_resolved config name with
          | Ok (Some (_resolved_name, meta)) ->
              let keepalive_running =
                match member "keepalive_running" keeper_json with
                | `Bool value -> value
                | _ -> Keeper_status_bridge.runtime_keepalive_running config meta
              in
              let now_ts = Time_compat.now () in
              let diagnostic =
                Keeper_exec_status.keeper_diagnostic_json
                  ~meta
                  ~agent_status:(member "agent" keeper_json)
                  ~keepalive_running
                  ~history_items:[]
                  ~now_ts
                |> Keeper_exec_status.augment_keeper_diagnostic_json
                     ~meta
                     ~keepalive_running
                     ~keepalive_started_at:
                       (Keeper_status_bridge.runtime_keepalive_started_at config meta)
                     ~now_ts
              in
              let trust =
                try compact_keeper_trust_json ~config ~meta
                with exn ->
                  Log.Dashboard.warn
                    "dashboard_execution trust enrich failed for keeper %s: %s"
                    meta.name (Printexc.to_string exn);
                  `Null
              in
              let fields = assoc_upsert fields "diagnostic" diagnostic in
              let fields = assoc_upsert fields "trust" trust in
              `Assoc fields
          | Ok None | Error _ -> keeper_json)
      | _ -> keeper_json)
  | _ -> keeper_json

let model_map_of_keeper_rows keepers =
  let model_map : (string, string) Hashtbl.t = Hashtbl.create 8 in
  let open Yojson.Safe.Util in
  List.iter
    (function
      | `Assoc _ as keeper_json -> (
          match member "name" keeper_json, member "active_model" keeper_json with
          | `String _, `String _ | `String _, _ | _, `String _ | _, _ -> ())
      | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _ -> ())
    keepers;
  model_map


let task_updated_at (task : Types.task) =
  match task.task_status with
  | Types.Done { completed_at; _ } -> completed_at
  | Types.Cancelled { cancelled_at; _ } -> cancelled_at
  | Types.InProgress { started_at; _ } -> started_at
  | Types.AwaitingVerification { submitted_at; _ } -> submitted_at
  | Types.Claimed { claimed_at; _ } -> claimed_at
  | Types.Todo -> task.created_at

let task_completed_at (task : Types.task) =
  match task.task_status with
  | Types.Done { completed_at; _ } -> Some completed_at
  | Types.Cancelled { cancelled_at; _ } -> Some cancelled_at
  | Types.Todo | Types.Claimed _ | Types.InProgress _
  | Types.AwaitingVerification _ -> None

let task_execution_links_json (task : Types.task) =
  match task.contract with
  | Some contract -> Types.task_execution_links_to_yojson contract.links
  | None -> `Null

let task_json (task : Types.task) =
  let fields =
    match Types.task_to_yojson task with
    | `Assoc assoc -> assoc
    | _ -> []
  in
  let fields =
    assoc_upsert fields "assignee"
      (Json_util.string_opt_to_json (task_assignee task))
  in
  let fields =
    assoc_upsert fields "updated_at" (`String (task_updated_at task))
  in
  let fields =
    assoc_upsert fields "execution_links" (task_execution_links_json task)
  in
  let fields =
    match task_completed_at task with
    | Some timestamp -> assoc_upsert fields "completed_at" (`String timestamp)
    | None -> List.remove_assoc "completed_at" fields
  in
  `Assoc fields

let agent_json ~(model_map : (string, string) Hashtbl.t) (agent : Types.agent) =
  let (emoji, korean_name) = get_agent_identity agent.name in
  let model_value =
    match Hashtbl.find_opt model_map agent.name with
    | Some m when m <> "" -> `String m
    | _ -> `Null
  in
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
      ("model", model_value);
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
    to finish at least once so cached surfaces can hydrate. The default
    (60s) is preserved by [Env_config_runtime.Dashboard.render_timeout_sec];
    operators can override via [MASC_DASHBOARD_RENDER_TIMEOUT_SEC]. *)
let render_timeout_s = Env_config_runtime.Dashboard.render_timeout_sec

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
      let snapshot_json =
        Dashboard_projection_cache.get_or_compute_snapshot_json
          ~config ~actor:(Some effective_actor) (fun actor_name ->
            Operator_control.snapshot_json
              ~actor:actor_name
              ~view:"summary"
              ~include_messages:false
              ~include_keepers:true
              ~include_summary_fields:false
              ~lightweight_summary:true
              ctx)
      in
      let t_after_snapshot = Time_compat.now () in
      Eio.Fiber.yield ();
      (* Yield between heavy computation phases to prevent fiber starvation.
         Eio's cooperative scheduler needs explicit yields in CPU-bound paths
         so other fibers (SSE, health checks) can progress. *)
      Eio.Fiber.yield ();
      let tasks = tasks_safe config in
      let operation_contexts = build_operation_contexts ~tasks in
      let session_contexts = [] in
      let execution_queue =
        build_execution_queue session_contexts operation_contexts
      in
      let t_after_operations = Time_compat.now () in
      let keepers =
        member_assoc "keepers" snapshot_json |> member_assoc "items"
        |> function
        | `List items ->
            (* #10710: enrich_keeper_with_diagnostic was being run as
               [List.map _ items] — strict N+1 against the keeper list.
               Field log: 14 keepers * 2.4s/keeper = 33s render walltime
               (4 of 11 slow renders had enrich at 70-99% of total).
               [enrich_keeper_with_diagnostic] reads each keeper's meta
               from its own file and computes per-keeper diagnostic JSON
               with no shared mutable state, so the work is embarrassingly
               parallel.

               [Eio.Fiber.List.map ~max_fibers] runs the enrich body
               cooperatively across a bounded fiber pool. The cap
               ([dashboard_enrich_max_fibers]) is intentionally below
               typical fleet size (14 today, growing) so we never burn
               more file descriptors / scheduler slots than the dashboard
               render strictly needs; raising it past ~8 buys little for
               disk-bound enrich workloads on a laptop and just makes the
               scheduler quantum thrash. *)
            Eio.Fiber.List.map
              ~max_fibers:dashboard_enrich_max_fibers
              (enrich_keeper_with_diagnostic ~config)
              items
        | _ -> []
      in
      let t_after_enrich = Time_compat.now () in
      Eio.Fiber.yield ();
      (* Load tasks/agents/messages — needed for worker_support_briefs.
         In light mode, tasks and messages are NOT serialized in the
         response payload (saves ~143KB) but are still loaded for
         worker_support_briefs computation. *)
      let agents = agents_safe config in
      let messages = messages_safe config in
      let t_after_data_load = Time_compat.now () in
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
          ("operation_briefs", `List (List.map (fun (row : operation_context) -> row.json) limited_ops));
          ("worker_support_briefs", `List (List.map (fun (row : worker_context) -> row.json) worker_support_briefs));
          ("continuity_briefs", `List (List.map (fun (row : continuity_context) -> row.json) continuity_rows));
          ("offline_worker_briefs", `List (List.map (fun (row : worker_context) -> row.json) offline_worker_briefs));
          ("agents",
           let model_map = model_map_of_keeper_rows keepers in
           `List (List.map (agent_json ~model_map) agents));
          (* pipeline_stage is now included in the snapshot keepers_json,
             so no redundant read_meta + parse_agent_status needed here. *)
          ("keepers", `List keepers);
        ]
      in
      let now = Time_compat.now () in
      let recent_cutoff = now -. Masc_time_constants.day in (* 24 hours *)
      let active_tasks = List.filter (fun (t : Types.task) ->
        not (Types.task_status_is_terminal t.task_status)
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
      (* Cap removed (2026-04-16): active_tasks is already bounded by
         how many tasks exist in state, and recent_done is capped at 20
         above. The previous [take 50] silently truncated the backlog in
         the dashboard planning view at exactly 50 entries, which surfaced
         as a "total tasks = 50" bug once the real backlog exceeded that
         number. The raw list is surfaced instead; frontend paginates. *)
      let all_visible = active_tasks @ recent_done in
      let task_fields = [
        ("tasks", `List (List.map task_json all_visible));
        ("task_counts", `Assoc [
          ("active", `Int (List.length active_tasks));
          ("done_recent", `Int (List.length recent_done));
          ("total", `Int (List.length tasks));
          ("shown", `Int (List.length all_visible));
        ]);
      ] in
      let t_end = Time_compat.now () in
      let phase_ms a b = (b -. a) *. 1000.0 in
      let timings : render_phase_timings_ms = {
        total_ms = phase_ms t_start t_end;
        snapshot_ms = phase_ms t_start t_after_snapshot;
        operations_ms = phase_ms t_after_snapshot t_after_operations;
        enrich_ms = phase_ms t_after_operations t_after_enrich;
        data_load_ms = phase_ms t_after_enrich t_after_data_load;
        assemble_ms = phase_ms t_after_data_load t_end;
        n_keepers = List.length keepers;
      } in
      (* #9766: surface phase breakdown in the slow-render WARN so the
         59.8s/9-keeper sample (~6.6s/keeper) can be attributed to a
         specific phase without rebuilding the binary with extra
         instrumentation.  enrich covers the per-keeper [List.map
         enrich_keeper_with_diagnostic] which is the suspected hot path. *)
      if timings.total_ms > 10000.0 then
        Log.Dashboard.warn "[dashboard_execution] slow render: %s"
          (format_slow_render_timings timings)
      else
        Log.Dashboard.debug
          "[dashboard_execution] timing: total=%.0fms snapshot=%.0fms \
           enrich=%.0fms data_load=%.0fms assemble=%.0fms"
          timings.total_ms timings.snapshot_ms timings.enrich_ms
          timings.data_load_ms timings.assemble_ms;
      if light then
        `Assoc (base_fields @ task_fields)
      else
        (* Full mode: include messages in addition to tasks *)
        `Assoc
          (base_fields @ task_fields @ [
            ("messages", `List (List.map message_json messages));
          ])

let json ?actor ?fixture ?(light = true) ~config ~sw ~clock ~proc_mgr () =
  let effective_actor = Dashboard_projection_cache.normalize_actor_name actor in
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
