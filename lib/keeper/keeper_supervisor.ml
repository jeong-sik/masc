(** Keeper_supervisor — keeper keepalive fiber supervision.

    Supervises the MASC-owned background keepalive fibers that maintain
    keeper presence and heartbeat snapshots. Uses [Keeper_registry] as
    the single source of truth for keeper state. The Promise-based
    liveness tracking ([done_p]/[done_r]) lives in registry entries.

    This is not the OAS [Agent.run] lifecycle; it sits outside the turn
    loop and only manages keepalive liveness/restart policy.

    @since 2.102.0 *)

open Keeper_types
open Keeper_execution
module StringMap = Map.Make (String)
module Startup_helpers = Keeper_supervisor_startup_helpers

(* ── Pure helpers ────────────────────────────────────────── *)

let backoff_delay = Startup_helpers.backoff_delay
let keep_last_n = Startup_helpers.keep_last_n

(** supervision_cohort cluster moved to Keeper_supervisor_types
    (intra-library file split, 2026-05-16). *)
include Keeper_supervisor_types

let committed_tools_of_ambiguous_blocker =
  Startup_helpers.committed_tools_of_ambiguous_blocker
;;

(* ── Event publishing ────────────────────────────────────── *)

(* #8856 / #8605 family: single helper takes the unified
   [Keeper_lifecycle_events.lifecycle_event] variant. The legacy
   [publish_lifecycle ?phase event_name] (string event_name) and
   [publish_phase_lifecycle ~phase] are folded into [publish_lifecycle
   ~event] -- the compiler now enforces that every call site picks
   either Custom_event (with optional phase context) or Phase_event,
   eliminating the [~phase:Stopped ~event:"crashed"] typo class
   originally addressed at runtime by #8572 / #8575. *)
let publish_lifecycle
      ~(event : Keeper_lifecycle_events.lifecycle_event)
      keeper_name
      detail
      ()
  =
  let event_name = Keeper_lifecycle_events.lifecycle_event_to_string event in
  let phase =
    Option.map
      Keeper_state_machine.phase_to_string
      (Keeper_lifecycle_events.lifecycle_event_phase event)
  in
  (* #12798: record in the per-keeper lifecycle audit ring for dashboard. *)
  Keeper_lifecycle_audit.record ~keeper_name ~event_name ~phase ~detail;
  match Keeper_keepalive.get_bus () with
  | Some bus -> Cascade_events.publish_keeper_lifecycle bus ~event ~keeper_name ~detail ()
  | None -> ()
;;

(** Phase-event helper: the wire event name IS the phase name. *)
let publish_phase_lifecycle ~phase keeper_name detail () =
  publish_lifecycle
    ~event:(Keeper_lifecycle_events.Phase_event phase)
    keeper_name
    detail
    ()
;;

let fork_stale_watchdog = Keeper_stale_watchdog.fork_stale_watchdog

(* ── Supervised fiber launch ─────────────────────────────── *)

let set_restart_launch_noop_for_test = Keeper_supervisor_restart_noop.set
let restart_launch_noop_enabled_for_test = Keeper_supervisor_restart_noop.enabled
let with_restart_launch_noop_for_test = Keeper_supervisor_restart_noop.with_noop

let launch_supervised_fiber
      ~proactive_warmup_sec
      ctx
      (meta : keeper_meta)
      (reg : Keeper_registry.registry_entry)
  =
  let base_path = ctx.config.base_path in
  let keepers_dir = Filename.concat (Coord.masc_root_dir ctx.config) "keepers" in
  (match Keeper_registry.prepare_fiber_launch ~base_path meta.name with
   | Ok _ -> ()
   | Error err ->
     Log.Keeper.warn
       "%s: Fiber_started rejected during supervised launch: %s"
       meta.name
       (Keeper_state_machine.transition_error_to_string err);
     Prometheus.inc_counter
       Keeper_metrics.metric_keeper_supervisor_cleanup_failures
       ~labels:
         [ "keeper", meta.name
         ; ("site", Keeper_supervisor_cleanup_failure_site.(to_label Fiber_start_rejected))
         ]
       ());
  if restart_launch_noop_enabled_for_test ()
  then ()
  else (
    fork_stale_watchdog ctx meta ~startup_warmup_sec:proactive_warmup_sec reg;
    (* Task 137: Inject bootstrap signal to ensure at least one warm-up turn runs
     and break the initial proactive deadlock. *)
    let bootstrap_signal : Keeper_event_queue.stimulus =
      { post_id = "bootstrap"
      ; urgency = Keeper_event_queue.Normal
      ; arrived_at = Unix.gettimeofday ()
      ; payload = "Keeper bootstrap signal"
      }
    in
    Keeper_registry.enqueue_event ~base_path meta.name bootstrap_signal;
    (* RFC-0059 PR-7-pilot: when [MASC_KEEPER_DOMAIN_POOL_ENABLED] is set
       and the shared typed [Domain_pool] has been installed, route the
       per-keeper heartbeat body through [Domain_pool.submit_io].  This keeps
       the main Domain focused on HTTP/SSE/Eio scheduling while centralising
       the worker weight policy in [Domain_pool]. *)
    let domain_pool_flag = Env_config.KeeperSupervisor.domain_pool_enabled in
    let pool_for_keeper = if domain_pool_flag then Domain_pool_ref.get () else None in
    let bump_fork_outcome outcome =
      (* Label order mirrors the other [keeper_supervisor.ml] inc_counter
         call sites ([keeper] first, then the discriminator).  Prometheus
         label-set keys are order-sensitive, so a single per-metric
         convention prevents accidental time-series splitting when new
         call sites add the same labels in a different order. *)
      Prometheus.inc_counter
        Keeper_metrics.metric_keeper_domain_pool_fork
        ~labels:[ "keeper", meta.name; "outcome", outcome ]
        ()
    in
    let fork_body body =
      match pool_for_keeper with
      | Some pool ->
        bump_fork_outcome "pool";
        Eio.Fiber.fork ~sw:ctx.sw (fun () ->
          let run_body_as_result () =
            try Ok (body ()) with
            | Eio.Cancel.Cancelled _ as e -> raise e
            | exn -> Error (exn, Printexc.get_raw_backtrace ())
          in
          match
            try Ok (Domain_pool.submit_io pool run_body_as_result) with
            | Eio.Cancel.Cancelled _ as e -> raise e
            | exn -> Error exn
          with
          | Ok (Ok ()) -> ()
          | Ok (Error (exn, bt)) ->
            bump_fork_outcome "body_failed";
            Log.Keeper.warn
              "keeper supervise pool body failed: keeper=%s err=%s"
              meta.name
              (Printexc.to_string exn);
            Printexc.raise_with_backtrace exn bt
          | Error exn ->
            bump_fork_outcome "submit_failed";
            Log.Keeper.warn
              "keeper supervise pool submit failed, running inline: keeper=%s err=%s"
              meta.name
              (Printexc.to_string exn);
            body ())
      | None ->
        bump_fork_outcome
          (if domain_pool_flag then "inline_no_pool" else "inline_disabled");
        Eio.Fiber.fork ~sw:ctx.sw body
    in
    fork_body (fun () ->
      let resolved = ref false in
      let resolve_done value =
        if (not !resolved) && Keeper_registry.try_resolve_done reg value
        then (
          resolved := true;
          true)
        else false
      in
      Eio_guard.protect
        (fun () ->
           try
             (* RFC-0125 P4: opt-in keeper-level max-turn watchdog.
                When [MASC_KEEPER_MAX_TURN_WATCHDOG_TIMEOUT_SEC] is set
                to a positive float, race the keepalive loop against
                [Eio.Time.sleep ctx.clock t] via [Eio.Fiber.first].
                Timer expiry stamps
                [Stale_turn_timeout (In_turn_hung ...)] BEFORE the
                timer fiber returns so the existing watchdog_triggered
                branch (below) treats the cancellation as a crash and
                [sweep_and_recover] restarts the keeper. Default
                disabled — opt-in. *)
             (match
                Env_config_runtime.Keeper_max_turn_watchdog.timeout_sec_opt
                  ()
              with
              | None ->
                Keeper_keepalive.run_heartbeat_loop
                  ~proactive_warmup_sec
                  ctx
                  meta
                  reg.fiber_stop
                  ~wakeup:reg.fiber_wakeup
              | Some timeout_s ->
                Eio.Fiber.first
                  (fun () ->
                    Eio.Time.sleep ctx.clock timeout_s;
                    Keeper_registry.set_failure_reason
                      ~base_path
                      meta.name
                      (Some
                         (Keeper_registry.Stale_turn_timeout
                            (Keeper_registry_types.In_turn_hung
                               { active_seconds = timeout_s
                               ; timeout_threshold = timeout_s
                               })));
                    Log.Keeper.warn
                      "%s: max-turn watchdog fired after %.1fs (RFC-0125 P4)"
                      meta.name
                      timeout_s)
                  (fun () ->
                    Keeper_keepalive.run_heartbeat_loop
                      ~proactive_warmup_sec
                      ctx
                      meta
                      reg.fiber_stop
                      ~wakeup:reg.fiber_wakeup));
             (* Check if watchdog set a failure reason that should trigger
              crash recovery instead of a clean stop. When the stale
              watchdog sets fiber_stop + Stale_turn_timeout, the heartbeat
              loop exits normally but the supervisor must treat this as a
              crash so sweep_and_recover restarts the keeper. Storm and
              budget-loop cohorts still route to auto-pause; legacy
              Stale_fleet_batch remains a watchdog signal but no longer
              pauses the keeper. *)
             let watchdog_triggered =
               match Keeper_registry.get ~base_path meta.name with
               | Some e ->
                 (match e.last_failure_reason with
                  | Some (Keeper_registry.Stale_turn_timeout _)
                  | Some (Keeper_registry.Stale_termination_storm _)
                  | Some (Keeper_registry.Stale_fleet_batch _)
                  | Some (Keeper_registry.Oas_timeout_budget_loop _) -> true
                  (* Other failure reasons are not stale-watchdog signals. *)
                  | Some (Keeper_registry.Heartbeat_consecutive_failures _)
                  | Some (Keeper_registry.Turn_consecutive_failures _)
                  | Some (Keeper_registry.Provider_runtime_error _)
                  | Some (Keeper_registry.Tool_required_unsatisfied _)
                  | Some (Keeper_registry.Ambiguous_partial_commit _)
                  | Some Keeper_registry.Fiber_unresolved
                  | Some (Keeper_registry.Exception _)
                  | None -> false)
               | None -> false
             in
             if watchdog_triggered
             then (
               let reason =
                 match Keeper_registry.get ~base_path meta.name with
                 | Some e ->
                   Option.map
                     Keeper_registry.failure_reason_to_string
                     e.last_failure_reason
                   |> Option.value ~default:"stale_turn_timeout"
                 | None -> "stale_turn_timeout"
	               in
	               let outcome =
	                 Keeper_registry.enrich_fiber_unresolved_outcome
	                   ~base_path
	                   ~keeper_name:meta.name
	                   reason
	               in
	               (match
	                  Keeper_registry.dispatch_event
	                    ~base_path
	                    meta.name
	                    (Keeper_state_machine.Fiber_terminated { outcome; provider_id = None; http_status = None })
	                with
                | Ok _ -> ()
                | Error e ->
                  Prometheus.inc_counter
                    Keeper_metrics.metric_keeper_dispatch_event_failures
                    ~labels:[ "keeper", meta.name; "event", "fiber_terminated" ]
                    ();
                  Log.Keeper.warn
                    "supervisor: Fiber_terminated dispatch failed: %s"
                    (Keeper_state_machine.transition_error_to_string e));
               if resolve_done (`Crashed reason)
               then
                 publish_phase_lifecycle
                   ~phase:Keeper_state_machine.Crashed
                   meta.name
                   reason
                   ())
             else (
               (* Normal exit: stop flag was set — dispatch typed events *)
               (match
                  Keeper_registry.dispatch_event
                    ~base_path
                    meta.name
                    Keeper_state_machine.Stop_requested
                with
                | Ok _ -> ()
                | Error e ->
                  Prometheus.inc_counter
                    Keeper_metrics.metric_keeper_dispatch_event_failures
                    ~labels:[ "keeper", meta.name; "event", "stop_requested" ]
                    ();
                  Log.Keeper.warn
                    "supervisor: Stop_requested dispatch failed: %s"
                    (Keeper_state_machine.transition_error_to_string e));
               (match
                  Keeper_registry.dispatch_event
                    ~base_path
                    meta.name
                    Keeper_state_machine.Drain_complete
                with
                | Ok _ -> ()
                | Error e ->
                  Prometheus.inc_counter
                    Keeper_metrics.metric_keeper_dispatch_event_failures
                    ~labels:[ "keeper", meta.name; "event", "drain_complete" ]
                    ();
                  Log.Keeper.warn
                    "supervisor: Drain_complete dispatch failed: %s"
                    (Keeper_state_machine.transition_error_to_string e));
               if resolve_done `Stopped
               then
                 publish_phase_lifecycle
                   ~phase:Keeper_state_machine.Stopped
                   meta.name
                   "normal exit"
                   ())
           with
           | Eio.Cancel.Cancelled _ as e -> raise e
           | exn ->
             (* RFC-0002: unified crash handler.
                Keeper_fiber_crash carries no payload — failure_reason is
                pre-stored in registry by the raise site.
                For unexpected exceptions, wrap in Exception variant. *)
             let fr =
               match exn with
               | Keeper_registry.Keeper_fiber_crash ->
                 (match Keeper_registry.get ~base_path meta.name with
                  | Some e ->
                    Option.value
                      ~default:(Keeper_registry.Exception "fiber_crash")
                      e.last_failure_reason
                  | None -> Keeper_registry.Exception "fiber_crash (unregistered)")
               | _ -> Keeper_registry.Exception (Printexc.to_string exn)
	             in
	             let reason = Keeper_registry.failure_reason_to_string fr in
	             let outcome =
	               Keeper_registry.enrich_fiber_unresolved_outcome
	                 ~base_path
	                 ~keeper_name:meta.name
	                 reason
	             in
	             Keeper_registry.set_failure_reason ~base_path meta.name (Some fr);
	             (match
	                Keeper_registry.dispatch_event
	                  ~base_path
	                  meta.name
	                  (Keeper_state_machine.Fiber_terminated { outcome; provider_id = None; http_status = None })
	              with
              | Ok _ -> ()
              | Error e ->
                Prometheus.inc_counter
                  Keeper_metrics.metric_keeper_dispatch_event_failures
                  ~labels:[ "keeper", meta.name; "event", "fiber_terminated" ]
                  ();
                Log.Keeper.warn
                  "supervisor: Fiber_terminated dispatch failed: %s"
                  (Keeper_state_machine.transition_error_to_string e));
             let ts = Time_compat.now () in
             Keeper_registry.record_crash ~base_path meta.name ts reason;
             let rc =
               match Keeper_registry.get ~base_path meta.name with
               | Some e -> e.restart_count
               | None -> 0
             in
             Keeper_crash_persistence.enqueue_record
               ~keepers_dir
               ~name:meta.name
               ~ts
               ~reason
               ~restart_count:rc;
             Keeper_registry.record_error ~base_path meta.name reason;
             if resolve_done (`Crashed reason)
             then
               publish_phase_lifecycle
                 ~phase:Keeper_state_machine.Crashed
                 meta.name
                 reason
                 ())
        ~finally:(fun () ->
          (* Finally runs best-effort. Any exception raised here (including
           Eio.Cancel.Cancelled, which propagates during concurrent fiber
           teardown) would be re-wrapped by [Fun.protect] as
           [Fun.Finally_raised], masking the original body exception and
           crashing the server (see masc-mcp crash 2026-04-17). Swallow
           everything and log — cleanup is advisory, state-machine events
           already fired on the body's happy/error paths. *)
          try
            Keeper_registry.cleanup_tracking ~base_path meta.name;
            (* #14187 follow-up: a keeper that crashed after exhausting its
             turn-livelock budget would restart into the same turn_id
             (because blocked turns do not increment total_turns).  The
             in-memory livelock state then immediately re-blocked the
             fresh restart, making recovery impossible.  Clear the
             per-keeper livelock bookkeeping during cleanup so the next
             restart starts with a fresh counter. *)
            Keeper_turn_livelock.reset_keeper_livelock ~keeper:meta.name;
            if not !resolved
            then
              if Shutdown.is_shutting_down_global ()
              then (
                Log.Keeper.warn
                  "%s: fiber unresolved during shutdown (not a crash)"
                  meta.name;
                Keeper_registry.mark_dead ~base_path meta.name ~at:(Time_compat.now ());
                ignore (resolve_done (`Crashed "shutdown")))
              else (
	                let reason =
	                  Keeper_registry.failure_reason_to_string
	                    Keeper_registry.Fiber_unresolved
	                in
	                let outcome =
	                  Keeper_registry.enrich_fiber_unresolved_outcome
	                    ~base_path
	                    ~keeper_name:meta.name
	                    reason
	                in
	                Keeper_registry.set_failure_reason
	                  ~base_path
                  meta.name
                  (Some Keeper_registry.Fiber_unresolved);
                (* 2026-05-05 fleet-stuck cycle: keeper meta runtime
                 [last_blocker] stayed null for 5+ hours while supervisor
                 self-preservation suppressed restarts under
                 [cohort=fiber_unresolved].  The diagnosis was buried in the
                 crash registry but invisible on the per-keeper meta surface
                 dashboards read.  Stamp the same cohort onto runtime so
                 operators (and the dashboard "차단된 키퍼" card) see why a
                 keeper is silent.  Best-effort: write_meta failure does not
                 abort cleanup, mirroring [handle_crash_auto_pause]. *)
                (match Keeper_registry.get ~base_path meta.name with
                 | Some entry ->
                   let stamped_meta =
                     { entry.meta with
                       runtime =
                         { entry.meta.runtime with
                           last_blocker =
                             Some
                               (blocker_info_of_class
                                  ~detail:"fiber_unresolved"
                                  Fiber_unresolved)
                         }
                     }
                   in
                   (match
                      write_meta_with_merge
                        ~merge:Keeper_meta_merge.heartbeat_fields_from_disk
                        ctx.config
                        stamped_meta
                    with
                    | Ok () -> ()
                    | Error err ->
                      Prometheus.inc_counter
                        Keeper_metrics.metric_keeper_write_meta_failures
                        ~labels:[ "keeper", meta.name; "phase", "fiber_unresolved_stamp" ]
                        ();
                      Log.Keeper.warn
                        "%s: fiber_unresolved meta stamp failed: %s"
                        meta.name
                        err)
                 | None -> ());
                let ts = Time_compat.now () in
                Keeper_registry.record_crash ~base_path meta.name ts reason;
                let rc =
                  match Keeper_registry.get ~base_path meta.name with
                  | Some e -> e.restart_count
                  | None -> 0
                in
                Keeper_crash_persistence.enqueue_record
                  ~keepers_dir
                  ~name:meta.name
                  ~ts
                  ~reason
                  ~restart_count:rc;
                Keeper_registry.record_error ~base_path meta.name reason;
	                Keeper_registry.dispatch_event_unit
	                  ~base_path
	                  meta.name
	                  (Keeper_state_machine.Fiber_terminated { outcome; provider_id = None; http_status = None });
                if resolve_done (`Crashed reason)
                then
                  publish_phase_lifecycle
                    ~phase:Keeper_state_machine.Crashed
                    meta.name
                    reason
                    ())
          with
          | Eio.Cancel.Cancelled _ ->
            (* Swallow cleanup cancellation without incrementing the cleanup
             failure counter. Re-raising Cancelled here is what the docstring
             above warns against: [Fun.protect] would wrap it as
             [Fun.Finally_raised], masking the body exception and crashing
             the supervisor. See 2026-05-05 cycle9 incident: 5+ FATALs/day
             traced to a re-raise at this exact site (commit bb10b80ee4
             leftover from #12910 revert). *)
            Log.Keeper.debug
              "%s: supervisor finally cleanup cancelled (suppressed to avoid \
               Fun.Finally_raised)"
              meta.name
          | exn ->
            (* Swallow non-cancellation cleanup failures too. Cleanup is
             advisory; re-raising here would still become [Fun.Finally_raised]
             and could mask the body outcome. Count only these unexpected
             cleanup exceptions so the metric remains actionable. *)
            Prometheus.inc_counter
              Keeper_metrics.metric_keeper_supervisor_cleanup_failures
              ~labels:[ "keeper", meta.name ]
              ();
            Log.Keeper.warn
              "%s: supervisor finally cleanup failed (suppressed to avoid \
               Fun.Finally_raised): %s"
              meta.name
              (Printexc.to_string exn))))
;;

(* #10993: persona drift visibility.

   [Keeper_identity.normalize_all_names ~check_persona:true] runs on
   every dispatch via [Tool_inline_dispatch_coord] (RFC P3-a
   logging-only mode), but its [Persona_not_found] branch emits a
   Log.Misc.warn that is hard to triage:

   - WARN level (alert ROC blends with normal degradation noise).
   - Per-event (24h sample: 11 events × 5 keepers vs the underlying
     truth of 9 keepers permanently mis-configured), so operators can
     not tell whether the gap is widening or stable.
   - Lacks the per-keeper startup snapshot that would let an operator
     run a quick \[ls personas/\] and reconcile.

   Surface the gap once at supervise_keepalive entry — the code path
   that actually puts the keeper into the registry. Behaviour is
   unchanged (still proceeds with fallback) so the boot path stays
   compatible with the current 9-missing-personas fleet; the value is
   in turning a silent runtime drift into a single ERROR per keeper
   per supervisor restart.

   The visibility ERROR is bounded by fleet size (~14 keepers) and
   only fires on first registration — the [is_registered] guard above
   skips repeat calls. *)
let persona_name_for_drift_check = Startup_helpers.persona_name_for_drift_check
let persona_profile_path_for_drift_check =
  Startup_helpers.persona_profile_path_for_drift_check
;;

let log_persona_drift_if_missing = Startup_helpers.log_persona_drift_if_missing

let supervise_keepalive ~proactive_warmup_sec (ctx : _ context) (meta : keeper_meta) =
  if Keeper_registry.is_registered ~base_path:ctx.config.base_path meta.name
  then ()
  else
    match Keeper_registry.spawn_slots_decision ~base_path:ctx.config.base_path () with
    | Error reason ->
      Keeper_registry.record_spawn_slot_denied ~keeper_name:meta.name ~surface:"supervisor" reason;
      publish_lifecycle
        ~event:
          (Keeper_lifecycle_events.Custom_event
             { verb = Keeper_lifecycle_events.Admission_denied
             ; phase = Some Keeper_state_machine.Offline
             })
        meta.name
        (Keeper_registry.spawn_slot_denial_reason_to_detail reason)
        ()
    | Ok () -> (
    log_persona_drift_if_missing ~base_path:ctx.config.base_path meta;
    (* Register in Keeper_registry — single source of truth. *)
    let reg =
      Keeper_registry.register_offline ~base_path:ctx.config.base_path meta.name meta
    in
    (* Coord initialization *)
    (try
       if not (Coord_utils.is_initialized ctx.config)
       then (
         let (_init_msg : string) = Coord.init ctx.config ~agent_name:None in
         ())
     with
     | Eio.Cancel.Cancelled _ as e -> raise e
     | exn ->
       Prometheus.inc_counter
         Keeper_metrics.metric_keeper_room_init_failures
         ~labels:[ "keeper", meta.name ]
         ();
       Log.Keeper.error "supervisor room init failed: %s" (Printexc.to_string exn));
    let live_meta =
      try
        let synced = ensure_keeper_room_presence ctx.config meta in
        (match write_meta ctx.config synced with
         | Ok () -> ()
         | Error msg ->
           Prometheus.inc_counter
             Keeper_metrics.metric_keeper_write_meta_failures
             ~labels:[ "keeper", meta.name; "phase", "presence_sync" ]
             ();
           Log.Keeper.warn
             "supervisor presence sync: write_meta failed for %s: %s"
             meta.name
             msg);
        synced
      with
      | Eio.Cancel.Cancelled _ as e -> raise e
      | exn ->
        Prometheus.inc_counter
          Keeper_metrics.metric_keeper_presence_sync_failures
          ~labels:[ "keeper", meta.name ]
          ();
        Log.Keeper.error "supervisor presence sync failed: %s" (Printexc.to_string exn);
        meta
    in
    Keeper_registry.update_meta ~base_path:ctx.config.base_path meta.name live_meta;
    launch_supervised_fiber ~proactive_warmup_sec ctx live_meta reg;
    publish_lifecycle
      ~event:
        (Keeper_lifecycle_events.Custom_event
           { verb = Keeper_lifecycle_events.Started
           ; phase = Some Keeper_state_machine.Running
           })
      meta.name
      "supervised"
      ())
;;

let resume_keeper_after_reconcile_gate (ctx : _ context) (meta : keeper_meta) =
  let latest_meta =
    match read_meta ctx.config meta.name with
    | Ok (Some latest) -> latest
    | _ -> meta
  in
  let resumed_meta =
    { latest_meta with
      paused = false
    ; updated_at = now_iso ()
    ; runtime = { latest_meta.runtime with last_blocker = None }
    }
  in
  (* #9733: same race shape as keeper_msg/overflow-pause/sync paths
     already migrated by #10135 / #10145.  The supervisor reconcile
     fiber clears [paused] and [runtime.last_blocker] (cycle-owned
     fields); a heartbeat fiber bumping [joined_room_ids] /
     [last_seen_seq_by_room] in parallel can still steal the CAS
     write and silently leave the keeper paused while
     [Keeper_registry.update_meta] applies the resume in-memory —
     a registry/disk split that hides the failure. *)
  (match
     write_meta_with_merge
       ~merge:Keeper_meta_merge.heartbeat_fields_from_disk
       ctx.config
       resumed_meta
   with
   | Ok () -> ()
   | Error err when is_version_conflict_error err ->
     Prometheus.inc_counter
       Keeper_metrics.metric_keeper_write_meta_failures
       ~labels:[ "keeper", resumed_meta.name; "phase", "reconcile_resume_cas_race" ]
       ();
     Log.Keeper.warn
       "%s: reconcile gate resume write_meta lost CAS race after retries: %s"
       resumed_meta.name
       err
   | Error err ->
     Prometheus.inc_counter
       Keeper_metrics.metric_keeper_write_meta_failures
       ~labels:[ "keeper", resumed_meta.name; "phase", "reconcile_resume" ]
       ();
     Log.Keeper.error
       "%s: reconcile gate resume write_meta failed: %s"
       resumed_meta.name
       err);
  Keeper_registry.update_meta
    ~base_path:ctx.config.base_path
    resumed_meta.name
    resumed_meta;
  Keeper_registry.set_failure_reason
    ~base_path:ctx.config.base_path
    resumed_meta.name
    None;
  Keeper_registry.reset_turn_failures ~base_path:ctx.config.base_path resumed_meta.name;
  Keeper_turn_livelock.reset_keeper_livelock ~keeper:resumed_meta.name;
  Keeper_registry.dispatch_event_unit
    ~base_path:ctx.config.base_path
    resumed_meta.name
    Keeper_state_machine.Operator_resume;
  match Keeper_registry.get ~base_path:ctx.config.base_path resumed_meta.name with
  | Some entry when Option.is_none (Eio.Promise.peek entry.done_p) ->
    (* tla-lint: allow-mutation: fiber signal — wake the keeper after operator resume *)
    Atomic.set entry.fiber_wakeup true
  | Some _ ->
    Keeper_registry.unregister ~base_path:ctx.config.base_path resumed_meta.name;
    supervise_keepalive ~proactive_warmup_sec:0 ctx resumed_meta
  | None -> supervise_keepalive ~proactive_warmup_sec:0 ctx resumed_meta
;;

let restore_reconcile_continue_gate (ctx : _ context) (meta : keeper_meta) =
  let blocker_detail, blocker_klass =
    match meta.runtime.last_blocker with
    | Some info -> String.trim info.detail, Some info.klass
    | None -> "", None
  in
  let committed_tools = committed_tools_of_ambiguous_blocker blocker_detail in
  let failure_reason =
    match blocker_klass with
    | Some Ambiguous_post_commit_timeout ->
      "ambiguous_partial_commit(post_commit_timeout)"
    | Some Ambiguous_post_commit_failure ->
      "ambiguous_partial_commit(post_commit_failure)"
    | Some _ | None -> "ambiguous_partial_commit(post_commit_failure)"
  in
  let blocker = blocker_detail in
  let input =
    `Assoc
      [ "kind", `String "reconcile_required"
      ; "keeper_name", `String meta.name
      ; "failure_reason", `String failure_reason
      ; "error_detail", `String blocker
      ; "committed_tools", `List (List.map (fun tool -> `String tool) committed_tools)
      ]
  in
  let _approval_id =
    Keeper_approval_queue.submit_pending
      ~keeper_name:meta.name
      ~tool_name:"keeper_continue_after_reconcile"
      ~input
      ~risk_level:Keeper_approval_queue.Critical
      ~base_path:ctx.config.base_path
      ~on_resolution:(fun decision ->
        match decision with
        | Agent_sdk.Hooks.Approve | Agent_sdk.Hooks.Edit _ ->
          resume_keeper_after_reconcile_gate ctx meta;
          Log.Keeper.info
            "%s: restored reconcile continue gate approved; keeper resumed"
            meta.name
        | Agent_sdk.Hooks.Reject reason ->
          Log.Keeper.warn
            "%s: restored reconcile continue gate rejected; keeper remains paused (%s)"
            meta.name
            reason;
          Prometheus.inc_counter
            Keeper_metrics.metric_keeper_supervisor_cleanup_failures
            ~labels:
              [ "keeper", meta.name
              ; ( "site"
                , Keeper_supervisor_cleanup_failure_site.(to_label Reconcile_gate_rejected) )
              ]
            ())
      ()
  in
  Log.Keeper.warn
    "%s: restored reconcile continue gate from persisted paused meta"
    meta.name
;;

(* ── Sweep and recover ───────────────────────────────────── *)

(** Reconcile only orphaned or cleanly stopped durable keepers.
    Running/Paused/Crashed/Dead entries are actively managed by sweep
    and must NOT be re-launched by reconcile. Stopped entries with
    unresolved fibers (done_p = None) are also skipped — sweep will
    handle them once the fiber terminates. *)
let reconcile_keepalive_keepers (ctx : _ context) =
  let base_path = ctx.config.base_path in
  let names = Keeper_types.keepalive_keeper_names ctx.config in
  Log.Keeper.debug
    "reconcile_keepalive_keepers: started (candidates=%d)"
    (List.length names);
  let t0 = Time_compat.now () in
  let reconcile_ym = Eio_guard.create_yield_meter () in
  List.iter
    (fun name ->
       (match read_meta ctx.config name with
        | Ok (Some meta) when not meta.paused ->
          let dominated_by_sweep =
            match Keeper_registry.get ~base_path meta.name with
            | None -> false (* no entry = orphaned, reconcile OK *)
            | Some e ->
              (match e.phase with
               | Keeper_state_machine.Running | Keeper_state_machine.Paused -> true
               | Keeper_state_machine.Crashed
               | Keeper_state_machine.Dead
               | Keeper_state_machine.Zombie -> true
               | Keeper_state_machine.Failing
               | Keeper_state_machine.Overflowed
               | Keeper_state_machine.Compacting
               | Keeper_state_machine.HandingOff
               | Keeper_state_machine.Draining
               | Keeper_state_machine.Restarting -> true
               | Keeper_state_machine.Offline -> false
               | Keeper_state_machine.Stopped ->
                 (* Stopped with unresolved fiber → sweep will clean up *)
                 Eio.Promise.peek e.done_p = None)
          in
          if not dominated_by_sweep
          then (
            supervise_keepalive ~proactive_warmup_sec:0 ctx meta;
            if Keeper_registry.is_running ~base_path meta.name
            then (
              publish_lifecycle
                ~event:
                  (Keeper_lifecycle_events.Custom_event
                     { verb = Keeper_lifecycle_events.Reconciled
                     ; phase = Some Keeper_state_machine.Running
                     })
                meta.name
                "durable keeper"
                ();
              Log.Keeper.info "%s: reconciled durable keeper" meta.name))
        | Ok (Some _meta) -> () (* paused, skip *)
        | Ok None -> ()
        | Error err ->
          Prometheus.inc_counter
            Keeper_metrics.metric_keeper_observation_query_failures
            ~labels:
              [ ("operation", Keeper_observation_query_operation.(to_label Reconcile_read_meta))
              ]
            ();
          Log.Keeper.warn "reconcile: read_meta failed for %s: %s" name err);
       Eio_guard.yield_step reconcile_ym)
    names;
  Log.Keeper.debug
    "reconcile_keepalive_keepers: completed (elapsed_ms=%d)"
    (int_of_float ((Time_compat.now () -. t0) *. 1000.0))
;;

let cleanup_dead_tombstone (ctx : _ context) (entry : Keeper_registry.registry_entry) =
  match read_meta ctx.config entry.name with
  | Ok (Some meta) ->
    let persisted_paused =
      if meta.paused
      then true
      else (
        (* #9733: dead tombstone cleanup writes [paused = true] —
             cycle-owned field — while heartbeat fibers can still
             update the same record's heartbeat-owned fields.  Use
             the same merged-CAS retry as the resume + overflow-pause
             paths so a parallel heartbeat write doesn't make this
             write fail and leave the keeper unpaused on disk while
             the supervisor proceeds to unregister it. *)
        match
          write_meta_with_merge
            ~merge:Keeper_meta_merge.heartbeat_fields_from_disk
            ctx.config
            { meta with paused = true }
        with
        | Ok () -> true
        | Error err when is_version_conflict_error err ->
          Prometheus.inc_counter
            Keeper_metrics.metric_keeper_write_meta_failures
            ~labels:[ "keeper", entry.name; "phase", "dead_cleanup_cas_race" ]
            ();
          Log.Keeper.warn
            "%s: dead tombstone cleanup paused write lost CAS race after retries: %s"
            entry.name
            err;
          false
        | Error err ->
          Prometheus.inc_counter
            Keeper_metrics.metric_keeper_write_meta_failures
            ~labels:[ "keeper", entry.name; "phase", "dead_cleanup" ]
            ();
          Log.Keeper.warn
            "%s: dead tombstone cleanup paused write failed: %s"
            entry.name
            err;
          false)
    in
    Keeper_registry.unregister ~base_path:ctx.config.base_path entry.name;
    Keeper_tool_emission_hook.drop_keeper_accumulator entry.name;
    if persisted_paused
    then (
      publish_lifecycle
        ~event:
          (Keeper_lifecycle_events.Custom_event
             { verb = Keeper_lifecycle_events.Dead_cleaned; phase = None })
        entry.name
        "paused meta persisted"
        ();
      Log.Keeper.info "%s: dead tombstone cleaned up" entry.name)
    else (
      publish_lifecycle
        ~event:
          (Keeper_lifecycle_events.Custom_event
             { verb = Keeper_lifecycle_events.Dead_cleaned; phase = None })
        entry.name
        "meta write failed, unregistered anyway"
        ();
      Log.Keeper.warn
        "%s: dead tombstone unregistered despite meta write failure"
        entry.name;
      Prometheus.inc_counter
        Keeper_metrics.metric_keeper_supervisor_cleanup_failures
        ~labels:
          [ "keeper", entry.name
          ; ("site", Keeper_supervisor_cleanup_failure_site.(to_label Dead_tombstone_meta_write))
          ]
        ())
  | Ok None ->
    Keeper_registry.unregister ~base_path:ctx.config.base_path entry.name;
    Keeper_tool_emission_hook.drop_keeper_accumulator entry.name;
    publish_lifecycle
      ~event:
        (Keeper_lifecycle_events.Custom_event
           { verb = Keeper_lifecycle_events.Dead_cleaned; phase = None })
      entry.name
      "meta missing"
      ();
    Log.Keeper.warn "%s: dead tombstone unregistered (meta missing)" entry.name;
    Prometheus.inc_counter
      Keeper_metrics.metric_keeper_supervisor_cleanup_failures
      ~labels:
        [ "keeper", entry.name
        ; ("site", Keeper_supervisor_cleanup_failure_site.(to_label Dead_tombstone_meta_missing))
        ]
      ()
  | Error err ->
    Keeper_registry.unregister ~base_path:ctx.config.base_path entry.name;
    Keeper_tool_emission_hook.drop_keeper_accumulator entry.name;
    publish_lifecycle
      ~event:
        (Keeper_lifecycle_events.Custom_event
           { verb = Keeper_lifecycle_events.Dead_cleaned; phase = None })
      entry.name
      (Printf.sprintf "meta read error: %s" err)
      ();
    Log.Keeper.warn "%s: dead tombstone unregistered (meta error: %s)" entry.name err;
    Prometheus.inc_counter
      Keeper_metrics.metric_keeper_supervisor_cleanup_failures
      ~labels:
        [ "keeper", entry.name
        ; ("site", Keeper_supervisor_cleanup_failure_site.(to_label Dead_tombstone_meta_error))
        ]
      ()
;;

(** Cohort key from structured failure_reason ADT.
    #10584: delegates to [Keeper_registry.failure_reason_cohort_key] so a
    new variant in keeper_registry forces a same-PR converter update via
    the source module's exhaustive-match check, instead of breaking main
    here on first build (the recurring P0 pattern from #10490 + #10574). *)

(* #10887: persistent self-preservation lock.  Fleet log shows 125
   identical [ratio=1.00, cohort=stale_turn_timeout] events / 2 days
   with no escape — every sweep re-suppresses the same dominant
   cohort because [apply_self_preservation] is stateless across calls.
   Without an escape valve, a transient cohort (token rotation lag,
   cascade.toml fix mid-flight, etc.) keeps the fleet locked even
   after the underlying condition has cleared.

   Add a probe: after [probe_after_n_suppressions] consecutive
   suppressions of the same dominant cohort, allow ONE keeper from
   the cohort to attempt restart.  If the underlying condition has
   cleared, the keeper survives → it stops appearing in [to_restart]
   on subsequent sweeps → counter naturally resets via "different
   dominant cohort or no suppression at all".  If the condition
   persists, the keeper crashes again, lands back in the next
   sweep's [to_restart] with the same cohort, and the counter
   resumes. *)
type sp_escape_state =
  { mutable last_dominant_cohort : string
  ; mutable consecutive_suppressions : int
  }

let sp_escape_state = { last_dominant_cohort = ""; consecutive_suppressions = 0 }

(** Probe cadence.  10 sweeps × default 30s sweep interval = 5
    minute probe — long enough that genuine systemic issues aren't
    probed back into life every cycle, short enough that a transient
    cohort clears within 1-2 probes once the root condition is fixed.
    Code constant rather than env knob per
    [feedback_no-hyperparameter-as-env-knob] — this is calibration,
    not operator policy. *)
let probe_after_n_suppressions = 10

(** Bounded minority exception for partial stale recovery.

    The live regression was 6/17 keepers: enough to trip the global
    self-preservation ratio gate, but not a fleet-wide provider/cascade
    storm.  Keep this below a majority so large-but-not-universal stale
    cohorts still go through the circuit breaker/probe path. *)
let partial_stale_recovery_max_ratio = 0.50

(** Reset the escape-valve state.  Test-only; production code never
    needs to call this (state cycles through the [last_dominant_cohort]
    inequality branch naturally). *)
let reset_self_preservation_escape_state_for_test () =
  sp_escape_state.last_dominant_cohort <- "";
  sp_escape_state.consecutive_suppressions <- 0
;;


(** Self-preservation gate. Suppresses restarts when a dominant failure
    cohort exceeds ratio threshold AND minimum candidate count.
    Bounded minority [stale_turn_timeout] cohorts are allowed through so
    alive-but-stuck recovery can drain partial slot starvation; larger stale
    cohorts still use the circuit breaker/probe path.
    #10887: emits a probe restart every [probe_after_n_suppressions]
    consecutive suppressions of the same cohort. *)
let apply_self_preservation ~keepers_dir ~total_keepers to_restart =
  let sp_ratio = Env_config.KeeperSupervisor.self_preservation_ratio in
  let sp_min = Env_config.KeeperSupervisor.self_preservation_min_candidates in
  let n_candidates = List.length to_restart in
  let n_total = max 1 total_keepers in
  let ratio = float_of_int n_candidates /. float_of_int n_total in
  if ratio > sp_ratio && n_candidates >= sp_min
  then (
    (* Group by failure_reason ADT variant (not string prefix) *)
    let insert_cohort acc (entry : Keeper_registry.registry_entry) _msg =
      let key = cohort_key_of_reason entry.last_failure_reason in
      let prev = StringMap.find_opt key acc |> Option.value ~default:[] in
      StringMap.add key ((entry, _msg) :: prev) acc
    in
    let cohorts =
      List.fold_left
        (fun acc ((e, m) : _ * string) -> insert_cohort acc e m)
        StringMap.empty
        to_restart
    in
    let dominant_key, dominant_entries =
      StringMap.fold
        (fun k v (best_k, best_v) ->
           if List.length v > List.length best_v then k, v else best_k, best_v)
        cohorts
        ("", [])
    in
    if List.length dominant_entries >= sp_min
    then (
      let dominant_count = List.length dominant_entries in
      let dominant_ratio = float_of_int dominant_count /. float_of_int n_total in
      if
        String.equal dominant_key stale_turn_timeout_cohort_key
        && dominant_ratio <= partial_stale_recovery_max_ratio
      then (
        reset_self_preservation_escape_state_for_test ();
        Log.Keeper.warn
          "self-preservation: allowing partial stale_turn_timeout recovery cohort \
           through (dominant=%d/%d ratio_dominant=%.2f, overall_candidates=%d/%d \
           ratio_overall=%.2f)"
          dominant_count
          n_total
          dominant_ratio
          n_candidates
          n_total
          ratio;
        to_restart)
      else (
        (* #10887: track consecutive suppressions of the same dominant
         cohort.  Different cohort -> counter resets to 1; same
         cohort -> counter increments. *)
        if String.equal sp_escape_state.last_dominant_cohort dominant_key
        then
          sp_escape_state.consecutive_suppressions
          <- sp_escape_state.consecutive_suppressions + 1
        else (
          sp_escape_state.last_dominant_cohort <- dominant_key;
          sp_escape_state.consecutive_suppressions <- 1);
        let probe_due =
          sp_escape_state.consecutive_suppressions >= probe_after_n_suppressions
        in
        let probe_entry =
          if probe_due
          then (
            match dominant_entries with
            | (e, _) :: _ -> Some e.Keeper_registry.name
            | [] -> None)
          else None
        in
        let suppressed_names =
          List.filter_map
            (fun ((e : Keeper_registry.registry_entry), _) ->
               match probe_entry with
               | Some probe_name when String.equal e.name probe_name -> None
               | _ -> Some e.name)
            dominant_entries
        in
        let suppressed_count = List.length suppressed_names in
        (match probe_entry with
         | Some probe_name ->
           (* Probe valve fires — positive signal, fleet is attempting
              auto-recovery.  WARN regardless of ratio. *)
           Log.Keeper.warn
             "self-preservation probe: allowing %s through after %d consecutive \
              same-cohort suppressions (ratio=%.2f, cohort=%s)"
             probe_name
             sp_escape_state.consecutive_suppressions
             ratio
             dominant_key;
           (* Reset the counter so the next probe is also
              [probe_after_n_suppressions] sweeps away. *)
           sp_escape_state.consecutive_suppressions <- 0
         | None ->
           (* #10945 + #10887: split universal (ratio>=0.99) vs partial
              suppression.  Universal = entire fleet sharing one
              cohort = auto-recovery is structurally OFF — log ERROR
              with operator-actionable hint.  Partial = circuit
              breaker working as designed = WARN.  Both lines carry
              [streak=N] so dashboards can show how close the next
              probe valve is. *)
           if ratio >= 0.99
           then (
             Prometheus.inc_counter
               Keeper_metrics.metric_keeper_self_preservation_universal
               ~labels:[ "cohort", dominant_key ]
               ();
             Log.Keeper.error
               "self-preservation: UNIVERSAL suppression %d/%d (ratio=%.2f, cohort=%s, \
                streak=%d) — auto-recovery is OFF until operator clears the shared \
                failure mode (e.g. cascade.toml hot-reload, token rotation, or kill the \
                dominant cohort to let SP release).  Probe valve will allow one keeper \
                through after %d consecutive suppressions.  See #10887 / #10765."
               suppressed_count
               n_total
               ratio
               dominant_key
               sp_escape_state.consecutive_suppressions
               probe_after_n_suppressions)
           else
             Log.Keeper.warn
               "self-preservation: suppressing %d/%d restarts (ratio=%.2f, cohort=%s, \
                streak=%d)"
               suppressed_count
               n_total
               ratio
               dominant_key
               sp_escape_state.consecutive_suppressions);
        publish_lifecycle
          ~event:
            (Keeper_lifecycle_events.Custom_event
               { verb = Keeper_lifecycle_events.Self_preservation; phase = None })
          "supervisor"
          (Printf.sprintf
             "%d/%d suppressed, cohort=%s%s"
             suppressed_count
             n_total
             dominant_key
             (match probe_entry with
              | Some name -> Printf.sprintf ", probe=%s" name
              | None -> ""))
          ();
        Keeper_crash_persistence.enqueue_sp_event
          ~keepers_dir
          ~ts:(Time_compat.now ())
          ~suppressed_count
          ~total:n_total
          ~ratio
          ~dominant_cohort:dominant_key;
        List.filter
          (fun ((e : Keeper_registry.registry_entry), _) ->
             not (List.mem e.name suppressed_names))
          to_restart))
    else (
      (* Dominant cohort below sp_min — no suppression this cycle,
         so the streak no longer applies to this cohort. *)
      reset_self_preservation_escape_state_for_test ();
      to_restart))
  else (
    (* No suppression: streak resets. *)
    reset_self_preservation_escape_state_for_test ();
    to_restart)
;;


(** #10765 Phase 2: persist [meta.paused = true] for a keeper whose stale
    watchdog detected a termination storm (window count >= threshold).  The
    caller must skip enqueuing the entry into [to_restart] so the supervisor
    no longer auto-restarts the keeper into the same dead-cascade environment.

    Ordering rationale: write meta first, then publish lifecycle + counter.
    A failed meta write is logged but does not abort the pause path — the
    in-memory [last_failure_reason] still routes the next sweep through this
    branch, so the supervisor remains correct even if the disk write loses
    a CAS race.  The keeper would re-resume on a server restart in that
    edge case, but that is strictly less bad than the pre-Phase-2 baseline
    (continuous restart loop). *)
type crash_pause_resume_policy =
  | Manual_resume_required
  | Auto_resume_with_backoff

let handle_crash_auto_pause
      (ctx : _ context)
      (entry : Keeper_registry.registry_entry)
      ~reason_tag
      ~metric_name
      ~lifecycle_detail
      ~log_message
      ~blocker_class
      ~resume_policy
  =
  (match read_meta ctx.config entry.name with
   | Ok (Some meta) ->
     let initial_sec = Env_config.KeeperSupervisor.auto_resume_initial_sec in
     let max_sec = Env_config.KeeperSupervisor.auto_resume_max_sec in
     let auto_resume_after_sec =
       match resume_policy with
       | Manual_resume_required -> None
       | Auto_resume_with_backoff ->
         next_auto_resume_after_sec ~initial_sec ~max_sec meta.auto_resume_after_sec
     in
     let blocker_text =
       let existing =
         match meta.runtime.last_blocker with
         | Some info -> String.trim info.detail
         | None -> ""
       in
       if existing <> ""
       then existing
       else (
         match blocker_class with
         | Some cls -> blocker_class_to_string cls
         | None -> reason_tag)
     in
     let blocker_info_opt =
       match blocker_class with
       | Some klass -> Some (blocker_info_of_class ~detail:blocker_text klass)
       | None ->
         (* No typed class available — preserve pre-existing typed
              info if any, otherwise drop the slot.  We refuse to
              silently fabricate a klass from [reason_tag]. *)
         meta.runtime.last_blocker
     in
     (* Task-138 §"Max no-task-progress 30min = release claimed":
          when the supervisor pauses a keeper because the same blocker
          class is looping (stale_storm or oas_timeout_budget_loop),
          the keeper is no longer making progress on its claimed task.
          Releasing [current_task_id] here lets a peer pick the task
          up while this keeper sits in [paused=true] back-off.

          Without this release the diagnostic state is "executor.json:
          current_task_id=task-147, paused=true, last_blocker.klass=
          oas_timeout_budget" — task is stuck forever because (a) this
          keeper cannot run while paused and (b) other keepers see the
          claim and skip.  The released task ID is not separately audited
          here; [last_blocker] in [runtime] already carries the pause
          reason, and Prometheus [keeper_paused_total] is incremented
          below.  Discovered 2026-05-05 fleet-stuck. *)
     (match
        write_meta_with_merge
          ~merge:Keeper_meta_merge.heartbeat_fields_from_disk
          ctx.config
          { meta with
            paused = true
          ; auto_resume_after_sec
          ; updated_at = now_iso ()
          ; current_task_id = None
          ; runtime = { meta.runtime with last_blocker = blocker_info_opt }
          }
      with
      | Ok () -> ()
      | Error err ->
        Prometheus.inc_counter
          Keeper_metrics.metric_keeper_write_meta_failures
          ~labels:[ "keeper", entry.name; "phase", "blocker_pause" ]
          ();
        Log.Keeper.warn
          "%s: %s pause meta write failed (in-memory failure_reason still gates restart, \
           but persisted state will not survive server restart): %s"
          entry.name
          reason_tag
          err)
   | Ok None ->
     Log.Keeper.warn
       "%s: %s pause: meta missing, cannot persist paused=true"
       entry.name
       reason_tag;
     Prometheus.inc_counter
       Keeper_metrics.metric_keeper_write_meta_failures
       ~labels:[ "keeper", entry.name; "phase", "pause_meta_missing" ]
       ()
   | Error err ->
     Log.Keeper.warn "%s: %s pause read_meta failed: %s" entry.name reason_tag err;
     Prometheus.inc_counter
       Keeper_metrics.metric_keeper_write_meta_failures
       ~labels:[ "keeper", entry.name; "phase", "pause_read_meta" ]
       ());
  Prometheus.inc_counter metric_name ~labels:[ "keeper", entry.name ] ();
  publish_phase_lifecycle
    ~phase:Keeper_state_machine.Paused
    entry.name
    lifecycle_detail
    ();
  Log.Keeper.error "%s: %s" entry.name log_message
;;

let handle_stale_storm_pause
      (ctx : _ context)
      (entry : Keeper_registry.registry_entry)
      ~count
  =
  handle_crash_auto_pause
    ctx
    entry
    ~reason_tag:"stale_storm"
    ~metric_name:Keeper_metrics.metric_keeper_stale_storm_paused
    ~lifecycle_detail:(Printf.sprintf "stale_termination_storm count=%d" count)
    ~blocker_class:(Some Turn_timeout)
    ~resume_policy:Manual_resume_required
    ~log_message:
      (Printf.sprintf
         "STALE STORM AUTO-PAUSED (count=%d in 6h window). Auto-resume is disabled \
          until the root cause clears; operator must resume manually via masc_keeper_up \
          or API after investigating the underlying cascade/tool/runtime loop. See \
          issue #10765."
         count)
;;

let handle_oas_timeout_budget_pause
      (ctx : _ context)
      (entry : Keeper_registry.registry_entry)
      ~count
  =
  handle_crash_auto_pause
    ctx
    entry
    ~reason_tag:"oas_timeout_budget_loop"
    ~metric_name:Keeper_metrics.metric_keeper_oas_timeout_budget_loop_paused
    ~lifecycle_detail:(Printf.sprintf "oas_timeout_budget_loop count=%d" count)
    ~blocker_class:(Some Oas_timeout_budget)
    ~resume_policy:Auto_resume_with_backoff
    ~log_message:
      (Printf.sprintf
         "OAS TIMEOUT BUDGET LOOP AUTO-PAUSED (count=%d). Supervisor will attempt \
          self-healing auto-resume with exponential back-off (see \
          MASC_KEEPER_AUTO_RESUME_INITIAL_SEC). Operator may also tune or reroute the \
          cascade/model before resuming manually; restarting into the same slow-provider \
          budget loop is avoided by the back-off delay."
         count)
;;

let failure_reason_policy_decision
      (reason : Keeper_registry.failure_reason option)
  : Keeper_failure_policy.decision option
  =
  match reason with
  | Some (Keeper_registry.Oas_timeout_budget_loop { count }) ->
    Some
      (Keeper_failure_policy.decide
         (Keeper_failure_policy.Oas_timeout_budget
            { phase = None
            ; strikes = Some count
            ; liveness = Keeper_failure_policy.Watchdog_stale
            }))
  | Some (Keeper_registry.Stale_termination_storm { count }) ->
    Some
      (Keeper_failure_policy.decide
         (Keeper_failure_policy.Stale_termination_storm { count }))
  | Some (Keeper_registry.Stale_turn_timeout _) ->
    Some
      (Keeper_failure_policy.decide
         (Keeper_failure_policy.Stale_turn { progress_seen = false }))
  | Some (Keeper_registry.Tool_required_unsatisfied _) ->
    Some
      (Keeper_failure_policy.decide
         Keeper_failure_policy.Required_tool_contract_violation)
  | Some (Keeper_registry.Ambiguous_partial_commit _) ->
    Some (Keeper_failure_policy.decide Keeper_failure_policy.Ambiguous_partial_commit)
  | Some
      ( Keeper_registry.Heartbeat_consecutive_failures _
      | Keeper_registry.Turn_consecutive_failures _
      | Keeper_registry.Stale_fleet_batch _
      | Keeper_registry.Provider_runtime_error _
      | Keeper_registry.Fiber_unresolved
      | Keeper_registry.Exception _ )
  | None ->
    None
;;

let failure_reason_policy_decision_for_test = failure_reason_policy_decision

let sweep_and_recover (ctx : _ context) =
  let now = Time_compat.now () in
  let max_restarts =
    Runtime_params.get Governance_registry.keeper_supervisor_max_restarts
  in
  let dead_ttl_sec = Runtime_params.get Governance_registry.keeper_dead_ttl_sec in
  let base_path = ctx.config.base_path in
  (* Refresh the cascade health cache before Phase 3.5 reads it.  Without this
     call the cache stayed cold (PR #14146 introduced the cache and
     [Phase 3.5] guard but never wired a writer), so every cascade looked
     unhealthy and auto-resume was silently disabled across the fleet.
     [run_once] is a registry scan — bounded, no I/O — so running it
     inline on every 30 s sweep is cheap.  [Safe_ops.protect] keeps a
     transient registry exception from killing the sweep. *)
  Safe_ops.protect ~default:() (fun () -> Keeper_health_probe.run_once ~base_path);
  (* Phase 2: sweep order — restart/unregister FIRST, reconcile LAST.
     This prevents reconcile from re-launching keepers that sweep is about
     to process (defense-in-depth alongside is_registered check). *)
  let entries = Keeper_registry.all ~base_path () in
  (* R-A-6.c / A-7 wire-in: per-sweep snapshot invariant scan.

     Iter 14 audit (`docs/tla-audit/ksm-a6-budget-never-revives-2026-05-12.md`)
     identified that `keeper_invariant_check` was test-only — production
     never invoked it.  Iter 16 (#14758) added [check_snapshot_invariants]
     suitable for sweep-time scans.

     Policy: WARN log per violation.  Intentionally NOT halting the sweep
     or marking-dead — a violation here is a development/migration
     signal, not a runtime emergency.  Metric/alarm escalation is a
     follow-up. *)
  List.iter
    (fun (entry : Keeper_registry.registry_entry) ->
       let vs =
         Keeper_invariant_check.check_snapshot_invariants
           ~phase:entry.phase
           ~conditions:entry.conditions
       in
       List.iter
         (fun (v : Keeper_invariant_check.violation) ->
            Log.Keeper.warn
              "keeper_invariant_violation: keeper=%s phase=%s property=%s detail=%s"
              entry.name
              (Keeper_state_machine.phase_to_string entry.phase)
              v.property
              v.detail)
         vs)
    entries;
  let to_restart = ref [] in
  let to_unregister = ref [] in
  let to_mark_dead = ref [] in
  let to_cleanup_dead = ref [] in
  let queue_crashed_entry (entry : Keeper_registry.registry_entry) msg =
    let queue_standard_restart () =
      if entry.restart_count >= max_restarts
      then to_mark_dead := (entry, msg) :: !to_mark_dead
      else (
        let delay = backoff_delay entry.restart_count in
        if now -. entry.last_restart_ts >= delay
        then to_restart := (entry, msg) :: !to_restart)
    in
    match failure_reason_policy_decision entry.last_failure_reason with
    | Some
        { Keeper_failure_policy.lifecycle_effect = Keeper_failure_policy.Pause_keeper
        ; _
        } ->
      (match entry.last_failure_reason with
       | Some (Keeper_registry.Stale_termination_storm { count }) ->
         (* #10765 Phase 2: policy owns the pause-vs-restart lifecycle
            decision; this branch only applies the stale-storm pause side
            effect and clears the in-memory registry slot so the counter
            increments once per storm. *)
         handle_stale_storm_pause ctx entry ~count;
         to_unregister := entry :: !to_unregister
       | Some (Keeper_registry.Oas_timeout_budget_loop { count }) ->
         (* Watchdog-preserved OAS budget loops include liveness evidence,
            so policy allows keeper pause without treating timeout alone as
            keeper death. *)
         handle_oas_timeout_budget_pause ctx entry ~count;
         to_unregister := entry :: !to_unregister
       | Some
           ( Keeper_registry.Heartbeat_consecutive_failures _
           | Keeper_registry.Turn_consecutive_failures _
           | Keeper_registry.Stale_turn_timeout _
           | Keeper_registry.Stale_fleet_batch _
           | Keeper_registry.Provider_runtime_error _
           | Keeper_registry.Tool_required_unsatisfied _
           | Keeper_registry.Ambiguous_partial_commit _
           | Keeper_registry.Fiber_unresolved
           | Keeper_registry.Exception _ )
       | None ->
         queue_standard_restart ())
    | Some
        { Keeper_failure_policy.lifecycle_effect =
            ( Keeper_failure_policy.Keep_running
            | Keeper_failure_policy.Soft_fail_turn
            | Keeper_failure_policy.Pause_current_work
            | Keeper_failure_policy.Force_release_turn
            | Keeper_failure_policy.Restart_keeper )
        ; _
        }
    | None ->
      queue_standard_restart ()
  in
  let watchdog_stop_pending (entry : Keeper_registry.registry_entry) =
    Atomic.get entry.fiber_stop
    &&
    match entry.last_failure_reason with
    | Some (Keeper_registry.Stale_turn_timeout _)
    | Some (Keeper_registry.Stale_termination_storm _)
    | Some (Keeper_registry.Stale_fleet_batch _)
    | Some (Keeper_registry.Oas_timeout_budget_loop _) -> true
    (* Other failure reasons are not stale-watchdog signals. *)
    | Some (Keeper_registry.Heartbeat_consecutive_failures _)
    | Some (Keeper_registry.Turn_consecutive_failures _)
    | Some (Keeper_registry.Provider_runtime_error _)
    | Some (Keeper_registry.Tool_required_unsatisfied _)
    | Some (Keeper_registry.Ambiguous_partial_commit _)
    | Some Keeper_registry.Fiber_unresolved
    | Some (Keeper_registry.Exception _)
    | None -> false
  in
  let force_unresolved_watchdog_crash (entry : Keeper_registry.registry_entry) =
    let msg =
      entry.last_failure_reason
      |> Option.map Keeper_registry.failure_reason_to_string
      |> Option.value ~default:"watchdog_stop_pending"
    in
    (* 2026-05-05 cycle 9: stamp the cohort onto keeper_meta.runtime so
       the per-keeper meta surface (and PR #12877's "차단된 키퍼"
       dashboard card) shows the same diagnosis the supervisor used to
       group the keeper into a self-preservation cohort.  Companion to
       PR #12943 which added the same stamp on the [Fiber_unresolved]
       finally branch; this branch — [force_unresolved_watchdog_crash]
       — was the other silent path where the stamp was missing.
       Mapping covers all three watchdog cohorts handled by
       [watchdog_stop_pending]. *)
    let stamp_cohort =
      match entry.last_failure_reason with
      | Some (Keeper_registry.Oas_timeout_budget_loop _) -> Some Oas_timeout_budget
      | Some (Keeper_registry.Stale_turn_timeout _)
      | Some (Keeper_registry.Stale_fleet_batch _)
      | Some (Keeper_registry.Stale_termination_storm _) -> Some Stale_turn_timeout
      (* Non-watchdog failure reasons do not seed a watchdog blocker_class. *)
      | Some (Keeper_registry.Heartbeat_consecutive_failures _)
      | Some (Keeper_registry.Turn_consecutive_failures _)
      | Some (Keeper_registry.Provider_runtime_error _)
      | Some (Keeper_registry.Tool_required_unsatisfied _)
      | Some (Keeper_registry.Ambiguous_partial_commit _)
      | Some Keeper_registry.Fiber_unresolved
      | Some (Keeper_registry.Exception _)
      | None -> None
    in
    (match stamp_cohort with
     | None -> ()
     | Some bc ->
       (match Keeper_registry.get ~base_path entry.name with
        | Some current ->
          let stamped_meta =
            { current.meta with
              runtime =
                { current.meta.runtime with
                  last_blocker = Some (blocker_info_of_class ~detail:msg bc)
                }
            }
          in
          (match
             write_meta_with_merge
               ~merge:Keeper_meta_merge.heartbeat_fields_from_disk
               ctx.config
               stamped_meta
           with
           | Ok () -> ()
           | Error err ->
             Prometheus.inc_counter
               Keeper_metrics.metric_keeper_write_meta_failures
               ~labels:[ "keeper", entry.name; "phase", "stale_turn_timeout_stamp" ]
               ();
             Log.Keeper.warn "%s: stale_turn_timeout meta stamp failed: %s" entry.name err)
        | None -> ()));
    Log.Keeper.warn
      "%s: supervisor forcing unresolved watchdog-stopped keeper to crashed (%s)"
      entry.name
      msg;
    Prometheus.inc_counter
      Keeper_metrics.metric_keeper_supervisor_cleanup_failures
      ~labels:
        [ "keeper", entry.name
        ; ("site", Keeper_supervisor_cleanup_failure_site.(to_label Force_watchdog_crash))
        ]
      ();
    (* 2026-05-05 fleet-stuck cycle: when a keeper fiber is stuck inside
       an LLM subprocess that does not honour [Eio.Cancel.Cancelled],
       the natural [Fun.protect] release in [with_keeper_turn_slot]
       never runs and its [reactive_turn_semaphore] permit is leaked.
       Production observation: 16 keepers held [reactive_slot] for
       18-25 minutes each, [reactive_available=0], every other keeper
       skipped its turn after the 180s [acquire_bounded] timeout, and
       the idle-turn watchdog killed them. Force-releasing here is the
       only path that drains the semaphore short of a process restart.
       Bounded over-release is documented in
       [Keeper_turn_slot.force_release_holder_for].

       WORKAROUND (RFC-0125 P5 removal target): this rescue path only
       releases the semaphore permit; the underlying stuck subprocess
       lives until process restart. The structural fix is RFC-0125 P4
       [keeper-level max-turn watchdog] (PR #15964) which cancels the
       keepalive fiber at a typed wall-clock boundary BEFORE the slot
       leaks. Removal target: 30-day soak on
       [metric_keeper_oas_timeout_budget_watchdog_termination] reaching
       zero with [MASC_KEEPER_MAX_TURN_WATCHDOG_TIMEOUT_SEC] enabled
       fleet-wide. Do not add new callers. *)
    (match Keeper_turn_slot.force_release_holder_for ~keeper_name:entry.name with
     | [] -> ()
     | released ->
       let summary =
         released
         |> List.map (fun (label, age) -> Printf.sprintf "%s/%.0fs" label age)
         |> String.concat ","
       in
       Log.Keeper.error
         "%s: force-released stale slots after watchdog crash: %s"
         entry.name
         summary);
	    if Keeper_registry.try_resolve_done entry (`Crashed msg)
	    then (
	      let outcome =
	        Keeper_registry.enrich_fiber_unresolved_outcome
	          ~base_path
	          ~keeper_name:entry.name
	          msg
	      in
	      ignore
	        (Keeper_registry.dispatch_event_and_log
	           ~base_path
	           entry.name
	           (Keeper_state_machine.Fiber_terminated { outcome; provider_id = None; http_status = None }));
      let ts = Time_compat.now () in
      Keeper_registry.record_crash ~base_path entry.name ts msg;
      Keeper_registry.record_error ~base_path entry.name msg;
      match Keeper_registry.get ~base_path entry.name with
      | Some updated -> queue_crashed_entry updated msg
      | None -> ())
  in
  (* 2-level supervision slice: process the flat registry through stable
     8-keeper cohorts.  Each cohort re-reads its entries by name before
     processing so earlier cohort actions cannot leave later cohorts walking
     stale registry records.  The iterator yields between cohort groups; the
     yield meter still protects unusually large cohorts or non-default sizes. *)
  let entry_cohorts = supervision_cohorts entries in
  let sweep_ym = Eio_guard.create_yield_meter () in
  iter_supervision_cohorts entry_cohorts ~f:(fun cohort ->
    let cohort_keepers = fresh_supervision_cohort_keepers ~base_path cohort in
    List.iter
      (fun (entry : Keeper_registry.registry_entry) ->
         (match entry.phase with
          | Keeper_state_machine.Dead | Keeper_state_machine.Zombie ->
            (match entry.dead_since_ts with
             | Some dead_since when now -. dead_since >= dead_ttl_sec ->
               to_cleanup_dead := entry :: !to_cleanup_dead
             | _ -> ())
          | Keeper_state_machine.Stopped -> to_unregister := entry :: !to_unregister
          | Keeper_state_machine.Running
          | Keeper_state_machine.Paused
          | Keeper_state_machine.Crashed
          | Keeper_state_machine.Failing
          | Keeper_state_machine.Overflowed
          | Keeper_state_machine.Compacting
          | Keeper_state_machine.HandingOff
          | Keeper_state_machine.Draining
          | Keeper_state_machine.Restarting
          | Keeper_state_machine.Offline ->
            (match Eio.Promise.peek entry.done_p with
             | None when watchdog_stop_pending entry ->
               force_unresolved_watchdog_crash entry
             | None -> () (* Alive — skip *)
             | Some `Stopped -> to_unregister := entry :: !to_unregister
             | Some (`Crashed msg) -> queue_crashed_entry entry msg));
         Eio_guard.yield_step sweep_ym)
      cohort_keepers);
  List.iter
    (fun (entry : Keeper_registry.registry_entry) ->
       Keeper_registry.unregister ~base_path entry.name;
       (* K4c — restart-budget exhaustion: keeper is permanently
       removed (no respawn), so reclaim its accumulator slot. *)
       Keeper_tool_emission_hook.drop_keeper_accumulator entry.name)
    !to_unregister;
  List.iter
    (fun ((entry : Keeper_registry.registry_entry), msg) ->
       (* RFC-0002: dispatch budget exhaustion before marking dead *)
       Keeper_registry.dispatch_event_unit
         ~base_path
         entry.name
         Keeper_state_machine.Restart_budget_exhausted;
       Keeper_registry.mark_dead ~base_path entry.name ~at:now;
       (* Task release: Dead keepers cannot make progress on claimed tasks.
       Without this release, current_task_id stays claimed forever —
       the task is invisible to peers while this keeper is permanently
       stopped.  Mirrors handle_crash_auto_pause (line 1163). *)
       (match entry.meta.current_task_id with
        | Some _ ->
          (match read_meta ctx.config entry.name with
           | Ok (Some meta) ->
             ignore
               (write_meta_with_merge
                  ~merge:Keeper_meta_merge.heartbeat_fields_from_disk
                  ctx.config
                  { meta with current_task_id = None })
           | _ -> ())
        | None -> ());
       let detail =
         Printf.sprintf "restart budget exhausted (%d), last: %s" max_restarts msg
       in
       publish_phase_lifecycle ~phase:Keeper_state_machine.Dead entry.name detail ();
       (* Loud alert: structured Dead event + Prometheus counter so a fleet-wide
       silent crash (8 keepers, 2026-04-25) is impossible to miss in dashboard
       or PromQL. The free-form [event="dead"] on masc.keeper.lifecycle does
       not carry restart_count or the structured failure reason. *)
       let last_fr_str =
         Option.map Keeper_registry.failure_reason_to_string entry.last_failure_reason
       in
       (match Keeper_keepalive.get_bus () with
        | Some bus ->
          Cascade_events.publish_keeper_dead
            bus
            ~keeper_name:entry.name
            ~reason:msg
            ~restart_count:entry.restart_count
            ~last_failure_reason:last_fr_str
            ()
        | None -> ());
       Prometheus.inc_counter
         Keeper_metrics.metric_keeper_dead_total
         ~labels:
           [ "keeper", entry.name; "reason", Option.value last_fr_str ~default:"unknown" ]
         ();
       Log.Keeper.error
         "keeper DEAD (max_restarts exhausted): name=%s reason=%s restart_count=%d — \
          operator action required"
         entry.name
         msg
         entry.restart_count)
    !to_mark_dead;
  (* RFC-0036 Phase A.2: fire Tombstone_reaped after cleanup completes.
     Hook is exception-safe; supervisor never observes failure. *)
  List.iter
    (fun (entry : Keeper_registry.registry_entry) ->
       cleanup_dead_tombstone ctx entry;
       Keeper_lifecycle_hooks.run
         ~base_dir:(Coord.masc_root_dir ctx.config)
         ~meta:entry.meta
         ~keeper_id:entry.name
         Keeper_lifecycle_hooks.Tombstone_reaped)
    !to_cleanup_dead;
  let active_count =
    Keeper_registry.all ~base_path () |> active_supervision_keeper_count
  in
  let restart_list =
    let keepers_dir = Filename.concat (Coord.masc_root_dir ctx.config) "keepers" in
    apply_self_preservation ~keepers_dir ~total_keepers:active_count !to_restart
  in
  (* Restart crashed keepers *)
  List.iter
    (fun ((old_entry : Keeper_registry.registry_entry), crash_msg) ->
       let attempt = old_entry.restart_count + 1 in
       Prometheus.inc_counter
         Keeper_metrics.metric_keeper_restart_attempts
         ~labels:[ "keeper", old_entry.name ]
         ();
       match read_meta ctx.config old_entry.name with
       | Ok (Some meta) ->
         (* RFC-0002: dispatch restart attempt event *)
         Keeper_registry.dispatch_event_unit
           ~base_path
           old_entry.name
           (Keeper_state_machine.Supervisor_restart_attempt { attempt });
         let old_crash_log = old_entry.crash_log in
         (* R-A-6.a guard: register_restarting refuses revival when the
            prior entry's restart_budget was already exhausted (TLA+ §S3
            BudgetNeverRevives).  In normal sweeps this never fires —
            the [restart_count >= max_restarts] gate at line ~1468 routes
            exhausted keepers to [to_mark_dead], not [to_restart].  A
            refusal here means some out-of-band path cleared the budget
            (one of the three vectors documented in iter 14 audit memo). *)
         (match Keeper_registry.register_restarting ~base_path old_entry.name meta with
          | Error (Keeper_registry.Budget_already_exhausted _) ->
            (* Route to mark_dead instead of merely skipping: a keeper that
               trips the BudgetNeverRevives guard should reach a stable
               terminal state, otherwise it would re-enter [to_restart]
               every sweep (an out-of-band budget reset would loop forever).
               Mark Dead makes the keeper visible to operators and exits
               the restart cycle deterministically. *)
            Log.Keeper.warn
              "%s: register_restarting refused — restart_budget_remaining=false \
               (BudgetNeverRevives guard tripped); routing to mark_dead"
              old_entry.name;
            Prometheus.inc_counter
              Keeper_metrics.metric_keeper_restart_outcomes
              ~labels:[ "keeper", old_entry.name; "outcome", "refused_budget_exhausted" ]
              ();
            to_mark_dead := (old_entry, crash_msg) :: !to_mark_dead
          | Ok reg ->
            Keeper_registry.restore_supervisor_state
              ~base_path
              old_entry.name
              ~restart_count:attempt
              ~last_restart_ts:now
              ~crash_log:(keep_last_n 5 (now, crash_msg) old_crash_log);
            launch_supervised_fiber ~proactive_warmup_sec:0 ctx meta reg;
            publish_lifecycle
              ~event:
                (Keeper_lifecycle_events.Custom_event
                   { verb = Keeper_lifecycle_events.Restarted
                   ; phase = Some Keeper_state_machine.Running
                   })
              old_entry.name
              (Printf.sprintf "attempt %d" attempt)
              ();
            Prometheus.inc_counter
              Keeper_metrics.metric_keeper_restart_outcomes
              ~labels:[ "keeper", old_entry.name; "outcome", "started" ]
              ();
            Log.Keeper.info
              "%s: restarted (attempt %d, backoff %.0fs)"
              old_entry.name
              attempt
              (backoff_delay (attempt - 1));
            (* Soft pre-warning when this is the FINAL allowed restart: next
               crash will trip the budget and mark Dead. Operator-actionable
               but not yet a fault — investigate root cause now. *)
            if attempt >= max_restarts
            then (
              Log.Keeper.warn
                "keeper near-exhaustion: name=%s restart=%d/%d — investigate"
                old_entry.name
                attempt
                max_restarts;
              Prometheus.inc_counter
                Keeper_metrics.metric_keeper_near_exhaustion_total
                ~labels:[ "keeper", old_entry.name ]
                ()))
       | _ ->
         Prometheus.inc_counter
           Keeper_metrics.metric_keeper_restart_outcomes
           ~labels:[ "keeper", old_entry.name; "outcome", "meta_unavailable" ]
           ();
         Log.Keeper.error "%s: cannot read meta for restart, removing" old_entry.name;
         Keeper_registry.unregister ~base_path old_entry.name;
         (* K4c — restart-meta read failure: keeper abandoned, drop. *)
         Keeper_tool_emission_hook.drop_keeper_accumulator old_entry.name)
    restart_list;
  (* Phase 2: restore paused reconcile gates whose approval queue was lost
     on restart. The queue itself is in-memory, but paused keeper meta is
     durable, so rebuild the human gate from persisted blocker evidence. *)
  let sweep_names_ym = Eio_guard.create_yield_meter () in
  Keeper_types.keeper_names ctx.config
  |> List.iter (fun name ->
    (match read_meta ctx.config name with
     | Ok (Some meta)
       when paused_meta_requires_reconcile_recovery meta
            && not (Keeper_approval_queue.has_pending_for_keeper ~keeper_name:meta.name)
       -> restore_reconcile_continue_gate ctx meta
     | _ -> ());
    Eio_guard.yield_step sweep_names_ym);
  (* Phase 3: prune stale paused keeper meta files from disk. Keep
     reconcile-recovery pauses until the operator explicitly resolves them. *)
  let paused_ttl_sec = Env_config.KeeperSupervisor.paused_cleanup_ttl_sec in
  Keeper_types.keeper_names ctx.config
  |> List.iter (fun name ->
    if Keeper_registry.is_running ~base_path name
    then ()
    else (
      match read_meta ctx.config name with
      | Ok (Some meta)
        when is_stale_paused_meta ~now ~paused_ttl_sec meta
             && (not (paused_meta_requires_reconcile_recovery meta))
             && not (Keeper_approval_queue.has_pending_for_keeper ~keeper_name:meta.name)
        ->
        let path = Keeper_types.keeper_meta_path ctx.config name in
        (try
           Sys.remove path;
           publish_lifecycle
             ~event:
               (Keeper_lifecycle_events.Custom_event
                  { verb = Keeper_lifecycle_events.Paused_pruned; phase = None })
             name
             (Printf.sprintf "last_updated=%s" meta.updated_at)
             ();
           Log.Keeper.info "%s: stale paused meta pruned" name
         with
         | Eio.Cancel.Cancelled _ as e -> raise e
         | exn ->
           Log.Keeper.warn
             "%s: paused meta prune failed: %s"
             name
             (Printexc.to_string exn);
           Prometheus.inc_counter
             Keeper_metrics.metric_keeper_supervisor_cleanup_failures
             ~labels:
               [ "keeper", name
               ; ("site", Keeper_supervisor_cleanup_failure_site.(to_label Paused_meta_prune))
               ]
             ())
      | _ -> ());
    Eio_guard.yield_step sweep_names_ym);
  (* Phase 3.5: self-healing circuit breaker — auto-resume keepers that were
     auto-paused (have [auto_resume_after_sec = Some sec]) and whose pause
     timer has elapsed.  Clearing [paused = false] here lets Phase 4
     (reconcile_keepalive_keepers) pick them up and restart them on the same
     sweep.  Reconcile-gated pauses (ambiguous commit timeouts) and
     operator-initiated pauses ([auto_resume_after_sec = None]) are
     intentionally skipped so they continue to require human action. *)
  Keeper_types.keeper_names ctx.config
  |> List.iter (fun name ->
    if Keeper_registry.is_running ~base_path name
    then ()
    else (
      match read_meta ctx.config name with
      | Ok (Some meta)
        when Keeper_supervisor_types.paused_meta_auto_resume_due ~now meta
             && not (Keeper_approval_queue.has_pending_for_keeper ~keeper_name:meta.name)
        ->
        let cascade_name = Keeper_types.cascade_name_of_meta meta in
        let cascade_status = Keeper_health_probe.get_cascade_status ~cascade_name in
        (* Three-valued admission:
                    Unhealthy   — block, the probe saw restart pressure.
                    Healthy     — proceed with timer check.
                    Unknown     — proceed with timer check.  No probe data
                                  yet (e.g. all keepers in the cascade
                                  paused so the registry has no entries
                                  to score).  Defaulting to "block" here
                                  is the bug PR #14146 shipped: it turned
                                  the boot-time race window into a
                                  permanent lockout.  See instructions/
                                  software-development.md anti-pattern
                                  "Unknown -> Permissive Default". *)
        (match cascade_status with
         | Keeper_health_probe.Unhealthy reason ->
           Log.Keeper.info
             "%s: auto-resume blocked; cascade %s is unhealthy (%s)"
             name
             cascade_name
             reason;
           Prometheus.inc_counter
             Keeper_metrics.metric_keeper_auto_resume_blocked_total
             ~labels:[ "keeper", name; "cascade", cascade_name ]
             ()
         | Keeper_health_probe.Unknown | Keeper_health_probe.Healthy ->
           let resume_after_sec = Option.value ~default:0.0 meta.auto_resume_after_sec in
           let paused_ts =
             Coord_resilience.Time.parse_iso8601_opt meta.updated_at
             |> Option.value ~default:0.0
           in
           if paused_ts > 0.0 && now -. paused_ts >= resume_after_sec
           then (
             (* Resume: clear [paused] flag but retain [auto_resume_after_sec]
                      so the doubled delay is ready for the next auto-pause.  It
                      will be reset to [None] on a successful turn completion. *)
             let resumed_meta =
               { meta with
                 paused = false
               ; updated_at = now_iso ()
               ; runtime = { meta.runtime with last_blocker = None }
               }
             in
             match
               write_meta_with_merge
                 ~merge:Keeper_meta_merge.heartbeat_fields_from_disk
                 ctx.config
                 resumed_meta
             with
             | Ok () ->
               publish_lifecycle
                 ~event:
                   (Keeper_lifecycle_events.Custom_event
                      { verb = Keeper_lifecycle_events.Auto_resumed; phase = None })
                 name
                 (Printf.sprintf "auto_resume backoff=%.0fs" resume_after_sec)
                 ();
               Prometheus.inc_counter
                 Keeper_metrics.metric_keeper_auto_resumed_total
                 ~labels:[ "keeper", name ]
                 ();
               Log.Keeper.info
                 "%s: auto-resumed after %.0fs backoff (next backoff=%.0fs if re-paused; \
                  resets to initial on successful turn)"
                 name
                 resume_after_sec
                 (Float.min
                    Env_config.KeeperSupervisor.auto_resume_max_sec
                    (resume_after_sec *. 2.0))
             | Error err ->
               Prometheus.inc_counter
                 Keeper_metrics.metric_keeper_write_meta_failures
                 ~labels:[ "keeper", name; "phase", "auto_resume" ]
                 ();
               Log.Keeper.warn "%s: auto-resume meta write failed: %s" name err))
      | _ -> ());
    Eio_guard.yield_step sweep_names_ym);
  (* Phase 4: reconcile LAST — only orphaned durable keepers *)
  reconcile_keepalive_keepers ctx
;;

type credential_recovery_outcome =
  Keeper_supervisor_liveness_recovery.credential_recovery_outcome =
  | Credential_recovery_not_needed
  | Credential_recovery_reissued of string
  | Credential_recovery_failed of string

let credential_recovery_before_restart_for_test =
  Keeper_supervisor_liveness_recovery.credential_recovery_before_restart_for_test
;;

let liveness_recovery_scan ctx =
  Keeper_supervisor_liveness_recovery.scan ~supervise_keepalive ~publish_lifecycle ctx
;;

let request_alive_but_stuck_recovery_for_test =
  Keeper_supervisor_alive_but_stuck.request_recovery_for_test
;;

let alive_but_stuck_reset_for_test = Keeper_supervisor_alive_but_stuck.reset_for_test
let alive_but_stuck_scan = Keeper_supervisor_alive_but_stuck.scan
