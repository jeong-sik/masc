(** MASC Orchestrator - Self-sustaining agent coordination *)

(** Orchestrator configuration *)
type config = {
  check_interval_s: float;      (* How often to check (default: 300s = 5min) *)
  min_priority: int;            (* Minimum task priority to trigger (default: 1) *)
  agent_timeout_s: int;         (* Timeout for spawned orchestrator (default: 300) *)
  orchestrator_agent: string;   (* Which agent to spawn as orchestrator (env: MASC_ORCHESTRATOR_AGENT) *)
  enabled: bool;                (* Is auto-orchestration enabled *)
  port: int;                    (* MASC HTTP port for API calls *)
}

let default_config = {
  check_interval_s = 300.0;
  min_priority = 2;
  agent_timeout_s = 300;
  orchestrator_agent = Env_config_runtime.Orchestrator.agent_name;
  enabled = false;
  port = Env_config_core.masc_http_port_int ();
}

(** Load config from environment or use defaults *)
let load_config () =
  let get_env_float name default =
    match Sys.getenv_opt name with
    | Some v -> Safe_ops.float_of_string_with_default ~default v
    | None -> default
  in
  let get_env_int name default =
    match Sys.getenv_opt name with
    | Some v -> Safe_ops.int_of_string_with_default ~default v
    | None -> default
  in
  let get_env_bool name default =
    match Sys.getenv_opt name with
    | Some "1" | Some "true" | Some "yes" -> true
    | Some "0" | Some "false" | Some "no" -> false
    | _ -> default
  in
  {
    check_interval_s = get_env_float "MASC_ORCHESTRATOR_INTERVAL" 300.0;
    min_priority = get_env_int "MASC_ORCHESTRATOR_MIN_PRIORITY" 2;
    agent_timeout_s = get_env_int "MASC_ORCHESTRATOR_TIMEOUT" 300;
    orchestrator_agent = Env_config.Orchestrator.agent_name;
    enabled = get_env_bool "MASC_ORCHESTRATOR_ENABLED" false;
    port = Env_config_core.masc_http_port_int ();
  }

(** Check if orchestration is needed *)
let should_orchestrate room_config =
  (* Check if room is paused first *)
  if Room.is_paused room_config then begin
    Log.Orchestrator.debug "room is paused, skipping";
    false
  end else begin
  match Room.read_backlog_r room_config with
  | Error msg ->
      Log.Orchestrator.error
        "backlog unavailable, skipping orchestration check: %s" msg;
      false
  | Ok backlog ->
      (* Get unclaimed tasks with priority <= min_priority *)
      let unclaimed_important = List.filter (fun (task: Types.task) ->
        task.task_status = Types.Todo && task.priority <= 2
      ) backlog.tasks in

      (* Get active (non-zombie) agents *)
      let agents = Room.get_agents_raw room_config in
      let active_agents = List.filter (fun (agent: Types.agent) ->
        not (Resilience.Zombie.is_zombie agent.last_seen)
      ) agents in

      (* Need orchestration if: important tasks exist AND no active agents *)
      let needs_orchestration =
        List.length unclaimed_important > 0 && List.length active_agents = 0
      in

      if needs_orchestration then
        Log.Orchestrator.info "%d unclaimed tasks, %d active agents, spawning"
          (List.length unclaimed_important) (List.length active_agents);

      needs_orchestration
  end  (* end of else begin for pause check *)

(** The orchestrator prompt - MCP tools are now available via --allowedTools! *)
let make_orchestrator_prompt ~port:_ =
  {|You are the MASC Orchestrator Agent.

You have access to MASC MCP tools via mcp__masc__* prefix.

## Your Tasks:

1. **Check status**: Call `mcp__masc__masc_status` to see the room state

2. **Find unclaimed tasks**: Look for tasks with "📋" (unclaimed) status

3. **Claim a task**: Call `mcp__masc__masc_transition` with:
   - agent_name: "orchestrator"
   - task_id: "task-XXX"
   - action: "claim"

4. **Work on the task**: Execute the task description

5. **Mark done**: Call `mcp__masc__masc_transition` with:
   - agent_name: "orchestrator"
   - task_id: "task-XXX"
   - action: "done"
   - notes: completion summary

6. **Broadcast progress**: Call `mcp__masc__masc_broadcast` to notify others

## Available MCP Tools:
- mcp__masc__masc_status - Get room status
- mcp__masc__masc_tasks - List all tasks
- mcp__masc__masc_transition - Claim/start/done/cancel/release a task
- mcp__masc__masc_claim_next - Auto-claim highest priority
- mcp__masc__masc_broadcast - Send message to all
- mcp__masc__masc_heartbeat - Update your heartbeat

Start by calling mcp__masc__masc_status to see the current room state.|}

