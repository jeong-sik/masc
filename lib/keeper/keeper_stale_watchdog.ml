(** Stale-turn watchdog — standalone fiber for keeper liveness detection.

    Extracted from [Keeper_supervisor] to avoid circular dependency with
    [Keeper_keepalive]. Both modules call [fork_stale_watchdog] through
    this shared implementation.

    Two stall detection modes:
    1. Idle stall: [last_turn_ts] older than 300s while [Running],
       with no recent keepalive skip verdict proving the fiber is still
       evaluating work.
    2. Failure loop: [consecutive_noop_count >= 3] — catches keepers in
       LLM timeout loops where [last_turn_ts] stays fresh because each
       failed turn updates it.

    On detection, sets [fiber_stop] and emits a stale broadcast so the
    supervisor's [sweep_and_recover] can restart the keeper.

    @since PR #10670 — extracted from Keeper_supervisor. *)

(* Spec navigation (OCaml -> TLA+) — plan §19 anchor pattern.  Sibling
   to PR 11618 (Cycle 35, keeper_execution_receipt.ml).  Authoritative
   spec mirror is
   specs/keeper-state-machine/OperatorPauseBroadcast.tla.

   Spec line 20-21 cite "lib/keeper/keeper_supervisor.ml: stale
   watchdog fiber forks under ctx.sw and calls
   emit_stale_keeper_broadcast".  That citation pre-dates PR 10670
   which extracted this module from Keeper_supervisor to break a
   circular dependency.  After the extraction:

     keeper_supervisor.ml line ~118    fork_stale_watchdog wrapper
                                       (re-exports the function below)
     keeper_stale_watchdog.ml          actual fiber logic + emit
                                       (this file)
     keeper_execution_receipt.ml       emit_stale_keeper_broadcast
                                       definition (called at line 287
                                       of this file)

   Spec citation drift: the spec module string still says
   "keeper_supervisor.ml" but the true post-extraction location of
   the watchdog logic is here.  Spec-side cleanup is deferred — when
   the spec is next regenerated it should point at this module
   directly.

   Spec semantics modelled (TLA+ -> OCaml):
     phase = StaleRunning      reached when this watchdog detects a
                               stall (idle or failure-loop) and sets
                               fiber_stop.
     OperatorBroadcast emit    line 287 below calls
                               Keeper_execution_receipt.emit_stale_keeper_broadcast
                               unconditionally on detection (inside a
                               try block — clean Spec model).
     Eventually-emit liveness  satisfied because every detection path
                               feeds into the same emit call;
                               last_broadcast_ts (line 99) only
                               throttles repeated emissions, it does
                               not silently skip.

   Bug model the spec catches: a refactor that wrapped the line 287
   emit in a conditional that could silently skip would re-create
   the original fleet-stall regression class.  The spec's bug-action
   would silently drop emits and violate the leads-to property. *)

open Keeper_types

(* Process-global termination history per keeper.  Survives keeper
   unregister/re-register because the watchdog module's state lives
   for the server process lifetime.  Each entry records the
   timestamps of recent stale terminations within a sliding window;
   when the count exceeds [escalation_threshold] we emit a loud
   warn line and a Prometheus counter so operators see the death
   spiral pattern (#10765 — 116 stale terminations / 24h, single
   keeper hit 13× with no escalation under the previous design).

   This is observability only — we still let the supervisor restart
   the keeper.  Phase 2 (deciding whether to auto-pause) is left
   for a follow-up PR with measurement evidence in hand. *)
let termination_window_sec = Env_config_keeper.KeeperWatchdog.termination_window_sec
let escalation_threshold = Env_config_keeper.KeeperWatchdog.escalation_threshold
let termination_history : (string, float list) Hashtbl.t = Hashtbl.create 16
let termination_history_mu = Eio.Mutex.create ()

let record_stale_termination keeper_name now : int =
  Eio.Mutex.use_rw ~protect:true termination_history_mu (fun () ->
    let prev =
      Hashtbl.find_opt termination_history keeper_name
      |> Option.value ~default:[]
    in
    let window_start = now -. termination_window_sec in
    let pruned = List.filter (fun ts -> ts >= window_start) (now :: prev) in
    Hashtbl.replace termination_history keeper_name pruned;
    List.length pruned)

(* Cycle 50 observability: kill-class-dimensioned counter.

   The pre-existing [masc_keeper_stale_termination_total] counter has
   only the [keeper] label, so a dashboard cannot attribute kills to
   the typed [stale_kill_class] root cause without re-parsing the
   reason_desc text.  PR #11292 already typed the class as
   [Keeper_registry.stale_kill_class] (idle_turn / in_turn_hung /
   noop_failure_loop); this PR surfaces that class as a Prometheus
   label so operators can chart "which root cause is dominant?".

   The existing termination counter is preserved unchanged (no label
   changes, no removal) so existing dashboards / alerts continue to
   work.  This counter is purely additive. *)

(** Map a [stale_kill_class] to a low-cardinality Prometheus label
    value.  Keep this distinct from [Keeper_registry.stale_kill_class_to_string]
    which embeds variable counts (seconds, noop_count) — those would
    explode counter cardinality. *)
let stale_kill_class_label (cls : Keeper_registry.stale_kill_class) : string =
  match cls with
  | Idle_turn _ -> "idle_turn"
  | In_turn_hung _ -> "in_turn_hung"
  | Noop_failure_loop _ -> "noop_failure_loop"

let has_recent_skip_observation ~now ~threshold
    (entry : Keeper_registry.registry_entry) : bool =
  match entry.last_skip_observation with
  | Some (ts, reasons) ->
      reasons <> [] && now -. ts <= threshold
  | None -> false

let pending_oas_timeout_budget_count
    (entry : Keeper_registry.registry_entry) : int option =
  let is_timeout_budget_observation_reason reason =
    List.exists
      (String.equal reason)
      Keeper_heartbeat_loop.oas_timeout_budget_observation_reasons
  in
  let has_timeout_observation =
    match entry.last_skip_observation with
    | Some (_, reasons) ->
        List.exists is_timeout_budget_observation_reason reasons
    | None -> false
  in
  match entry.last_failure_reason, has_timeout_observation with
  | Some (Keeper_registry.Oas_timeout_budget_loop { count }), true -> Some count
  | _ -> None

let () =
  Prometheus.register_counter
    ~name:Prometheus.metric_keeper_stale_termination_by_class
    ~help:
      "Total stale watchdog terminations broken down by typed kill \
       class (idle_turn | in_turn_hung | noop_failure_loop).  \
       Companion to masc_keeper_stale_termination_total which has \
       only the keeper label — this counter adds the class dimension \
       so dashboards can attribute kills to root cause without \
       re-parsing the reason_desc string.  Labels: keeper, class."
    ()

let () =
  Prometheus.register_counter
    ~name:Prometheus.metric_keeper_oas_timeout_budget_watchdog_termination
    ~help:
      "Total watchdog terminations that preserved an unresolved \
       oas_timeout_budget failure reason instead of reclassifying the \
       keeper as an idle stale stall. Labels: keeper."
    ()

(* #10765 phase 2: fleet-wide batch termination detection.

   Each keeper runs its watchdog as an independent fiber, so the
   per-keeper [record_stale_termination] above never sees the
   cross-keeper pattern.  Issue evidence: 8 keepers terminated
   within the same second at 12:54:13Z (analyst, executor,
   issue_king, janitor, masc-improver, nick0cave, ollama-local,
   qa-king).  That shape is a *systemic* signal — typically cascade
   dead (#10474), provider auth failure, or fd exhaustion (#10745) —
   not 8 independent stuck fibers.  The supervisor will keep
   restarting each one individually unless an operator notices.

   Track recent terminations across all keepers in a small bounded
   window.  When the number of distinct keepers in the window
   reaches the threshold we emit a fleet-tier ERROR pointing at the
   systemic root-cause issue list, plus a Prometheus counter.  No
   state-machine change: the per-keeper restart still proceeds.  The
   point is to make the batch event visible at all. *)
let batch_window_sec = Env_config_keeper.KeeperWatchdog.batch_window_sec
let batch_threshold = Env_config_keeper.KeeperWatchdog.batch_threshold
let batch_terminations : (string * float) list Atomic.t = Atomic.make []

let record_batch_termination keeper_name now : string list =
  let rec atomic_update () =
    let prev = Atomic.get batch_terminations in
    let pruned =
      List.filter (fun (_, ts) -> now -. ts <= batch_window_sec) prev
    in
    let next = (keeper_name, now) :: pruned in
    if Atomic.compare_and_set batch_terminations prev next
    then next
    else atomic_update ()
  in
  let entries = atomic_update () in
  List.sort_uniq compare (List.map fst entries)

let fork_stale_watchdog (ctx : _ context) (meta : keeper_meta)
    (reg : Keeper_registry.registry_entry) =
  let base_path = ctx.config.base_path in
  let stale_threshold_sec () =
    Env_config_keeper.KeeperWatchdog.stale_threshold_sec
  in
  let watchdog_poll_sec () =
    Env_config_keeper.KeeperWatchdog.poll_sec
  in
  let noop_threshold () =
    Env_config_keeper.KeeperWatchdog.noop_threshold
  in
  let grace_period_sec () =
    Env_config_keeper.KeeperWatchdog.grace_period_sec
  in
  let last_broadcast_ts = ref 0.0 in
  let request_watchdog_stop () =
    (* tla-lint: allow-mutation: fiber signal — stale watchdog asks the
       heartbeat fiber to exit and wakes it if it is in interruptible sleep. *)
    Atomic.set reg.fiber_stop true;
    Atomic.set reg.fiber_wakeup true
  in
  Eio.Fiber.fork ~sw:ctx.sw (fun () ->
    let rec watchdog_loop () =
      if Atomic.get reg.fiber_stop then ()
      else begin
        Eio.Fiber.yield ();
        let now = Time_compat.now () in
        let threshold = stale_threshold_sec () in
        (try
           match Keeper_registry.get ~base_path meta.name with
           | Some entry
             when entry.phase = Keeper_state_machine.Running ->
             let last_turn = entry.meta.runtime.usage.last_turn_ts in
             let fiber_age = now -. entry.started_at in
             let grace_remaining = grace_period_sec () -. fiber_age in
             (* #10765-followup: separate idle-stale (no turn running) from
                in-turn-stale (turn running too long).  Production
                observation (2026-04-26): 9 keepers killed at idle
                305–329s while masc-improver showed legitimate turn
                latency=278s.  The previous code looked only at
                [last_turn_ts] and could fire while a turn was actively
                running, killing the keeper mid-LLM-call.  Active turns
                get a separate (larger) threshold so legitimately slow
                turns aren't mistaken for hangs.  Use
                [Keeper_runtime_resolved.turn_timeout_sec] as the ceiling
                so the watchdog never kills a turn still within its
                configured budget (default 3600s, range [60, 7200]).
                Previous 600s hardcoded minimum caused fleet-wide
                termination when local models take 900s+ turns. *)
             let active_turn_timeout_sec =
               let turn_timeout = Keeper_runtime_resolved.turn_timeout_sec () in
               Float.max turn_timeout threshold
             in
             let idle_stale, in_turn_stale, in_turn_age,
                 idle_skip_suppressed =
               match entry.current_turn_observation with
               | Some obs ->
                 let elapsed = now -. obs.started_at in
                 ( false
                 , elapsed > active_turn_timeout_sec
                   && fiber_age >= grace_period_sec ()
                 , elapsed
                 , false )
               | None ->
                 let skip_observed =
                   has_recent_skip_observation ~now ~threshold entry
                 in
                 let stale =
                   last_turn > 0.0
                   && now -. last_turn > threshold
                   && fiber_age >= grace_period_sec ()
                   && not skip_observed
                 in
                 (stale, false, 0.0, skip_observed)
             in
             let noop_count =
               entry.meta.runtime.proactive_rt.consecutive_noop_count
             in
             let failure_loop = noop_count >= noop_threshold () in
             let stale = idle_stale || in_turn_stale || failure_loop in
             (* The tick line is a sampled state snapshot. Stale termination
                and broadcasts below remain ERROR, so INFO does not need every
                intermediate heartbeat/noop snapshot. *)
             let log_line =
               Printf.sprintf
                 "%s: watchdog tick noop=%d idle_stale=%b idle_skip_suppressed=%b in_turn_stale=%b in_turn_age=%.0f failure_loop=%b stale=%b last_turn=%.0f fiber_age=%.0f grace_rem=%.0f"
                 meta.name noop_count idle_stale idle_skip_suppressed
                 in_turn_stale in_turn_age failure_loop stale last_turn
                 fiber_age grace_remaining
             in
             Log.Keeper.routine "%s" log_line;
             let cooldown_ok =
               !last_broadcast_ts = 0.0
               || now -. !last_broadcast_ts > threshold
             in
             if stale && cooldown_ok then begin
               match pending_oas_timeout_budget_count entry with
               | Some count when idle_stale ->
                 let stall_seconds = now -. last_turn in
                 Keeper_registry.set_failure_reason ~base_path meta.name
                   (Some (Keeper_registry.Oas_timeout_budget_loop { count }));
                 (* tla-lint: allow-mutation: fiber signal — stop the keeper
                    through the provider-timeout path, preserving the typed
                    root cause for supervisor auto-pause. *)
                 request_watchdog_stop ();
                 Prometheus.inc_counter
                   Prometheus.metric_keeper_oas_timeout_budget_watchdog_termination
                   ~labels:[ ("keeper", meta.name) ]
                   ();
                 Log.Keeper.error
                   "%s: watchdog terminating fiber (oas_timeout_budget unresolved after idle %.0fs; count=%d; preserving provider timeout root cause) [cascade=%s]"
                   meta.name stall_seconds count meta.cascade_name
               | _ ->
               (* #10940 follow-up: surface the most recent skip reasons
                  alongside [idle %.0fs] so operators can tell whether
                  the kill targeted a *stuck* fiber or a *deliberately
                  skipping* one.  [last_skip_observation] is stamped by
                  the keepalive loop on every [should_run_turn=false]
                  decision; we only quote it if it's recent enough to
                  be the proximate cause of the idle window
                  ([recency_window] = the same idle threshold that
                  triggered the kill).  Older stamps are ignored to
                  avoid surfacing labels from before the current idle
                  window. *)
               let recency_window = threshold in
               let skip_reason_label =
                 match entry.last_skip_observation with
                 | Some (ts, reasons)
                   when reasons <> []
                        && now -. ts <= recency_window ->
                   Printf.sprintf " last_skip=[%s] (%.0fs ago)"
                     (String.concat "," reasons) (now -. ts)
                 | _ -> ""
               in
               (* Phase B PR-6 (2026-04-28): the kill reason now carries
                  a typed [stale_kill_class] so dashboards can attribute
                  the kill to the correct root cause (idle stall vs
                  active turn hang vs no-op loop) instead of every kill
                  collapsing to a single [stale_turn_timeout(<seconds>)]
                  string.  The three sub-causes need different operator
                  actions, so they need different typed labels.  The
                  surrounding [reason_desc] log line still embeds the
                  same human-readable text via [stale_kill_class_to_string]. *)
               let kill_class : Keeper_registry.stale_kill_class =
                 if in_turn_stale then
                   In_turn_hung
                     { active_seconds = in_turn_age;
                       timeout_threshold = active_turn_timeout_sec;
                     }
                 else if idle_stale then
                   Idle_turn { stall_seconds = now -. last_turn }
                 else
                   Noop_failure_loop { noop_count }
               in
               let reason_desc =
                 match kill_class with
                 | Idle_turn { stall_seconds } ->
                   Printf.sprintf "idle %.0fs%s"
                     stall_seconds skip_reason_label
                 | In_turn_hung { active_seconds; timeout_threshold } ->
                   Printf.sprintf "active turn hung %.0fs (timeout %.0fs)"
                     active_seconds timeout_threshold
                 | Noop_failure_loop { noop_count = n } ->
                   Printf.sprintf "failure-loop noop=%d" n
               in
               let stall_seconds =
                 if in_turn_stale then in_turn_age else now -. last_turn
               in
               let prior_failure_reason = entry.last_failure_reason in
               Keeper_registry.set_failure_reason ~base_path meta.name
                 (Keeper_registry.stale_watchdog_failure_reason
                    ~prior:prior_failure_reason ~kill_class);
               (* tla-lint: allow-mutation: fiber signal — stop the wedged keeper after stale-turn classification *)
               request_watchdog_stop ();
               let window_count = record_stale_termination meta.name now in
               Prometheus.inc_counter
                 Prometheus.metric_keeper_stale_termination_total
                 ~labels:[ ("keeper", meta.name) ]
                 ();
               Prometheus.inc_counter
                 Prometheus.metric_keeper_stale_termination_by_class
                 ~labels:[
                   ("keeper", meta.name);
                   ("class", stale_kill_class_label kill_class);
                 ]
                 ();
               Log.Keeper.error
                 "%s: stale watchdog terminating fiber (%s) [cascade=%s window_count=%d/6h]"
                 meta.name reason_desc meta.cascade_name window_count;
               if window_count >= escalation_threshold then begin
                 let cascade_recovered () =
                   match ctx.net with
                   | None -> false
                   | Some net ->
                       (match Cascade_catalog_runtime.resolve_named_providers_strict
                                ~sw:ctx.sw ~net ~cascade_name:meta.cascade_name () with
                        | Error _ -> false
                        | Ok candidates ->
                            let healthy =
                              Cascade_health_filter.filter_healthy ~sw:ctx.sw
                                ~net candidates
                            in
                            let has_recovery_evidence
                                (p : Llm_provider.Provider_config.t) =
                              let provider_key = p.model_id in
                              match
                                Cascade_health_tracker.provider_info
                                  Cascade_health_tracker.global
                                  ~provider_key
                              with
                              | None -> false
                              | Some info ->
                                  info.events_in_window > 0
                                  && info.success_rate > 0.0
                                  && (not info.in_cooldown)
                                  && Result.is_ok
                                       (Cascade_health_tracker.check_circuit_breaker
                                          Cascade_health_tracker.global
                                          ~provider_key)
                            in
                            List.exists has_recovery_evidence healthy)
                 in
                 if cascade_recovered () then
                   Log.Keeper.info "%s: stale threshold reached, but cascade %s appears healthy. Skipping auto-pause." meta.name meta.cascade_name
                 else begin
                 Prometheus.inc_counter
                   Prometheus.metric_keeper_stale_termination_threshold_breached
                   ~labels:[ ("keeper", meta.name) ]
                   ();
                 (* Phase 2 (#10765): override the [Stale_turn_timeout] latch
                    set above with the storm-pattern variant so the
                    supervisor's [`Crashed] branch can route this entry to
                    auto-pause + [meta.paused = true] persistence instead of
                    blindly enqueuing it for restart.  This breaks the
                    restart-loop-back-to-stale cycle observed when the
                    underlying cascade/provider/fd issue persists across
                    restarts (24h evidence: 116 events, single keeper 13×). *)
                 Keeper_registry.set_failure_reason ~base_path meta.name
                   (Some (Keeper_registry.Stale_termination_storm
                            { count = window_count }));
                 Prometheus.inc_counter
                   Prometheus.metric_keeper_stale_termination_threshold_breached
                   ~labels:[("keeper", meta.name)]
                   ();
                 Log.Keeper.error
                   "%s: STALE-TERMINATION THRESHOLD BREACHED — %d \
                    terminations in last %.0fs (threshold=%d). \
                    Phase 2: keeper will be auto-paused; supervisor will \
                    NOT restart until an operator investigates the \
                    underlying root cause (cascade dead, fd leak, \
                    provider auth, etc.) and resumes the keeper. \
                    See issue #10765."
                   meta.name window_count termination_window_sec
                   escalation_threshold
               end
               end;
               (* #10765 phase 2: fleet batch detection.  See module-level
                  comment on [batch_terminations] for rationale. *)
               let batch = record_batch_termination meta.name now in
               if List.length batch >= batch_threshold then begin
                 Prometheus.inc_counter
                   Prometheus.metric_keeper_stale_termination_batch
                   ();
                 Log.Keeper.error
                   "FLEET BATCH TERMINATION: %d distinct keepers \
                    terminated in last %.0fs [%s] — systemic signal \
                    (cascade dead, provider auth, fd leak).  \
                    Per-keeper restarts will loop without operator \
                    intervention.  See #10765, #10474, #10745."
                   (List.length batch) batch_window_sec
                   (String.concat ", " batch)
               end;
               (try
                  Keeper_execution_receipt.emit_stale_keeper_broadcast
                    ctx.config
                    ~keeper_name:meta.name
                    ~agent_name:meta.agent_name
                    ~cascade_name:
                      (Keeper_execution_receipt.cascade_name_of_string
                         meta.cascade_name)
                    ~trace_id:
                      (Keeper_id.Trace_id.to_string
                         entry.meta.runtime.trace_id)
                    ~generation:entry.meta.runtime.generation
                    ~stale_seconds:stall_seconds
                    ~last_turn_ts:last_turn;
                  last_broadcast_ts := now
                with
                | Eio.Cancel.Cancelled _ as e -> raise e
                | exn ->
                  Prometheus.inc_counter
                    Prometheus.metric_keeper_stale_broadcast_emit_failures
                    ~labels:[("keeper", meta.name)]
                    ();
                  Log.Keeper.warn
                    "%s: stale broadcast emit failed (restart still triggered): %s"
                    meta.name (Printexc.to_string exn))
             end
           | None ->
             Log.Keeper.warn "%s: watchdog: registry entry NOT FOUND" meta.name
           | Some entry ->
             Log.Keeper.info
               "%s: watchdog: phase=%s (not Running, skipping)"
               meta.name
               (Keeper_state_machine.phase_to_string entry.phase)
         with
         | Eio.Cancel.Cancelled _ as e -> raise e
         | exn ->
           Prometheus.inc_counter
             Prometheus.metric_keeper_stale_watchdog_tick_failures
             ~labels:[("keeper", meta.name)]
             ();
           Log.Keeper.warn
             "%s: stale watchdog tick failed (suppressed): %s"
             meta.name (Printexc.to_string exn));
        (* P3 cleanup: previously this try/with swallowed every
           non-Cancelled exception silently.  Eio.Time.sleep does not
           have other failure modes worth catching here, and the outer
           watchdog_loop's `with Eio.Cancel.Cancelled _ -> ()` already
           handles cancellation propagation correctly.  Removing the
           defensive wrapper makes any unexpected sleep exception
           surface instead of being lost. *)
        Eio.Time.sleep ctx.clock (watchdog_poll_sec ());
        watchdog_loop ()
      end
    in
    try watchdog_loop ()
    with Eio.Cancel.Cancelled _ -> ())
