(* keeper_turn_slot — semaphores, autonomous wait queue, budget-exhaustion strikes,
   and the main [with_keeper_turn_slot] gate.

   Head section (types, throttle config, semaphore, holder table, bookkeeping)
   extracted to Keeper_turn_slot_acquire as part of godfile near-threshold split. *)

open Keeper_types
open Keeper_meta_contract
open Keeper_types_profile

include Keeper_turn_slot_acquire


let release_recorded_holder
      ?(before_release = fun () -> ())
      ~keeper_name
      ~label
      ~acquisition_id
      sem
  =
  let label_str = slot_pool_to_string label in
  match acquisition_id with
  | None ->
    Log.Keeper.warn
      "release_keeper_turn_slot: %s holder for %s missing acquisition id; releasing \
       semaphore defensively"
      label_str
      keeper_name;
    before_release ();
    Eio.Semaphore.release sem
  | Some acquisition_id ->
    let force_released =
      try consume_force_release ~label ~keeper_name ~acquisition_id with
      | Eio.Cancel.Cancelled _ ->
        observe_bookkeeping_failure ~op:("drop_holder " ^ label_str) ~kind:Keeper_bookkeeping_failure_kind.Cancelled;
        Log.Keeper.warn
          "release_keeper_turn_slot: drop_holder %s skipped (Cancelled)"
          label_str;
        false
      | exn ->
        observe_bookkeeping_failure ~op:("drop_holder " ^ label_str) ~kind:Keeper_bookkeeping_failure_kind.Exception;
        Log.Keeper.warn
          "release_keeper_turn_slot: drop_holder %s failed: %s"
          label_str
          (Printexc.to_string exn);
        false
    in
    if force_released
    then
      Log.Keeper.debug
        "release_keeper_turn_slot: %s holder for %s was already force-released"
        label_str
        keeper_name
    else (
      before_release ();
      Eio.Semaphore.release sem)
;;

let release_keeper_turn_slot_impl ~keeper_name ~(stamp_autonomous_completion : bool) state
  =
  safe_bookkeeping ~op:"drop_autonomous_waiter" (fun () ->
    Option.iter (fun ticket -> drop_autonomous_waiter ~ticket) !(state.autonomous_ticket));
  state.autonomous_ticket := None;
  (* Release exactly what we acquired. The turn, autonomous, and reactive
     semaphores account for separate quotas, so release order does not affect
     permit ownership. *)
  if !(state.acquired_turn)
  then (
    release_recorded_holder
      ~keeper_name
      ~label:Turn_pool
      ~acquisition_id:!(state.turn_acquisition_id)
      turn_semaphore;
    state.acquired_turn := false;
    state.turn_acquisition_id := None);
  if !(state.acquired_autonomous)
  then (
    release_recorded_holder
      ~keeper_name
      ~label:Autonomous_pool
      ~acquisition_id:!(state.autonomous_acquisition_id)
      ~before_release:(fun () ->
        (* Stamp completion time only for normal completion, before releasing
           the semaphore so that [maybe_yield_for_fairness] can measure the
           correct interval when this keeper's heartbeat loops back
           immediately. *)
        if stamp_autonomous_completion
        then
          safe_bookkeeping ~op:"record_autonomous_completion" (fun () ->
            record_autonomous_completion ~keeper_name))
      autonomous_turn_semaphore;
    state.acquired_autonomous := false;
    state.autonomous_acquisition_id := None);
  if !(state.acquired_reactive)
  then (
    release_recorded_holder
      ~keeper_name
      ~label:Reactive_pool
      ~acquisition_id:!(state.reactive_acquisition_id)
      reactive_turn_semaphore;
    state.acquired_reactive := false;
    state.reactive_acquisition_id := None)
;;

let release_keeper_turn_slot ~keeper_name state =
  release_keeper_turn_slot_impl ~keeper_name ~stamp_autonomous_completion:true state
;;

let release_keeper_turn_slot_for_retry ~keeper_name state =
  release_keeper_turn_slot_impl ~keeper_name ~stamp_autonomous_completion:false state
;;

