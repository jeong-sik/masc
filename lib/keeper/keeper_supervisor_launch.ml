(** Keeper_supervisor — keeper keepalive fiber supervision.
    Uses [Keeper_registry] as SSOT for keeper state; manages
    liveness/restart policy outside the turn loop. *)

open Keeper_types
open Keeper_meta_contract
open Keeper_meta_store
open Keeper_types_profile
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

type done_signal_resolution =
  | Done_signal_resolved_now
  | Done_signal_already_resolved
  | Done_signal_already_seen

let done_signal_of_registry_result = function
  | Keeper_registry.Done_resolved _ -> Done_signal_resolved_now
  | Keeper_registry.Done_already_resolved _ -> Done_signal_already_resolved
;;

let should_publish_lifecycle_for_done_signal = function
  | Done_signal_resolved_now -> true
  | Done_signal_already_resolved
  | Done_signal_already_seen -> false
;;

(* ── Event publishing (see Keeper_supervisor_publish_lifecycle, #8856/#8605) ─ *)

let publish_lifecycle = Keeper_supervisor_publish_lifecycle.publish_lifecycle
let publish_phase_lifecycle = Keeper_supervisor_publish_lifecycle.publish_phase_lifecycle
(* ── Supervised fiber launch ─────────────────────────────── *)

let global_switch : Eio.Switch.t option Atomic.t = Atomic.make None
let set_global_switch sw = Atomic.set global_switch (Some sw)
let get_global_switch () = Atomic.get global_switch

let set_restart_launch_noop_for_test = Keeper_supervisor_restart_noop.set
let restart_launch_noop_enabled_for_test = Keeper_supervisor_restart_noop.enabled
let with_restart_launch_noop_for_test = Keeper_supervisor_restart_noop.with_noop
let domain_pool_ignored_warning_emitted = Atomic.make false

let launch_supervised_fiber_body
      ~proactive_warmup_sec
      ctx
      (meta : keeper_meta)
      (reg : Keeper_registry.registry_entry)
  =
  let base_path = ctx.config.base_path in
  let keepers_dir = Workspace.keepers_runtime_dir ctx.config in
  if restart_launch_noop_enabled_for_test ()
  then ()
  else (
    (* Task 137: Inject bootstrap signal to ensure at least one warm-up turn runs
     and break the initial proactive deadlock. *)
    let bootstrap_signal : Keeper_event_queue.stimulus =
      { post_id = "bootstrap"
      ; urgency = Keeper_event_queue.Normal
      ; arrived_at = Unix.gettimeofday ()
      ; payload = Keeper_event_queue.Bootstrap
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
         call sites ([keeper] first, then the discriminator).  Otel_metric_store
         label-set keys are order-sensitive, so a single per-metric
         convention prevents accidental time-series splitting when new
         call sites add the same labels in a different order. *)
      Otel_metric_store.inc_counter
        Keeper_metrics.(to_string DomainPoolFork)
        ~labels:[ "keeper", meta.name; "outcome", outcome ]
        ()
    in
    let fork_body body =
      bump_fork_outcome
        (if domain_pool_flag then "inline_eio_context" else "inline_disabled");
      if
        domain_pool_flag
        && Atomic.compare_and_set
             domain_pool_ignored_warning_emitted
             false
             true
      then
        Log.Keeper.warn
          "keeper supervise domain pool ignored: keepalive body requires the owning \
           Eio domain (first_keeper=%s)"
          meta.name;
      (* determinism-contract: allow — ctx.sw fallback is the same deterministic
         default used before the ref -> Atomic conversion. *)
      let sw = Option.value (Atomic.get global_switch) ~default:ctx.sw in
      match
        Keeper_lane.fork
          ~sw
          reg.lane
          ~run:body
          ~cleanup:(fun _ -> Ok ())
      with
      | Ok () -> ()
      | Error error ->
        let detail = Keeper_lane.start_error_to_string error in
        Keeper_registry.set_failure_reason
          ~base_path
          meta.name
          (Some (Keeper_registry.Exception detail));
        ignore
          (Keeper_registry.resolve_done
             reg
             ~source:"supervisor_lane_start_rejected"
             (`Crashed detail)
           : Keeper_registry.done_resolve_result)
    in
    fork_body (fun lane_sw ->
      let ctx = { ctx with sw = lane_sw } in
      let resolved = Atomic.make false in
      (* Issue #18901 follow-up: distinguish parent-cancellation from
         genuine missed-resolution in the finally branch. The body's
         try/with re-raises [Eio.Cancel.Cancelled] (line 281 area)
         which then propagates to the surrounding switch, leaving the
         finally to fire with [resolved=false]. Without this flag the
         finally cannot tell whether the unresolved drop was a parent
         cancel (supervisor restart, sibling failure) or a real
         missed-resolution bug — both collapsed into [Unexpected].
         Setting the flag from the cancel handler keeps the typed
         [fiber_drop_cause] payload accurate. *)
      let cancelled_by_parent = Atomic.make false in
      let resolve_done ~source value =
        if not (Atomic.get resolved) then
          (* Issue #18335: the keepalive layer (keeper_keepalive.ml:760-791)
             may have already resolved done_p via record_keeper_stopped.
             When the Promise is already resolved, suppress finally cleanup,
             but do not let this supervisor branch publish a second lifecycle
             event for an outcome it did not own. *)
          let signal =
            Keeper_registry.resolve_done reg ~source value
            |> done_signal_of_registry_result
          in
          Atomic.set resolved true;
          signal
        else
          Done_signal_already_seen
      in
      Eio_guard.protect
        (fun () ->
           try
             (* RFC-0125 P4 의 keeper-level max-turn watchdog (구 [In_turn_hung]
                wall-clock timer) 를 제거한다 (RFC-0250 §"deliberately removed"
                정렬). 그 타이머는 [Eio.Fiber.first] 로 keepalive loop 전체를 감싸
                keeper *launch* 이후 wall-clock 을 쟀고 — 턴 경계마다 리셋되지
                않으므로 — 단일 턴이 아니라 keeper lifetime 을 cap 했다. 결과적으로
                30 분 넘게 사는 정상 keeper (짧은 턴을 여러 번 처리했든 idle 이든)
                도 강제 재시작되었다. 이름과 달리 "현재 턴이 너무 오래" 가 아니라
                "프로세스가 너무 오래" 를 측정한 것이다.

                per-turn wall-clock timeout 은 의도적으로 금지된 패턴이다:
                [Keeper_unified_turn_attempt_watchdog] .mli — "MASC must not impose
                a wall-clock timeout around the whole provider/tool". in-turn /
                idle 복구는 supervisor sweep 의 [assess_in_turn_progress]
                ([Mid_turn_no_progress], turn observation 의 last_progress_at 기준)
                + [assess_stale_run] ([Idle_turn], last_turn_ts 기준) 가 담당하며,
                둘 다 turn-scoped 라 이 원칙을 준수한다 (각각
                test_assess_in_turn_progress / test_assess_stale_run 로 커버).
                따라서 keepalive loop 를 race 없이 직접 실행한다. watchdog 의 유일
                producer 였던 [In_turn_hung] kill-class variant 와 그 opt-in env
                knob ([MASC_KEEPER_MAX_TURN_WATCHDOG_TIMEOUT_SEC]) 도 함께 제거됐다.
                아래 watchdog_triggered 분기는 sweep 이 stamp 한 다른 stale reason
                ([Idle_turn] / [Mid_turn_no_progress] 등) 으로 계속 작동한다. *)
             Keeper_keepalive.run_heartbeat_loop
               ~proactive_warmup_sec
               ctx
               meta
               reg.fiber_stop
               ~wakeup:reg.fiber_wakeup;
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
                  | Some (Keeper_registry.Completion_contract_violation _)
                  | Some Keeper_registry.Turn_overflow_pause
                  | Some Keeper_registry.Turn_livelock_pause
                  | Some (Keeper_registry.Ambiguous_partial_commit _)
                  | Some (Keeper_registry.Fiber_unresolved _)
                  | Some (Keeper_registry.Exception _)
                  | Some Keeper_registry.Operator_interrupt
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
	               let outcome = reason in
	               (match
	                  Keeper_registry.dispatch_event
	                    ~base_path
	                    meta.name
	                    (Keeper_state_machine.Fiber_terminated { outcome; provider_id = None; http_status = None })
	                with
                | Ok _ -> ()
                | Error e ->
                  Otel_metric_store.inc_counter
                    Keeper_metrics.(to_string DispatchEventFailures)
                    ~labels:[ "keeper", meta.name; "event", "fiber_terminated" ]
                    ();
                  Log.Keeper.warn
                    "supervisor: Fiber_terminated dispatch failed: %s"
                    (Keeper_state_machine.transition_error_to_string e));
               if
                 resolve_done ~source:"supervisor_watchdog_crash" (`Crashed reason)
                 |> should_publish_lifecycle_for_done_signal
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
                  Otel_metric_store.inc_counter
                    Keeper_metrics.(to_string DispatchEventFailures)
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
                  Otel_metric_store.inc_counter
                    Keeper_metrics.(to_string DispatchEventFailures)
                    ~labels:[ "keeper", meta.name; "event", "drain_complete" ]
                    ();
                  Log.Keeper.warn
                    "supervisor: Drain_complete dispatch failed: %s"
                    (Keeper_state_machine.transition_error_to_string e));
               if
                 resolve_done ~source:"supervisor_normal_exit" `Stopped
                 |> should_publish_lifecycle_for_done_signal
               then
                 publish_phase_lifecycle
                   ~phase:Keeper_state_machine.Stopped
                   meta.name
                   "normal exit"
                   ())
           with
           | Eio.Cancel.Cancelled _ ->
             Atomic.set cancelled_by_parent true;
             (* Do NOT re-raise Cancelled in a forked fiber, as it cancels the parent switch. *)
             ()
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
	             let outcome = reason in
	             Keeper_registry.set_failure_reason ~base_path meta.name (Some fr);
	             (match
	                Keeper_registry.dispatch_event
	                  ~base_path
	                  meta.name
	                  (Keeper_state_machine.Fiber_terminated { outcome; provider_id = None; http_status = None })
	              with
              | Ok _ -> ()
              | Error e ->
                Otel_metric_store.inc_counter
                  Keeper_metrics.(to_string DispatchEventFailures)
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
             if
               resolve_done ~source:"supervisor_exception_handler" (`Crashed reason)
               |> should_publish_lifecycle_for_done_signal
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
           crashing the server (see masc crash 2026-04-17). Swallow
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
            Keeper_turn_livelock.reset_keeper_livelock
              ~base_path
              ~keeper:meta.name;
            (* ETA-LIVELOCK: keep the typed-escalation classifier in
               lock-step with the upstream livelock bookkeeping so a
               restarted keeper sees the first block at ERROR again.
               Without this reset the [Threshold_park] state from a
               previous lifetime would silently demote the new
               keeper's First block to DEBUG. *)
            Keeper_livelock_state.reset_for_keeper ~keeper:meta.name;
            if not (Atomic.get resolved)
            then
              if Shutdown.is_shutting_down_global ()
              then (
                (* Issue #18901: graceful-shutdown branch. Tag the failure
                   reason with [Graceful_shutdown] cause so the cohort
                   key splits away from the legacy "fiber_unresolved"
                   ERROR cohort. Severity stays at INFO via the
                   [Log.Keeper.info] call below — record_crash is not
                   invoked here because shutdown drops are bookkeeping,
                   not restart-budget signal. *)
                Log.Keeper.info
                  "%s: fiber unresolved during shutdown (graceful, not a crash)"
                  meta.name;
                Keeper_registry.set_failure_reason
                  ~base_path
                  meta.name
                  (Some (Keeper_registry.Fiber_unresolved Graceful_shutdown));
                Keeper_registry.mark_dead ~base_path meta.name ~at:(Time_compat.now ());
                (* fire-and-forget: resolve_done signals completion *)
                ignore
                  (resolve_done
                     ~source:"supervisor_shutdown_cleanup"
                     (`Crashed "shutdown")))
              else if Atomic.get cancelled_by_parent
              then (
                (* Issue #18901 follow-up: parent-cancel branch. The
                   body's try/with caught [Eio.Cancel.Cancelled] and set
                   the flag before re-raising. Shutdown was not in
                   progress, so this is a *supervisor-driven* cancel
                   (restart, sibling failure propagating cancel) rather
                   than a missed-resolution bug. WARN severity, separate
                   cohort, no record_crash — parent cancels are
                   expected lifecycle events, not restart-budget signal. *)
                Log.Keeper.warn
                  "%s: fiber unresolved after parent cancellation (transient)"
                  meta.name;
                Keeper_registry.set_failure_reason
                  ~base_path
                  meta.name
                  (Some (Keeper_registry.Fiber_unresolved Cancelled_by_parent));
                Keeper_registry.mark_dead ~base_path meta.name ~at:(Time_compat.now ());
                (* fire-and-forget: resolve_done signals completion *)
                ignore
                  (resolve_done
                     ~source:"supervisor_parent_cancel_cleanup"
                     (`Crashed "cancelled_by_parent")))
              else (
	                let reason =
	                  Keeper_registry.failure_reason_to_string
	                    (Keeper_registry.Fiber_unresolved Unexpected)
	                in
	                let outcome = reason in
	                Keeper_registry.set_failure_reason
	                  ~base_path
                  meta.name
                  (Some (Keeper_registry.Fiber_unresolved Unexpected));
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
                      Otel_metric_store.inc_counter
                        Keeper_metrics.(to_string WriteMetaFailures)
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
                if
                  resolve_done ~source:"supervisor_unresolved_cleanup" (`Crashed reason)
                  |> should_publish_lifecycle_for_done_signal
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
            Otel_metric_store.inc_counter
              Keeper_metrics.(to_string SupervisorCleanupFailures)
              ~labels:[ "keeper", meta.name ]
              ();
            Log.Keeper.warn
              "%s: supervisor finally cleanup failed (suppressed to avoid \
               Fun.Finally_raised): %s"
              meta.name
              (Printexc.to_string exn))))
;;

(** Launch gate: the registry FSM must accept [Fiber_started] before any
    fiber is forked. Returns [Error _] when the launch was refused; in that
    case nothing was forked, no [Started]/[Running] event may be published
    by the caller, and [done_p] has been resolved through the crash path. *)
let launch_supervised_fiber
      ~proactive_warmup_sec
      ctx
      (meta : keeper_meta)
      (reg : Keeper_registry.registry_entry)
  =
  let base_path = ctx.config.base_path in
  match Keeper_registry.prepare_fiber_launch ~base_path meta.name with
  | Error err ->
    (* Fail closed: a rejected [Fiber_started] (terminal state, invalid
       transition, precondition violation) means the registry refuses a
       new fiber. Forking anyway created a live keepalive loop in a state
       the sweep and dashboard treat as not running. Resolve [done_p]
       through the crash path so supervise/restart waiters observe a typed
       outcome and the next sweep re-queues with the usual backoff/budget. *)
    let reason =
      Printf.sprintf
        "fiber_start_rejected: %s"
        (Keeper_state_machine.transition_error_to_string err)
    in
    Log.Keeper.warn
      "%s: Fiber_started rejected during supervised launch — launch aborted: %s"
      meta.name
      (Keeper_state_machine.transition_error_to_string err);
    Otel_metric_store.inc_counter
      Keeper_metrics.(to_string SupervisorCleanupFailures)
      ~labels:
        [ "keeper", meta.name
        ; ("site", Keeper_supervisor_cleanup_failure_site.(to_label Fiber_start_rejected))
        ]
      ();
    Keeper_registry.set_failure_reason
      ~base_path
      meta.name
      (Some (Keeper_registry.Exception reason));
    Keeper_registry.record_crash ~base_path meta.name (Time_compat.now ()) reason;
    Keeper_registry_error_recording.record ~base_path meta.name reason;
    if
      Keeper_registry.resolve_done reg ~source:"supervisor_launch_rejected" (`Crashed reason)
      |> done_signal_of_registry_result
      |> should_publish_lifecycle_for_done_signal
    then
      publish_phase_lifecycle ~phase:Keeper_state_machine.Crashed meta.name reason ();
    (match Keeper_lane.reject_before_start reg.lane ~reason:(Failure reason) with
     | Ok () -> ()
     | Error lane_error ->
       Log.Keeper.error
         "%s: rejected launch could not close lane join contract: %s"
         meta.name
         (Keeper_lane.start_error_to_string lane_error));
    Error err
  | Ok _ ->
    launch_supervised_fiber_body ~proactive_warmup_sec ctx meta reg;
    Ok ()
;;

(* #10993: persona drift visibility.

   [Keeper_identity.normalize_all_names ~check_persona:true] runs on
   every dispatch via [Mcp_tool_runtime_workspace] (RFC P3-a
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
let reconcile_keepalive_keepers ~load_or_materialize_keeper_meta (ctx : _ context)
  =
  Keeper_supervisor_reconcile_keepalive.reconcile_keepalive_keepers
    ~publish_lifecycle
    ~supervise_keepalive
    ~load_or_materialize_keeper_meta
    ctx
;;

(* Dead-tombstone cleanup submits a durable exact-lane finalization operation;
   completion events/hooks are delivered from its durable receipt. *)
let cleanup_dead_tombstone (ctx : _ context) (entry : Keeper_registry.registry_entry) =
  Keeper_supervisor_cleanup_tombstone.cleanup_dead_tombstone ctx entry
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

let handle_turn_failure_streak_pause ctx entry =
  Pause_policy.handle_turn_failure_streak_pause ~publish_phase_lifecycle ctx entry
;;

let failure_reason_policy_decision = Pause_policy.failure_reason_policy_decision
let failure_reason_policy_decision_for_test = failure_reason_policy_decision