(** Spawn the orchestrator agent. *)
let spawn_orchestrator ~sw:_ ~proc_mgr:_ ?domain_mgr:_ config room_config =
  if Room.is_paused room_config then begin
    Log.Orchestrator.debug "room paused before spawn, aborting";
    { Spawn.success = false; output = "Room paused"; exit_code = 0; elapsed_ms = 0;
      input_tokens = None; output_tokens = None; cache_creation_tokens = None;
      cache_read_tokens = None; cost_usd = None }
  end else begin
  Log.Orchestrator.info "spawning agent: %s (with MCP tools)" config.orchestrator_agent;

  let _msg = Room.broadcast room_config ~from_agent:"system"
    ~content:"Auto-orchestrator activated - spawning coordinator with MCP tools" in

  let prompt = make_orchestrator_prompt ~port:config.port in
  let result =
    Spawn.spawn ~agent_name:config.orchestrator_agent ~prompt
      ~timeout_seconds:config.agent_timeout_s ()
  in

  if result.success then
    Log.Orchestrator.info "completed in %dms" result.elapsed_ms
  else
    Log.Orchestrator.warn "failed (exit %d) in %dms"
      result.exit_code result.elapsed_ms;

  result
  end

(* ── Pulse helpers ─────────────────────────────────────────── *)

(** Fixed-interval rhythm with no quiet hours.
    Orchestrator runs at constant interval regardless of time of day. *)
let fixed_rhythm base_s =
  { Pulse.base_s; min_s = base_s; max_s = base_s; quiet = (0, 0) }

(** Pulse instances for orchestrator and zombie cleanup.
    Stored in refs for shutdown access. *)
let orchestrator_pulse : Pulse.t option ref = ref None
let zombie_pulse : Pulse.t option ref = ref None

let pulse_mu = Eio.Mutex.create ()
let with_pulse_rw f = Eio_guard.with_mutex pulse_mu f
let with_pulse_ro f = Eio_guard.with_mutex_ro pulse_mu f

(** Build the orchestrator check consumer.
    Checks if orchestration is needed and spawns coordinator if so. *)
let make_orchestrator_check_consumer ~sw ~proc_mgr ?domain_mgr ~config ~room_config ()
    : (module Pulse.Consumer) =
  (module struct
    let name = "orchestrator-check"
    let should_act _beat = config.enabled
    let on_beat _beat =
      try
        if should_orchestrate room_config then
          Eio.Fiber.fork ~sw (fun () ->
            try
              ignore (spawn_orchestrator ~sw ~proc_mgr ?domain_mgr config room_config)
            with Eio.Cancel.Cancelled _ as e -> raise e | exn ->
              Log.Orchestrator.error "spawn failed: %s" (Printexc.to_string exn));
        Ok ()
      with Eio.Cancel.Cancelled _ as e -> raise e | exn ->
        let msg = Printf.sprintf "orchestrator check error: %s" (Printexc.to_string exn) in
        Log.Orchestrator.warn "%s (recovering...)" msg;
        Error msg
  end)

(** Build the zero-zombie cleanup consumer.
    Runs Room.cleanup_zombies and logs if zombies were found. *)