(** Force-release every slot recorded for [keeper_name] in [holder_table].
    Called by the supervisor when a keeper has been declared crashed but
    its fiber has not returned through the [Fun.protect] finally branch
    in [with_keeper_turn_slot] — typically because the LLM subprocess
    swallowed the cancellation and never produced [Eio.Cancel.Cancelled].

    Returns the list of [(label, age_sec)] pairs that were force-released
    so the supervisor can stamp the diagnosis onto the keeper meta. The
    list is empty when nothing was held.

    Idempotency / over-release: the natural release path
    ([release_keeper_turn_slot]) checks [state.acquired_*] flags before
    calling [Eio.Semaphore.release]. After force-release the holder
    table no longer has the entry, but the keeper's [slot_state] flags
    remain set — so a late-returning fiber will release the semaphore a
    second time, raising the count above [reactive_turn_limit] briefly
    (Eio counting semaphores allow over-release safely; the count just
    re-converges on the next saturation). The bounded over-release is
    accepted as the cost of unblocking the fleet — the alternative
    ([slot_state] reaching the supervisor across closures) would
    require shared mutable state that the current architecture
    deliberately keeps closure-local.

    2026-05-05 motivation: 16 keepers held [reactive_slot] for 18-25
    minutes each behind LLM subprocess hangs while
    [reactive_available=0]. The existing [force_unresolved_watchdog_crash]
    path stamps the keeper as crashed but does not return the slot, so
    the next cohort of keepers waits another 180s on
    [acquire_bounded] and trips the same idle-turn watchdog. *)
let force_release_holder_for ~keeper_name : (string * float) list =
  let now = Time_compat.now () in
  let released_with_age = ref [] in
  let try_release ~label ~sem =
    let snapshots =
      with_holder_lock (fun () ->
        purge_expired_force_released_holders_locked ~now;
        let table = Atomic.get holder_table_atomic in
        let matching =
          Holder_map.fold
            (fun key acquired_at acc ->
               if
                 key.holder_label = label
                 && String.equal key.holder_keeper_name keeper_name
               then (key, acquired_at) :: acc
               else acc)
            table
            []
        in
        let next_table =
          List.fold_left
            (fun acc (key, _) -> Holder_map.remove key acc)
            table
            matching
        in
        Atomic.set holder_table_atomic next_table;
        List.iter
          (fun (key, _) -> Hashtbl.replace force_released_holders key now)
          matching;
        matching)
    in
    let label_str = slot_pool_to_string label in
    List.iter
      (fun (_key, acquired_at) ->
         let age = now -. acquired_at in
         Eio.Semaphore.release sem;
         released_with_age := (label_str, age) :: !released_with_age;
         Otel_metric_store.inc_counter
           Keeper_metrics.(to_string SlotForceReleased)
           ~labels:[ "keeper", keeper_name; "label", label_str ]
           ();
         Log.Keeper.error
           "%s: force-released %s slot held for %.0fs (zombie fiber, likely stuck in LLM \
            subprocess)"
           keeper_name
           label_str
           age)
      snapshots
  in
  try_release ~label:Reactive_pool ~sem:reactive_turn_semaphore;
  try_release ~label:Autonomous_pool ~sem:autonomous_turn_semaphore;
  try_release ~label:Turn_pool ~sem:turn_semaphore;
  !released_with_age
;;

let reset_autonomous_completion_for_test () : unit =
  with_completion_table (fun () -> Hashtbl.reset last_autonomous_completion)
;;

(* PR-M (Leak 9): consecutive [provider_timeout] cycle FAILED strikes
   per keeper.

   [provider_timeout] is the canonical policy surface for the legacy
   structured timeout-budget path
   (see [Keeper_unified_turn.resolve_bounded_provider_timeout_budget_with_turn_budget]).
   Re-running on the same fiber gives the same context and the same
   shape of failure repeats, but provider/runtime budget pressure is not
   keeper fiber corruption. Crossing [provider_timeout_strike_limit]
   is therefore routed through [Keeper_failure_policy] before any
   lifecycle effect is applied. Without independent keeper-liveness
   loss, the keeper stays alive while provider cooldown, runtime
   backpressure, and turn retry policy do the actual throttling.

   Counter is in-memory for the common same-server case and is reset on
   any successful turn (see [Ok updated] branch). On first bump after a
   process restart, callers may seed it from the persisted
   [Provider_timeout_loop] failure reason so restart cannot erase a
   partially observed loop. *)
