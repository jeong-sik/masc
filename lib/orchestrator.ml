(** MASC Orchestrator - Self-sustaining agent workspace *)

(** Orchestrator configuration *)
type config = {
  check_interval_s: float;      (* How often to check (default: 300s = 5min) *)
  min_priority: int;            (* Minimum task priority to trigger (default: 1) *)
  agent_timeout_s: int;         (* Timeout for spawned orchestrator (default: 300) *)
  orchestrator_agent: string;   (* Which agent to spawn as orchestrator (env: MASC_ORCHESTRATOR_AGENT) *)
  enabled: bool;                (* Is auto-orchestration enabled *)
  port: int;                    (* MASC HTTP port for API calls *)
}

(** Load config from environment or use defaults *)
let load_config () =
  {
    check_interval_s =
      Env_config_core.get_float ~default:300.0 "MASC_ORCHESTRATOR_INTERVAL";
    min_priority =
      Env_config_core.get_int ~default:2 "MASC_ORCHESTRATOR_MIN_PRIORITY";
    agent_timeout_s =
      Env_config_core.get_int ~default:300 "MASC_ORCHESTRATOR_TIMEOUT";
    orchestrator_agent = Env_config.Orchestrator.agent_name;
    enabled =
      Env_config_core.get_bool ~default:false
        Env_config_core.orchestrator_enabled_env_key;
    port = Env_config_core.masc_http_port_int ();
  }

let default_config = load_config ()

(** Check if orchestration is needed *)
let should_orchestrate ~min_priority workspace_config =
  (* Check if workspace is paused first *)
  if Workspace.is_paused workspace_config then begin
    Log.Orchestrator.debug "workspace is paused, skipping";
    false
  end else begin
  match Workspace.read_backlog_r workspace_config with
  | Error msg ->
      Log.Orchestrator.error
        "backlog unavailable, skipping orchestration check: %s" msg;
      false
  | Ok backlog ->
      (* Get unclaimed tasks with priority <= min_priority *)
      let unclaimed_important = List.filter (fun (task: Masc_domain.task) ->
        task.task_status = Masc_domain.Todo && task.priority <= min_priority
      ) backlog.tasks in

      (* Get active (non-zombie) agents *)
      let agents = Workspace.get_agents_raw workspace_config in
      let active_agents = List.filter (fun (agent: Masc_domain.agent) ->
        not (Workspace_resilience.Zombie.is_zombie agent.last_seen)
      ) agents in

      (* Need orchestration if: important tasks exist AND no active agents *)
      let needs_orchestration =
        unclaimed_important <> [] && active_agents = []
      in

      if needs_orchestration then
        Log.Orchestrator.info "%d unclaimed tasks, %d active agents, spawning"
          (List.length unclaimed_important) (List.length active_agents);

      needs_orchestration
  end  (* end of else begin for pause check *)

(** The orchestrator prompt - MCP tools are now available via --allowedTools! *)
let orchestrator_prompt_key = "system.orchestrator"
let orchestrator_prompt_asset = "prompts/" ^ orchestrator_prompt_key ^ ".md"

type embedded_prompt_error =
  | Embedded_prompt_missing of string
  | Embedded_prompt_empty of string

let embedded_orchestrator_prompt () : (string, embedded_prompt_error) result =
  match Embedded_config.read orchestrator_prompt_asset with
  | None -> Error (Embedded_prompt_missing orchestrator_prompt_asset)
  | Some markdown ->
    let prompt = Prompt_registry.markdown_body markdown in
    if String.trim prompt = "" then
      Error (Embedded_prompt_empty orchestrator_prompt_asset)
    else Ok prompt

let embedded_prompt_error_message = function
  | Embedded_prompt_missing asset ->
    Printf.sprintf "orchestrator prompt asset %S is not embedded" asset
  | Embedded_prompt_empty asset ->
    Printf.sprintf "orchestrator prompt asset %S has an empty body" asset

