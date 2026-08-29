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

let keep_last_n = Startup_helpers.keep_last_n

(** supervision_cohort cluster moved to Keeper_supervisor_types
    (intra-library file split, 2026-05-16). *)
include Keeper_supervisor_types

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

type cleanup_attempt_outcome =
  | Cleanup_completed
  | Cleanup_cancelled
  | Cleanup_failed of exn

let run_cleanup_best_effort cleanup =
  try
    cleanup ();
    Cleanup_completed
  with
  | Eio.Cancel.Cancelled _ -> Cleanup_cancelled
  | exn -> Cleanup_failed exn
;;

(* ── Event publishing (see Keeper_supervisor_publish_lifecycle, #8856/#8605) ─ *)

let publish_lifecycle = Keeper_supervisor_publish_lifecycle.publish_lifecycle
let publish_phase_lifecycle = Keeper_supervisor_publish_lifecycle.publish_phase_lifecycle
(* ── Supervised fiber launch ─────────────────────────────── *)

let set_global_switch = Keeper_process_switch.set
let get_global_switch = Keeper_process_switch.get

let set_restart_launch_noop_for_test = Keeper_supervisor_restart_noop.set
let restart_launch_noop_enabled_for_test = Keeper_supervisor_restart_noop.enabled
let with_restart_launch_noop_for_test = Keeper_supervisor_restart_noop.with_noop

let launch_supervised_fiber_body
      ?intake_token
      ~lifecycle_token
      ~proactive_warmup_sec
      ctx
      (meta : keeper_meta)
      (reg : Keeper_registry.registry_entry)
  =
  let base_path = ctx.config.base_path in
  let keepers_dir = Workspace.keepers_runtime_dir ctx.config in
  if restart_launch_noop_enabled_for_test ()
  then (* test no-op launch: nothing forked, but not a fork rejection *) Ok ()
  else (
    let lifecycle_result = Atomic.make None in
    let finish_lifecycle boundary terminalize =
      let result =
        Keeper_keepalive_launch_transaction.finish_lifecycle
          ~boundary
          ~base_path
          ~keeper_name:meta.name
          ~terminalize
      in
      Atomic.set lifecycle_result (Some result);
      result
    in
    (* Task 137: Inject bootstrap signal to ensure at least one warm-up turn runs
     and break the initial proactive deadlock. *)
    let bootstrap_signal : Keeper_event_queue.stimulus =
      { post_id = "bootstrap"
      ; urgency = Keeper_event_queue.Normal
      ; arrived_at = Unix.gettimeofday ()
      ; payload = Keeper_event_queue.Bootstrap
      }
    in
    Keeper_registry_event_queue.enqueue
      ?intake_token
      ~base_path
      meta.name
      bootstrap_signal;
    let fork_body body =
      match
        Keeper_lane.fork
          ~sw:ctx.sw
          reg.lane
          ~run:body
          ~cleanup:(fun _ ->
            match Atomic.get lifecycle_result with
            | Some result -> result
            | None ->
              finish_lifecycle
                Keeper_keepalive_launch_transaction.Unexpected
                (fun () -> Error "supervisor lane exited without terminal disposition"))
      with
      | Ok () -> Ok ()
      | Error error ->
        (* Fork was rejected (parent switch already cancelling, or
           [claim_start] refused): no keepalive fiber is running. Resolve the
           registry crash path — [Keeper_lane.fork] already settled the lane
           exit for [Fork_failed] — publish [Crashed] under the same
           dedupe guard the launch gate uses, and propagate an error so the
           caller suppresses the Started/Running lifecycle for a keeper whose
           lane was never forked (mirrors [prepare_fiber_launch]'s rejection
           path). *)
        let detail = Keeper_lane.start_error_to_string error in
        let owns_terminal_signal =
          Keeper_registry.resolve_done
            reg
            ~source:"supervisor_lane_start_rejected"
            (`Crashed detail)
          |> done_signal_of_registry_result
          |> should_publish_lifecycle_for_done_signal
        in
        if owns_terminal_signal
        then (
          let _failure_reason_recorded =
            Keeper_registry.update_entry_exact_for_lifecycle
              lifecycle_token
              reg
              (fun current ->
                { current with
                  last_failure_reason = Some (Keeper_registry.Exception detail)
                })
            |> Keeper_registry.exact_update_succeeded
                 reg
                 ~site:"supervisor_lane_start_rejected.failure_reason"
          in
          let terminalized =
            match
              Keeper_registry.dispatch_event_exact_for_lifecycle
                lifecycle_token
                reg
                (Keeper_state_machine.Fiber_terminated
                   { outcome = detail; provider_id = None; http_status = None })
            with
            | Ok _ -> true
            | Error transition_error ->
              Otel_metric_store.inc_counter
                Keeper_metrics.(to_string DispatchEventFailures)
                ~labels:[ "keeper", meta.name; "event", "fiber_terminated" ]
                ();
              Log.Keeper.warn
                "supervisor: exact-lane fork-rejection terminalization failed: %s"
                (Keeper_state_machine.transition_error_to_string transition_error);
              false
          in
          let _crash_recorded =
            Keeper_registry.update_entry_exact_for_lifecycle
              lifecycle_token
              reg
              (fun current ->
                Keeper_registry_error_tracking.record_crash_entry
                  current
                  (Time_compat.now ())
                  detail)
            |> Keeper_registry.exact_update_succeeded
                 reg
                 ~site:"supervisor_lane_start_rejected.crash_log"
          in
          Keeper_registry_error_recording.record_exact_for_lifecycle
            lifecycle_token
            reg
            detail;
          if terminalized
          then
            publish_phase_lifecycle
              ~phase:Keeper_state_machine.Crashed
              meta.name
              detail
              ()
          else
            match
              Keeper_registry.unregister_exact_for_lifecycle lifecycle_token reg
            with
            | Keeper_registry.Exact_unregistered ->
              Log.Keeper.error
                "supervisor: removed non-terminalizable fork-rejected lane name=%s"
                meta.name
            | Keeper_registry.Exact_entry_missing ->
              Log.Keeper.warn
                "supervisor: fork-rejected lane was already unregistered name=%s"
                meta.name
            | Keeper_registry.Exact_entry_replaced ->
              Log.Keeper.warn
                "supervisor: fork-rejected lane retained newer same-name owner name=%s"
                meta.name
            | Keeper_registry.Exact_unregister_lifecycle_reserved owner ->
              Log.Keeper.info
                "supervisor: fork-rejected lane cleanup deferred to lifecycle transaction owner name=%s %s"
                meta.name
                (Keeper_lifecycle_reservation.snapshot_to_string owner));
        Error
          (Keeper_state_machine.Precondition_violation
             { event = "supervisor_lane_fork"; reason = detail })
    in
    fork_body (fun lane_sw ->
      let ctx = { ctx with sw = lane_sw } in
      let resolved = Atomic.make false in
      (* Preserve the exact typed cancellation origin after the supervised
         body consumes [Eio.Cancel.Cancelled]. The finally branch can then
         distinguish an operator lane shutdown from parent cancellation and
         from a genuine missed-resolution bug. *)
      let cancelled_by_parent = Atomic.make false in
      let cancelled_by_shutdown_request = Atomic.make false in
      (* Process-local sibling lifetime only: heartbeat completion closes the
         Board worker without creating durable admission or recovery state. *)
      let board_worker_stop, resolve_board_worker_stop = Eio.Promise.create () in
      let stop_board_worker () =
        ignore (Eio.Promise.try_resolve resolve_board_worker_stop () : bool)
      in
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
             (* MASC owns the worker's input and durable callbacks, while AGENT_CORE
                owns target admission, dispatch, and advancement. The fork
                itself lives in [Keeper_keepalive] so both lane-start paths
                produce the same lane. *)
             Keeper_keepalive.fork_board_attention_worker
               ~sw:lane_sw
               ~ctx
               ~keeper_name:meta.name
               ~stop:board_worker_stop;
             (* Keeper lifetime, idle duration, and progress age are
                observations only. The supervisor runs the lane directly;
                configured provider/tool boundaries and explicit operator
                lifecycle events remain independent typed mechanisms. *)
             Eio_guard.protect
               (fun () ->
                  Keeper_keepalive.run_heartbeat_loop
                    ~proactive_warmup_sec
                    ctx
                    meta
                    reg.fiber_stop
                    ~wakeup:reg.fiber_wakeup
                    ~cadence_sleeping:reg.cadence_sleeping)
               ~finally:stop_board_worker;
             (* A normal return is an explicit stop/shutdown path. Observed
                idle/progress ages never rewrite it into a crash. *)
             let terminalize_normal () =
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
                   ();
               Ok ()
             in
             ignore
               (finish_lifecycle
                  Keeper_keepalive_launch_transaction.Graceful
                  terminalize_normal
                : (unit, string) result)
           with
           | Eio.Cancel.Cancelled cause ->
             (match Keeper_lane.classify_cancellation_cause cause with
              | Keeper_lane.Shutdown_request ->
                Atomic.set cancelled_by_shutdown_request true
              | Keeper_lane.External_cancel _ -> Atomic.set cancelled_by_parent true);
             (* Do NOT re-raise Cancelled in a forked fiber, as it cancels the parent switch. *)
             ()
           | exn ->
             (* RFC-0002: unified crash handler.
                Keeper_fiber_crash carries no payload — failure_reason is
                pre-stored in registry by the raise site.
                For unexpected exceptions, wrap in Exception variant. *)
             let terminalize_crash () =
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
                 ();
             Ok ()
             in
             ignore
               (finish_lifecycle
                  Keeper_keepalive_launch_transaction.Unexpected
                  terminalize_crash
                : (unit, string) result))
        ~finally:(fun () ->
          (* Finally runs best-effort. Any exception raised here (including
           Eio.Cancel.Cancelled, which propagates during concurrent fiber
           teardown) would be re-wrapped by [Fun.protect] as
           [Fun.Finally_raised], masking the original body exception and
           crashing the server (see masc crash 2026-04-17). Swallow
           everything and log — cleanup is advisory, state-machine events
           already fired on the body's happy/error paths. *)
          match run_cleanup_best_effort (fun () ->
            Keeper_registry.cleanup_tracking ~base_path meta.name;
            Keeper_turn_attempt_observer.reset_keeper ~base_path ~keeper:meta.name;
            if not (Atomic.get resolved)
            then (
              let boundary =
                if
                  Shutdown.is_shutting_down_global ()
                  || Atomic.get cancelled_by_shutdown_request
                then Keeper_keepalive_launch_transaction.Graceful
                else Keeper_keepalive_launch_transaction.Unexpected
              in
              let terminalize_unresolved () =
              if Shutdown.is_shutting_down_global ()
              then (
                (* Issue #18901: graceful-shutdown branch. Tag the failure
                   reason with [Graceful_shutdown] cause so the cohort
                   key splits away from the legacy "fiber_unresolved"
                   ERROR cohort. Severity stays at INFO via the
                   [Log.Keeper.info] call below — record_crash is not
                   invoked here because shutdown drops are bookkeeping,
                   not crash observations. *)
                Log.Keeper.info
                  "%s: fiber unresolved during shutdown (graceful, not a crash)"
                  meta.name;
                Keeper_registry.set_failure_reason
                  ~base_path
                  meta.name
                  (Some (Keeper_registry.Fiber_unresolved Graceful_shutdown));
                Keeper_registry.dispatch_event_unit
                  ~base_path
                  meta.name
                  (Keeper_state_machine.Fiber_terminated
                     { outcome = "shutdown"; provider_id = None; http_status = None });
                (* fire-and-forget: resolve_done signals completion *)
                ignore
                  (resolve_done
                     ~source:"supervisor_shutdown_cleanup"
                     (`Crashed "shutdown")))
              else if Atomic.get cancelled_by_shutdown_request
              then (
                (* Exact exception identity distinguishes an operator lane
                   shutdown from parent cancellation. A requested shutdown is
                   a graceful stop, so the operator observes a joined stop
                   rather than a crash/tombstone. *)
                Log.Keeper.info
                  "%s: fiber stopped by shutdown request (graceful, not a crash)"
                  meta.name;
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
                  resolve_done ~source:"supervisor_shutdown_requested" `Stopped
                  |> should_publish_lifecycle_for_done_signal
                then
                  publish_phase_lifecycle
                    ~phase:Keeper_state_machine.Stopped
                    meta.name
                    "shutdown requested"
                    ())
              else if Atomic.get cancelled_by_parent
              then (
                (* Issue #18901 follow-up: parent-cancel branch. The
                   body's try/with caught [Eio.Cancel.Cancelled] and set
                   the flag before re-raising. Shutdown was not in
                   progress, so this is a *supervisor-driven* cancel
                   (restart, sibling failure propagating cancel) rather
                   than a missed-resolution bug. WARN severity, separate
                   cohort, no record_crash — parent cancels are
                   expected lifecycle events, not crash observations. *)
                Log.Keeper.warn
                  "%s: fiber unresolved after parent cancellation (transient)"
                  meta.name;
                Keeper_registry.set_failure_reason
                  ~base_path
                  meta.name
                  (Some (Keeper_registry.Fiber_unresolved Cancelled_by_parent));
                Keeper_registry.dispatch_event_unit
                  ~base_path
                  meta.name
                  (Keeper_state_machine.Fiber_terminated
                     { outcome = "cancelled_by_parent"
                     ; provider_id = None
                     ; http_status = None
                     });
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
                    ());
                Ok ()
              in
              ignore
                (finish_lifecycle boundary terminalize_unresolved
                  : (unit, string) result)))
          with
          | Cleanup_completed -> ()
          | Cleanup_cancelled ->
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
          | Cleanup_failed exn ->
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
      ?intake_token
      ~lifecycle_token
      ~proactive_warmup_sec
  ctx
  (meta : keeper_meta)
  (reg : Keeper_registry.registry_entry)
  =
  match Keeper_registry.prepare_fiber_launch_for_lifecycle lifecycle_token reg with
  | Error err ->
    (* Fail closed: a rejected [Fiber_started] (terminal state, invalid
       transition, precondition violation) means the registry refuses a
       new fiber. Forking anyway created a live keepalive loop in a state
       the sweep and dashboard treat as not running. Resolve [done_p]
       through the crash path so supervise/restart waiters observe a typed
       outcome and the next sweep re-queues with the usual lane-local backoff. *)
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
    ignore
      (Keeper_registry.update_entry_exact_for_lifecycle
         lifecycle_token
         reg
         (fun current ->
            { current with
              last_failure_reason = Some (Keeper_registry.Exception reason)
            })
       |> Keeper_registry.exact_update_succeeded
            reg
            ~site:"supervisor_launch_rejected.failure_reason");
    ignore
      (Keeper_registry.update_entry_exact_for_lifecycle
         lifecycle_token
         reg
         (fun current ->
            Keeper_registry_error_tracking.record_crash_entry
              current
              (Time_compat.now ())
              reason)
       |> Keeper_registry.exact_update_succeeded
            reg
            ~site:"supervisor_launch_rejected.crash_log");
    Keeper_registry_error_recording.record_exact_for_lifecycle
      lifecycle_token
      reg
      reason;
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
    (* Propagate the fork outcome: a rejected [Keeper_lane.fork] returns
       [Error] here so the caller suppresses the Started/Running lifecycle
       for a keeper whose lane was never forked. *)
    launch_supervised_fiber_body
      ?intake_token
      ~lifecycle_token
      ~proactive_warmup_sec
      ctx
      meta
      reg
;;

let supervise_keepalive ~proactive_warmup_sec (ctx : _ context) (meta : keeper_meta) =
  Keeper_supervisor_supervise_keepalive.supervise_keepalive
    ~publish_lifecycle
    ~launch_supervised_fiber:(fun ~intake_token ->
      launch_supervised_fiber ~intake_token)
    ~proactive_warmup_sec
    ctx
    meta
;;

(* ── Sweep and recover ───────────────────────────────────── *)

(** Reconcile only orphaned or cleanly stopped durable keepers.
    Running/Paused/Crashed entries are actively managed by sweep
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