let provider_timeout_strike_limit = 3

type provider_timeout_strike_outcome =
  | Provider_timeout_warn
  | Provider_timeout_soft_backoff

let classify_provider_timeout_strike ~strikes =
  if strikes >= provider_timeout_strike_limit
  then Provider_timeout_soft_backoff
  else Provider_timeout_warn

module Budget_strike_map = Set_util.StringMap

(* Stdlib.Mutex: this ledger is updated from keeper Eio fibers and from
   non-Eio unit tests. The critical section is pure map replacement and
   cannot yield, so a plain mutex avoids the previous CAS retry loop without
   introducing Eio-context requirements. *)
let budget_exhaustions_mutex = Stdlib.Mutex.create ()
let budget_exhaustions : int Budget_strike_map.t ref = ref Budget_strike_map.empty

let update_budget_exhaustions f =
  Stdlib.Mutex.lock budget_exhaustions_mutex;
  Fun.protect
    ~finally:(fun () -> Stdlib.Mutex.unlock budget_exhaustions_mutex)
    (fun () ->
       let next, result = f !budget_exhaustions in
       budget_exhaustions := next;
       result)
;;

let bump_budget_exhaustion_seeded ~keeper_name ~prior_strikes : int =
  let prior_strikes = max 0 prior_strikes in
  update_budget_exhaustions (fun current ->
    let current_strikes =
      Budget_strike_map.find_opt keeper_name current
      |> Option.value ~default:prior_strikes
    in
    let next_strikes = max current_strikes prior_strikes + 1 in
    Budget_strike_map.add keeper_name next_strikes current, next_strikes)
;;

let bump_budget_exhaustion ~keeper_name : int =
  bump_budget_exhaustion_seeded ~keeper_name ~prior_strikes:0
;;

let reset_budget_exhaustion ~keeper_name : unit =
  update_budget_exhaustions (fun current ->
    Budget_strike_map.remove keeper_name current, ())
;;

let peek_budget_exhaustion_for_test ~keeper_name : int =
  update_budget_exhaustions (fun current ->
    let strikes =
      Budget_strike_map.find_opt keeper_name current |> Option.value ~default:0
    in
    current, strikes)
;;

let set_budget_exhaustion_for_test ~keeper_name ~strikes : unit =
  if strikes <= 0
  then reset_budget_exhaustion ~keeper_name
  else
    update_budget_exhaustions (fun current ->
      Budget_strike_map.add keeper_name strikes current, ())
;;

(** Test-only: stamp a completion time directly without going through
    [Time_compat.now].  Allows deterministic fairness-cooldown scenarios. *)
let record_autonomous_completion_at_for_test ~(keeper_name : string) ~(ts : float) : unit =
  with_completion_table (fun () ->
    Hashtbl.replace last_autonomous_completion keeper_name ts)
;;

