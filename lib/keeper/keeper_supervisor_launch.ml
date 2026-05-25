(** Keeper_supervisor — keeper keepalive fiber supervision.
    Uses [Keeper_registry] as SSOT for keeper state; manages
    liveness/restart policy outside the turn loop. *)

open Keeper_types
open Keeper_execution
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

(* ── Event publishing (see Keeper_supervisor_publish_lifecycle, #8856/#8605) ─ *)

let publish_lifecycle = Keeper_supervisor_publish_lifecycle.publish_lifecycle
let publish_phase_lifecycle = Keeper_supervisor_publish_lifecycle.publish_phase_lifecycle
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
    Keeper_registry_event_queue.enqueue ~base_path meta.name bootstrap_signal;
    (* RFC-0059 PR-7-pilot originally routed the whole keepalive body through
       a Domain_pool worker.  Live recovery proved that unsafe: the body is
       an Eio fiber loop that uses the server switch, clock, turn timeouts, and
       provider streaming.  Moving it to an Executor_pool domain can touch an
       Eio switch from the wrong domain and tear down keepers at boot.  Keep
       the flag observable, but run the supervisor fiber on the owning Eio
       domain.  Only pure/blocking sub-work should use [Domain_pool]. *)
    let domain_pool_flag = Env_config.KeeperSupervisor.domain_pool_enabled in
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
      bump_fork_outcome
        (if domain_pool_flag then "inline_eio_required" else "inline_disabled");
      if domain_pool_flag
      then
        Log.Keeper.warn
          "keeper supervise domain pool ignored for %s: keepalive body requires the \
           owning Eio domain"
          meta.name;
      Eio.Fiber.fork ~sw:ctx.sw body
    in
    fork_body (fun () ->
      let resolved = ref false in
      let resolve_done value =
        if not !resolved then
          (* Issue #18335: the keepalive layer (keeper_keepalive.ml:760-791)
             may have already resolved done_p via record_keeper_stopped.
             When the Promise is already resolved, treat it as success —
             the keeper completed normally via the keepalive exit path. *)
          if Keeper_registry.try_resolve_done reg value then (
            resolved := true;
            true)
          else if Option.is_some (Eio.Promise.peek reg.done_p) then (
            resolved := true;
            true)
          else
            false
        else
          false
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
                  | Some (Keeper_registry.Provider_timeout_loop _) -> true
                  (* Other failure reasons are not stale-watchdog signals. *)
                  | Some (Keeper_registry.Heartbeat_consecutive_failures _)
                  | Some (Keeper_registry.Turn_consecutive_failures _)
                  | Some (Keeper_registry.Provider_runtime_error _)
                  | Some (Keeper_registry.Tool_required_unsatisfied _)
                  | Some Keeper_registry.Turn_overflow_pause
                  | Some Keeper_registry.Turn_livelock_pause
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
	                 Keeper_registry_cascade_attempt.enrich_fiber_unresolved_outcome
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
	               Keeper_registry_cascade_attempt.enrich_fiber_unresolved_outcome
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
             Keeper_registry_error_recording.record ~base_path meta.name reason;
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
            (* ETA-LIVELOCK: keep the typed-escalation classifier in
               lock-step with the upstream livelock bookkeeping so a
               restarted keeper sees the first block at ERROR again.
               Without this reset the [Threshold_park] state from a
               previous lifetime would silently demote the new
               keeper's First block to DEBUG. *)
            Keeper_livelock_state.reset_for_keeper ~keeper:meta.name;
            if not !resolved
            then
              if Shutdown.is_shutting_down_global ()
              then (
                Log.Keeper.warn
                  "%s: fiber unresolved during shutdown (not a crash)"
                  meta.name;
                Keeper_registry.mark_dead ~base_path meta.name ~at:(Time_compat.now ());
                (* fire-and-forget: resolve_done signals completion *)
                ignore (resolve_done (`Crashed "shutdown")))
              else (
	                let reason =
	                  Keeper_registry.failure_reason_to_string
	                    Keeper_registry.Fiber_unresolved
	                in
	                let outcome =
	                  Keeper_registry_cascade_attempt.enrich_fiber_unresolved_outcome
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
                Keeper_registry_error_recording.record ~base_path meta.name reason;
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
  Keeper_supervisor_supervise_keepalive.supervise_keepalive
    ~publish_lifecycle
    ~launch_supervised_fiber
    ~proactive_warmup_sec
    ctx
    meta
;;

let resume_keeper_after_reconcile_gate (ctx : _ context) (meta : keeper_meta) =
  Keeper_supervisor_resume_reconcile_gate.resume_keeper_after_reconcile_gate
    ~supervise_keepalive
    ctx
    meta
;;

let restore_reconcile_continue_gate (ctx : _ context) (meta : keeper_meta) =
  Keeper_supervisor_restore_reconcile_gate.restore_reconcile_continue_gate
    ~supervise_keepalive
    ctx
    meta
;;

(* ── Sweep and recover ───────────────────────────────────── *)

(** Reconcile only orphaned or cleanly stopped durable keepers.
    Running/Paused/Crashed/Dead entries are actively managed by sweep
    and must NOT be re-launched by reconcile. Stopped entries with
    unresolved fibers (done_p = None) are also skipped — sweep will
    handle them once the fiber terminates. *)
(* Phase 4 reconciliation extracted to
   [Keeper_supervisor_reconcile_keepalive] (godfile decomp).
   publish_lifecycle + supervise_keepalive injected to avoid cycle. *)
let reconcile_keepalive_keepers (ctx : _ context) =
  Keeper_supervisor_reconcile_keepalive.reconcile_keepalive_keepers
    ~publish_lifecycle
    ~supervise_keepalive
    ctx
;;

(* Dead-tombstone cleanup extracted to
   [Keeper_supervisor_cleanup_tombstone] (godfile decomp). publish_lifecycle is
   injected explicitly to avoid sibling -> parent cycle. *)
let cleanup_dead_tombstone (ctx : _ context) (entry : Keeper_registry.registry_entry) =
  Keeper_supervisor_cleanup_tombstone.cleanup_dead_tombstone
    ~publish_lifecycle
    ctx
    entry
;;

(** Cohort key from structured failure_reason ADT.
    #10584: delegates to [Keeper_registry.failure_reason_cohort_key] so a
    new variant in keeper_registry forces a same-PR converter update via
    the source module's exhaustive-match check, instead of breaking main
    here on first build (the recurring P0 pattern from #10490 + #10574). *)

(* See Keeper_supervisor_self_preservation for probe mechanism (#10887). *)
let reset_self_preservation_escape_state_for_test () =
  Keeper_supervisor_self_preservation.reset_for_test ()
;;


(* Self-preservation gate — see Keeper_supervisor_self_preservation for rationale. *)
let apply_self_preservation ~keepers_dir ~total_keepers to_restart =
  Keeper_supervisor_self_preservation.apply
    ~keepers_dir
    ~publish_lifecycle
    ~total_keepers
    to_restart
;;


(* Crash-driven pause policy — see Keeper_supervisor_pause_policy (#10765). *)
module Pause_policy = Keeper_supervisor_pause_policy

type crash_pause_resume_policy = Pause_policy.crash_pause_resume_policy =
  | Manual_resume_required
  | Auto_resume_with_backoff

let handle_crash_auto_pause ctx entry =
  Pause_policy.handle_crash_auto_pause ~publish_phase_lifecycle ctx entry
;;

let handle_stale_storm_pause ctx entry =
  Pause_policy.handle_stale_storm_pause ~publish_phase_lifecycle ctx entry
;;

let handle_provider_timeout_pause ctx entry =
  Pause_policy.handle_provider_timeout_pause ~publish_phase_lifecycle ctx entry
;;

let failure_reason_policy_decision = Pause_policy.failure_reason_policy_decision
let failure_reason_policy_decision_for_test = failure_reason_policy_decision