let make_zero_zombie_consumer ~sw ~room_config
    : (module Pulse.Consumer) =
  (module struct
    let name = "zero-zombie-cleanup"
    let should_act _beat = true
    let on_beat _beat =
      (* Run GC in background fiber to avoid blocking Pulse consumers.
         Heartbeat and other consumers proceed without waiting for
         cleanup_zombies I/O. See RFC #3646 M5 / #3626. *)
      Eio.Fiber.fork ~sw (fun () ->
        try
          let status = Room.cleanup_zombies room_config in
          let status_trimmed = String.trim status in
          if String.length status_trimmed > 0 then begin
            let has_zombie_indicator =
              try
                String.sub status_trimmed 0 (min 4 (String.length status_trimmed)) = "\xf0\x9f\xa7\x9f" ||
                String.length status_trimmed >= 7 && String.sub status_trimmed 0 7 = "Cleaned"
              with Eio.Cancel.Cancelled _ as e -> raise e | exn ->
                Log.Orchestrator.warn "zombie indicator check failed: %s" (Printexc.to_string exn);
                false
            in
            if has_zombie_indicator then
              Log.Orchestrator.info "[zombie] %s" status_trimmed
          end;
          let ttl = Env_config_runtime.Claim.ttl_seconds in
          (try
            let released = Room_task_schedule.release_stale_claims room_config ~ttl_seconds:ttl in
            if released <> [] then
              Log.Orchestrator.info "[stale-claims] released %d stale task(s): %s"
                (List.length released)
                (String.concat ", " (List.map (fun (tid, agent) ->
                  Printf.sprintf "%s(%s)" tid agent) released))
          with Eio.Cancel.Cancelled _ as e -> raise e | exn ->
            Log.Orchestrator.warn "[stale-claims] error: %s" (Printexc.to_string exn))
        with Eio.Cancel.Cancelled _ as e -> raise e | exn ->
          if not (Resilience.ZeroZombie.is_benign_error exn) then
            Log.Orchestrator.warn "[zombie] error: %s" (Printexc.to_string exn));
      Ok ()
  end)

(** Start the orchestrator background services using Pulse.
    Returns a cancel function to gracefully stop both Pulse engines. *)
let start ~sw ~proc_mgr ~clock ?domain_mgr room_config =
  let config = load_config () in

  (* Zero-Zombie cleanup: always enabled, configurable interval *)
  let neo4j_interval = Env_config_governance.Timeouts.neo4j_timeout_sec in
  Log.Orchestrator.debug "zero-zombie cleanup enabled (interval: %.0fs)" neo4j_interval;
  let zombie_consumer = make_zero_zombie_consumer ~sw ~room_config in
  let zp = Pulse.create ~clock ~rhythm:(fixed_rhythm neo4j_interval) ~lifecycle:Always_on ~consumers:[zombie_consumer] in
  with_pulse_rw (fun () -> zombie_pulse := Some zp);
  Eio.Fiber.fork ~sw (fun () ->
    try Pulse.run ~sw zp
    with
    | Eio.Cancel.Cancelled _ as e -> raise e
    | exn ->
      Log.Orchestrator.error "zombie cleanup pulse crashed: %s"
        (Printexc.to_string exn));

  (* Orchestrator check: respects enabled flag via should_act *)
  if config.enabled then
    Log.Orchestrator.debug "loop enabled (interval: %.0fs, agent: %s)"
      config.check_interval_s config.orchestrator_agent
  else
    Log.Orchestrator.debug "loop disabled (set MASC_ORCHESTRATOR_ENABLED=1 to enable)";

  let orch_consumer = make_orchestrator_check_consumer ~sw ~proc_mgr ?domain_mgr ~config ~room_config () in
  let op = Pulse.create ~clock ~rhythm:(fixed_rhythm config.check_interval_s) ~lifecycle:Always_on ~consumers:[orch_consumer] in
  with_pulse_rw (fun () -> orchestrator_pulse := Some op);
  Eio.Fiber.fork ~sw (fun () ->
    try Pulse.run ~sw op
    with
    | Eio.Cancel.Cancelled _ as e -> raise e
    | exn ->
      Log.Orchestrator.error "orchestrator check pulse crashed: %s"
        (Printexc.to_string exn));

  (* Return cancel function — shuts down both Pulse engines *)
  fun () ->
    with_pulse_ro (fun () ->
      (match !orchestrator_pulse with Some p -> Pulse.shutdown p | None -> ()));
    with_pulse_ro (fun () ->
      (match !zombie_pulse with Some p -> Pulse.shutdown p | None -> ()))