(** Minimum gap between consecutive autonomous turns from the same keeper
    when other keepers are waiting in the FIFO queue. 0 disables fairness
    cooldown entirely (pre-#6810 behavior).

    Default 5s gives peers a chance to win head-of-queue after a fast
    keeper releases the semaphore, even when the fast keeper's heartbeat
    immediately loops back.

    Env: [MASC_KEEPER_AUTONOMOUS_FAIRNESS_COOLDOWN_SEC]. Range [0, 60]. *)
let autonomous_fairness_cooldown_sec =
  Keeper_config.float_of_env_default
    "MASC_KEEPER_AUTONOMOUS_FAIRNESS_COOLDOWN_SEC"
    ~default:5.0
    ~min_v:0.0
    ~max_v:60.0
;;

let others_waiting_in_queue ~(keeper_name : string) : bool =
  with_autonomous_wait_queue (fun () ->
    prune_autonomous_wait_queue_locked ();
    let found = ref false in
    Queue.iter
      (fun w ->
         if
           (not !found)
           && Hashtbl.mem autonomous_wait_queue_active_tickets w.ticket
           && w.keeper_name <> keeper_name
         then found := true)
      autonomous_wait_queue;
    !found)
;;

(** Pure computation: how many seconds [keeper_name] should yield before
    re-entering the queue at time [now].  Returns [0.0] when no yield is
    needed.  Extracted so the delay logic is testable without Eio. *)
let fairness_delay_sec_at ~(now : float) ~(keeper_name : string) : float =
  if autonomous_fairness_cooldown_sec <= 0.0
  then 0.0
  else if not (others_waiting_in_queue ~keeper_name)
  then 0.0
  else (
    match
      with_completion_table (fun () ->
        Hashtbl.find_opt last_autonomous_completion keeper_name)
    with
    | None -> 0.0
    | Some last_done ->
      Float.max 0.0 (autonomous_fairness_cooldown_sec -. (now -. last_done)))
;;

(** Enforce fairness cooldown before re-entering the autonomous queue.
    If this keeper just completed a turn AND other keepers are waiting,
    yield for the remainder of [autonomous_fairness_cooldown_sec] before
    appending our ticket. Called from [with_keeper_turn_slot] before
    [enqueue_autonomous_waiter]. *)
let maybe_yield_for_fairness ~(keeper_name : string) : unit =
  let remaining = fairness_delay_sec_at ~now:(Time_compat.now ()) ~keeper_name in
  if remaining > 0.0
  then (
    Log.Keeper.info
      "fairness_cooldown: keeper=%s yielding %.2fs (queue has other waiters)"
      keeper_name
      remaining;
    match Eio_context.get_clock_opt () with
    | Some clock -> Eio.Time.sleep clock remaining
    | None ->
      (* No Eio clock available: bound the wait so the fairness loop does
           not spin under contention. [Eio.Fiber.yield] imposes no minimum
           delay; 5ms is only a no-clock fallback hint. Production paths
           always have a clock and take the [Some clock] branch above. *)
      Time_compat.sleep 0.005)
;;

let rec wait_for_autonomous_queue_head
          ~(keeper_name : string)
          ~(ticket : int)
          ~(started_at : float)
  : (unit, [> `Semaphore_wait_timeout of semaphore_wait_timeout ]) result
  =
  if Option.equal Int.equal (autonomous_waiter_head_ticket ()) (Some ticket)
  then Ok ()
  else (
    let waited_sec = Time_compat.now () -. started_at in
    if waited_sec >= semaphore_wait_timeout_sec
    then (
      let ahead =
        match autonomous_waiter_position ~ticket with
        | Some idx -> idx
        | None -> 0
      in
      (* INFO not WARN: this is a fail-safe — the keeper is voluntarily
         skipping its slot in the queue and will retry on the next
         cycle. WARN-level here produced ~38 entries per ~3MB log
         window with 12 keepers contending on a 60s wait budget. The
         operator only needs to know if these dominate; per-event
         noise is harmful. Live log evidence: 2026-04-16 /loop iter 8. *)
      Log.Keeper.info
        "semaphore_wait: autonomous fairness queue wait exceeded %.0fs (keeper=%s \
         ahead=%d), skipping turn"
        semaphore_wait_timeout_sec
        keeper_name
        ahead;
      (* #9771: surface the timeout as a fleet-wide metric so
         operators can detect chronic slot starvation without
         scraping the WARN log. *)
      Otel_metric_store.inc_counter
        Keeper_metrics.(to_string SemaphoreWaitTimeout)
        ~labels:[ "keeper", keeper_name; "channel", "autonomous_queue_head" ]
        ();
      Error
        (`Semaphore_wait_timeout
            (semaphore_wait_timeout_snapshot
               ~phase:Autonomous_queue_head
               ~queue_ahead:ahead
               ())))
    else (
      (match Eio_context.get_clock_opt () with
       | Some clock -> Eio.Time.sleep clock autonomous_queue_poll_sec
       | None ->
         (* Environment drift: production should always have an Eio clock.
              Yield cooperatively instead of using a blocking Unix sleep so
              the Eio convention guard remains satisfied. *)
         Eio.Fiber.yield ());
      wait_for_autonomous_queue_head ~keeper_name ~ticket ~started_at))
;;