let make_orchestrator_prompt ~port:_ =
  let prompt = Prompt_registry.get_prompt orchestrator_prompt_key in
  if String.trim prompt <> "" then prompt
  else begin
    Log.Orchestrator.warn
      "%s prompt missing or empty, using embedded asset %s"
      orchestrator_prompt_key orchestrator_prompt_asset;
    match embedded_orchestrator_prompt () with
    | Ok embedded -> embedded
    | Error error ->
      let message = embedded_prompt_error_message error in
      Log.Orchestrator.error "%s" message;
      invalid_arg message
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
    Checks if orchestration is needed and spawns a workspace lead if so. *)
let make_orchestrator_check_consumer ~sw ~proc_mgr ?domain_mgr ~config ~workspace_config ()
    : (module Pulse.Consumer) =
  (module struct
    let name = "orchestrator-check"
    let should_act _beat = config.enabled
    let on_beat _beat =
      try
        if should_orchestrate ~min_priority:config.min_priority workspace_config then
          Log.Orchestrator.info "orchestration needed but vendor-specific spawn removed";
        Ok ()
      with Eio.Cancel.Cancelled _ as e -> raise e | exn ->
        let msg = Printf.sprintf "orchestrator check error: %s" (Printexc.to_string exn) in
        Log.Orchestrator.warn "%s (recovering...)" msg;
        Error msg
  end)

(** RFC-0294 PR-4: single-owner orphan-task surfacer.

    R1g (RFC-0294) removed [audit_orphan_tasks] from the keeper wake-driver, so an
    orphaned task — in particular an [AwaitingVerification] one, which
    [cleanup_zombies] Phase 3 does not release (RFC-0220 §5) and so never returns
    to 0 — would become silently invisible (broken-but-visible regression). This
    refreshes [masc_orphan_tasks] (gauge, labeled by status_class) each pulse beat
    from the same audit, independent of the keeper actor. It is an alertable
    metric, not an actor wake: if the reaper/pulse itself stalls (the 2026-06-21/22
    reaper-not-running incident) the gauge goes stale, which is itself alertable.
    Every class in [Workspace.orphan_status_classes] is emitted (0 when empty) so a
    cleared class resets rather than leaving a stale value. *)
let surface_orphan_tasks_gauge workspace_config =
  let counts =
    Workspace.orphan_counts_by_status_class
      (Workspace.audit_orphan_tasks workspace_config)
  in
  List.iter
    (fun (status_class, count) ->
       Otel_metric_store.set_gauge Otel_metric_store.metric_orphan_tasks
         ~labels:[ "status_class", status_class ]
         (Float.of_int count))
    counts

(** Build the legacy zero-zombie pulse consumer as an observation-only orphan
    surfacer. Inactivity is not an objective lifecycle transition, so a pulse
    must never stop a keeper, release its task, or delete its registry file. *)
let make_zero_zombie_consumer ~sw:_ ~workspace_config
    : (module Pulse.Consumer) =
  (module struct
    let name = "zero-zombie-cleanup"
    let should_act _beat = true
    let on_beat _beat =
      (try surface_orphan_tasks_gauge workspace_config; Ok () with
       | Eio.Cancel.Cancelled _ as e -> raise e
       | exn ->
         let msg =
           Printf.sprintf "orphan observation failed: %s" (Printexc.to_string exn)
         in
         Log.Orchestrator.warn "%s" msg;
         Error msg)
  end)

(** Start the orchestrator background services using Pulse.
    Returns a cancel function to gracefully stop both Pulse engines. *)
let start ~sw ~proc_mgr ~clock ?domain_mgr workspace_config =
  let config = load_config () in

  (* Zero-Zombie cleanup: always enabled, configurable interval *)
  let neo4j_interval = Env_config_runtime_services.Timeouts.neo4j_timeout_sec in
  Log.Orchestrator.debug "zero-zombie cleanup enabled (interval: %.0fs)" neo4j_interval;
  let zombie_consumer = make_zero_zombie_consumer ~sw ~workspace_config in
  let dedup_consumer = Channel_gate.make_dedup_cleanup_consumer () in
  let zp = Pulse.create ~clock ~rhythm:(fixed_rhythm neo4j_interval) ~lifecycle:Always_on ~consumers:[zombie_consumer; dedup_consumer] in
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

  let orch_consumer = make_orchestrator_check_consumer ~sw ~proc_mgr ?domain_mgr ~config ~workspace_config () in
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