let semaphore_wait_seconds_buckets =
  [ 0.001; 0.005; 0.01; 0.025; 0.05; 0.1; 0.25; 0.5; 1.0; 2.5; 5.0; 10.0; 30.0; 60.0 ]
;;

let observe_semaphore_wait_seconds ~keeper_name ~runtime_profile ~channel seconds =
  let seconds = if seconds < 0.0 then 0.0 else seconds in
  let labels =
    [ "keeper_name", keeper_name; "runtime_profile", runtime_profile; "channel", channel ]
  in
  Otel_metric_store.observe_histogram
    Keeper_metrics.(to_string SemaphoreWaitSeconds)
    ~labels
    seconds;
  let inc_bucket le =
    Otel_metric_store.inc_counter
      Keeper_metrics.(to_string SemaphoreWaitSecondsBucket)
      ~labels:(labels @ [ "le", le ])
      ()
  in
  List.iter
    (fun upper -> if seconds <= upper then inc_bucket (Printf.sprintf "%g" upper))
    semaphore_wait_seconds_buckets;
  inc_bucket "+Inf"
;;

let with_keeper_turn_slot_control ?(runtime_profile = "unknown") ~keeper_name ~channel f =
  let is_autonomous =
    match channel with
    | Keeper_world_observation.Scheduled_autonomous -> true
    | Keeper_world_observation.Reactive -> false
  in
  (* Issue #8569: derive the [channel=…] log label from the SSOT
     [Keeper_world_observation.channel_to_string], not from a local
     [if is_autonomous] branch. The boolean drives routing (semaphore
     selection); the label belongs to the Variant SSOT, which emits
     [scheduled_autonomous] (full snake_case). The previous local
     branch emitted [autonomous] (truncated), splitting [channel=…]
     log lines from every other surface that uses the SSOT helper —
     operators grepping for one form silently missed the other. *)
  let channel_label = Keeper_world_observation.channel_to_string channel in
  (* Track acquisitions in mutable flags so the outer Fun.protect can
     release exactly the slots we hold — regardless of which result or
     exception path fires (Eio.Cancel.Cancelled or any other). This
     keeps resource cleanup independent of Eio.Semaphore's internal
     cancel-race handling. *)
  let slot_state = make_keeper_turn_slot_state () in
  let acquire_bounded ~label ~phase sem =
    let label_str = slot_pool_to_string label in
    match Eio_context.get_clock_opt () with
    | Some clock ->
      (try
         Eio.Time.with_timeout_exn clock semaphore_wait_timeout_sec (fun () ->
           Eio.Semaphore.acquire sem);
         (* Cancel-race fix: do NOT [record_holder] here. The caller
           records the holder AFTER setting the matching [acquired_*]
           flag in [slot_state]. If a fiber is cancelled between
           [Eio.Semaphore.acquire] returning and the caller's flag
           assignment, the release path stays consistent — flag=false
           means semaphore is treated as not-yet-held and the previous
           record_holder-here pattern would have left a stale entry
           visible in [holder_table] (the 16x1500s "ghost holders"
           symptom of 2026-05-05). *)
         Ok ()
       with
       | Eio.Time.Timeout ->
         (* Routine, not WARN: the keeper-specific heartbeat loop already
           emits the operator-facing skip warning with owner/runtime
           context, while the metric below preserves attribution.
           2026-05-05: also dump the actual holders so operators are
           not blind to *which* peer is starving the queue. *)
         let holders = snapshot_holders ~label ~now:(Time_compat.now ()) in
         let holder_summary = format_slot_holders holders in
         Log.Keeper.routine
           "semaphore_wait: %s semaphore wait exceeded %.0fs (channel=%s, holders=%s), \
            skipping turn"
           label_str
           semaphore_wait_timeout_sec
           channel_label
           holder_summary;
         (* #9771: per-keeper × per-acquire-channel counter so
           operators can attribute slot starvation to autonomous
           vs turn semaphore pressure. *)
         Otel_metric_store.inc_counter
           Keeper_metrics.(to_string SemaphoreWaitTimeout)
           ~labels:[ "keeper", keeper_name; "channel", label_str ]
           ();
         Error
           (`Semaphore_wait_timeout (semaphore_wait_timeout_snapshot ~phase ~holders ())))
    | None ->
      (* No Eio clock available: we are running outside an Eio main loop
         (e.g. Alcotest without [Eio_main.run]). Production masc
         always provides a clock via [Masc_eio_env.init]; reaching this
         branch at runtime would indicate an environment-setup drift.  If
         the permit is immediately available we can still acquire without
         waiting; otherwise fail closed rather than blocking forever. *)
      if Eio.Semaphore.get_value sem > 0
      then (
        Log.Keeper.warn
          "semaphore_wait: no Eio clock available — %s acquire is immediate only \
           (environment drift?)"
          label_str;
        Eio.Semaphore.acquire sem;
        (* Cancel-race fix: see comment in the with-clock branch above.
           record_holder is the caller's responsibility, after flag set. *)
        Ok ())
      else (
        let holders = snapshot_holders ~label ~now:(Time_compat.now ()) in
        Log.Keeper.warn
          "semaphore_wait: no Eio clock available and %s semaphore has no permits; \
           failing closed instead of waiting unboundedly"
          label_str;
        Otel_metric_store.inc_counter
          Keeper_metrics.(to_string SemaphoreWaitTimeout)
          ~labels:[ "keeper", keeper_name; "channel", label_str ]
          ();
        Error
          (`Semaphore_wait_timeout (semaphore_wait_timeout_snapshot ~phase ~holders ())))
  in
  let log_acquire_attempt () =
    let queue_depth = autonomous_wait_queue_depth () in
    Log.Keeper.routine
      "semaphore_acquire: keeper=%s channel=%s autonomous_available=%d turn_available=%d \
       queue_depth=%d"
      keeper_name
      channel_label
      (Eio.Semaphore.get_value autonomous_turn_semaphore)
      (Eio.Semaphore.get_value turn_semaphore)
      queue_depth;
    Otel_metric_store.set_gauge
      Keeper_metrics.(to_string TurnQueueDepth)
      ~labels:[ "keeper", keeper_name; "channel", channel_label ]
      (float_of_int queue_depth)
  in
  let acquire_all () =
    let t0 = Time_compat.now () in
    log_acquire_attempt ();
    let autonomous_result =
      if is_autonomous
      then (
        (* Fairness cooldown: if this keeper recently completed a turn and
             other keepers are waiting, yield before re-entering the FIFO
             queue to give peers a chance to reach head-of-queue first.
             See [maybe_yield_for_fairness] and #6810. *)
        maybe_yield_for_fairness ~keeper_name;
        let ticket = enqueue_autonomous_waiter ~keeper_name in
        slot_state.autonomous_ticket := Some ticket;
        (* Reset the queue-head timeout clock to the moment we bound the
             queue, NOT [t0] (slot-entry). Otherwise [maybe_yield_for_fairness]
             above silently consumes the [semaphore_wait_timeout_sec] budget
             before we even appear in the FIFO, producing the symptom
             "skipping turn (semaphore wait > 60s, peers holding slot,
             autonomous_available=N)" with N>0 because the slot is genuinely
             free but we ran out of budget while sleeping in fairness yield. *)
        let queue_entered_at = Time_compat.now () in
        match
          wait_for_autonomous_queue_head ~keeper_name ~ticket ~started_at:queue_entered_at
        with
        | Error _ as e -> e
        | Ok () ->
          (match
             acquire_bounded
               ~label:Autonomous_pool
               ~phase:Autonomous_slot
               autonomous_turn_semaphore
           with
           | Error _ as e -> e
           | Ok () ->
             (* Cancel-race fix (see acquire_bounded comment): set the
                 [acquired_*] flag BEFORE [record_holder]. The flag is a
                 plain ref assignment (no cancel point); record_holder
                 acquires a [~protect:true] mutex (cancel-safe within
                 the lock). If a cancel arrives between [acquire] and
                 here the semaphore is reported as not-held and never
                 leaks; if it arrives after the flag set, release path
                 calls drop_holder (no-op when no entry exists). *)
             slot_state.acquired_autonomous := true;
             run_after_acquire_flag_hook_for_test
               ~label:(slot_pool_to_string Autonomous_pool)
               ~keeper_name;
             let acquisition_id =
               record_holder
                 ~label:Autonomous_pool
                 ~keeper_name
                 ~acquired_at:(Time_compat.now ())
             in
             slot_state.autonomous_acquisition_id := Some acquisition_id;
             drop_autonomous_waiter ~ticket;
             slot_state.autonomous_ticket := None;
             Ok ()))
      else Ok ()
    in
    match autonomous_result with
    | Error _ as e -> e
    | Ok () ->
      let reactive_result =
        if is_autonomous
        then Ok ()
        else (
          match
            acquire_bounded
              ~label:Reactive_pool
              ~phase:Reactive_slot
              reactive_turn_semaphore
          with
          | Error _ as e -> e
          | Ok () ->
            (* Cancel-race fix: flag THEN record_holder. *)
            slot_state.acquired_reactive := true;
            run_after_acquire_flag_hook_for_test
              ~label:(slot_pool_to_string Reactive_pool)
              ~keeper_name;
            let acquisition_id =
              record_holder
                ~label:Reactive_pool
                ~keeper_name
                ~acquired_at:(Time_compat.now ())
            in
            slot_state.reactive_acquisition_id := Some acquisition_id;
            Ok ())
      in
      (match reactive_result with
       | Error _ as e -> e
       | Ok () ->
         (match acquire_bounded ~label:Turn_pool ~phase:Turn_slot turn_semaphore with
          | Error _ as e -> e
          | Ok () ->
            (* Cancel-race fix: flag THEN record_holder. *)
            slot_state.acquired_turn := true;
            run_after_acquire_flag_hook_for_test
              ~label:(slot_pool_to_string Turn_pool)
              ~keeper_name;
            let acquisition_id =
              record_holder
                ~label:Turn_pool
                ~keeper_name
                ~acquired_at:(Time_compat.now ())
            in
            slot_state.turn_acquisition_id := Some acquisition_id;
            let semaphore_wait_sec = Time_compat.now () -. t0 in
            observe_semaphore_wait_seconds
              ~keeper_name
              ~runtime_profile
              ~channel:channel_label
              semaphore_wait_sec;
            let semaphore_wait_ms =
              int_of_float
                ((if semaphore_wait_sec < 0.0 then 0.0 else semaphore_wait_sec) *. 1000.0)
            in
            Ok semaphore_wait_ms))
  in
  let slot_control =
    { release_for_retry =
        (fun () ->
          if keeper_turn_slot_is_held slot_state
          then (
            Log.Keeper.info
              "%s: releasing keeper turn slot before degraded retry"
              keeper_name;
            release_keeper_turn_slot_for_retry ~keeper_name slot_state))
    ; reacquire_after_retry =
        (fun () ->
          if keeper_turn_slot_is_held slot_state
          then (
            Log.Keeper.warn
              "%s: retry slot reacquire requested while a slot is still held; releasing \
               first"
              keeper_name;
            release_keeper_turn_slot_for_retry ~keeper_name slot_state);
          acquire_all ())
    }
  in
  Eio_guard.protect
    ~finally:(fun () -> release_keeper_turn_slot ~keeper_name slot_state)
    (fun () ->
       match acquire_all () with
       | Error _ as e -> e
       | Ok semaphore_wait_ms -> Ok (f ~semaphore_wait_ms ~slot_control))
;;

let with_keeper_turn_slot ?runtime_profile ~keeper_name ~channel f =
  with_keeper_turn_slot_control
    ?runtime_profile
    ~keeper_name
    ~channel
    (fun ~semaphore_wait_ms ~slot_control:_ -> f ~semaphore_wait_ms)
;;

let with_keeper_turn_slot_control_for_test ?runtime_profile ~keeper_name ~channel f =
  with_keeper_turn_slot_control ?runtime_profile ~keeper_name ~channel f
;;

let with_keeper_turn_slot_for_test ?runtime_profile ~keeper_name ~channel f =
  with_keeper_turn_slot ?runtime_profile ~keeper_name ~channel f
;;

let wait_for_autonomous_queue_head_for_test ~keeper_name ~ticket ~started_at =
  wait_for_autonomous_queue_head ~keeper_name ~ticket ~started_at
;;
