(* keeper_turn_slot — semaphores, autonomous wait queue, budget-exhaustion strikes,
   and the main [with_keeper_turn_slot] gate.

   Extracted from keeper_keepalive.ml to isolate concurrency-control logic
   from heartbeat lifecycle and snapshot concerns. *)

open Keeper_types

exception Semaphore_wait_timeout of float

let int_of_env_default_with_deprecated
    ~primary
    ~deprecated
    ~default
    ~min_v
    ~max_v
  =
  match Env_config_core.resolve_deprecated ~primary ~deprecated with
  | None -> default
  | Some raw ->
      let v =
        Option.value ~default (int_of_string_opt (String.trim raw))
      in
      Keeper_config.clamp_int v ~min_v ~max_v
;;

(* Global turn slot cap across autonomous + reactive pools.

   Sized for the observed 14-keeper fleet plus burst headroom. Operators
   running larger fleets raise [MASC_KEEPER_AUTOBOOT_MAX] explicitly; the
   only enforced floor is [min_v:1] (0 = deadlock). The previous [max_v:20]
   cap was a typo-defence boilerplate, not an architectural ceiling, and
   forced operator raise-cycles every time the fleet grew. Removed. *)
let keeper_turn_throttle_limit =
  int_of_env_default_with_deprecated
    ~primary:"MASC_KEEPER_AUTOBOOT_MAX"
    ~deprecated:"MASC_KEEPER_AUTOBOT_MAX"
    ~default:32
    ~min_v:1
    ~max_v:max_int
;;

let turn_semaphore = Eio.Semaphore.make keeper_turn_throttle_limit

(* 2026-05-05 fleet-stuck diagnosis: when a peer holds the semaphore
   for 60+ seconds the wait timeout WARN says "peers holding slot" but
   never names *which* peer.  Operators are then blind to which keeper
   is the actual blocker.

   Track holders in a single Hashtbl keyed by (label, keeper_name) so
   [acquire_bounded] can dump the live list on timeout.  Mutex-guarded
   because Eio fibers may release/acquire concurrently.

   Holder rows are tuples [(label, keeper_name) → acquire_ts].
   [label] disambiguates the three pools (turn / autonomous / reactive)
   without requiring three separate tables.  Cardinality is bounded by
   the deployment's keeper count (typically <50). *)
let holder_table : (string * string, float) Hashtbl.t = Hashtbl.create 32
let holder_mutex = Eio.Mutex.create ()

let with_holder_lock f =
  Eio.Mutex.use_rw ~protect:true holder_mutex f

let record_holder ~label ~keeper_name ~acquired_at =
  with_holder_lock (fun () ->
    Hashtbl.replace holder_table (label, keeper_name) acquired_at)

let drop_holder ~label ~keeper_name =
  with_holder_lock (fun () ->
    Hashtbl.remove holder_table (label, keeper_name))

(** [snapshot_holders ~label ~now] returns [(keeper_name, held_for_sec)]
    pairs for the given [label] sorted by descending hold time.  Used
    by [acquire_bounded] to attribute timeouts to the longest-held
    peer.  Pure read, no mutation. *)
let snapshot_holders ~label ~now =
  with_holder_lock (fun () ->
    Hashtbl.fold
      (fun (l, name) ts acc ->
        if String.equal l label then (name, now -. ts) :: acc else acc)
      holder_table [])
  |> List.sort (fun (_, a) (_, b) -> compare b a)

(* Autonomous turn concurrency. Reactive turns use a separate pool so
   explicit mentions / board events stay responsive even when scheduled
   turns saturate.

   Provider rate limits (and any future cost cap) are enforced per-provider
   downstream; this counter is only a coarse fairness gate between fibers.
   The previous [max_v:16] ceiling was a typo-defence boilerplate, not an
   architectural ceiling, and starved fleets >16 keepers. Removed. *)
let autonomous_turn_limit =
  Keeper_config.int_of_env_default
    "MASC_KEEPER_AUTONOMOUS_CONCURRENCY" ~default:16 ~min_v:1 ~max_v:max_int
;;

let () =
  Log.Keeper.info "autonomous_turn_concurrency=%d (env=%s)"
    autonomous_turn_limit
    (Option.value ~default:"<unset>"
       (Env_config_core.raw_value_opt "MASC_KEEPER_AUTONOMOUS_CONCURRENCY"))

let autonomous_turn_semaphore = Eio.Semaphore.make autonomous_turn_limit

let reactive_turn_limit =
  Keeper_config.int_of_env_default
    "MASC_KEEPER_REACTIVE_CONCURRENCY" ~default:16 ~min_v:1 ~max_v:max_int
;;

let () =
  Log.Keeper.info "reactive_turn_concurrency=%d (env=%s)"
    reactive_turn_limit
    (Option.value ~default:"<unset>"
       (Env_config_core.raw_value_opt "MASC_KEEPER_REACTIVE_CONCURRENCY"))

let reactive_turn_semaphore = Eio.Semaphore.make reactive_turn_limit

let turn_semaphore_value_for_test () =
  Eio.Semaphore.get_value turn_semaphore

let autonomous_turn_semaphore_value_for_test () =
  Eio.Semaphore.get_value autonomous_turn_semaphore

let reactive_turn_semaphore_value_for_test () =
  Eio.Semaphore.get_value reactive_turn_semaphore

type autonomous_waiter =
  {
    ticket : int;
    keeper_name : string;
  }

(* Eio.Mutex: queue operations are pure/non-yielding. Stdlib.Mutex is
   PTHREAD_MUTEX_ERRORCHECK on OCaml 5 and raises "Resource deadlock
   avoided" whenever two Eio fibers on the same OS thread contend, which
   is the default in single-domain Eio_main (memory:
   feedback_eio-mutex-vs-stdlib). Test helpers must run inside Eio_main
   to use this. *)
let autonomous_wait_queue_mutex = Eio.Mutex.create ()

let autonomous_wait_queue : autonomous_waiter list ref = ref []

let autonomous_wait_queue_next_ticket = ref 0

(* Routed through Env_config_keeper so operators can tune cadence
   without a rebuild (same fragmentation class as the watchdog
   thresholds extracted in #10740). The value is read once at
   module load — restart required to pick up env changes. *)
let autonomous_queue_poll_sec =
  Env_config_keeper.KeeperPollIntervals.autonomous_queue_poll_sec

let with_autonomous_wait_queue f =
  Eio.Mutex.use_rw ~protect:true autonomous_wait_queue_mutex f

let autonomous_queue_depth_labels = [ ("channel", "autonomous_queue") ]

let record_autonomous_queue_depth depth =
  Prometheus.set_gauge
    Prometheus.metric_keeper_turn_queue_depth
    ~labels:autonomous_queue_depth_labels
    (float_of_int depth)

let reset_autonomous_turn_queue_for_test () =
  with_autonomous_wait_queue (fun () ->
    autonomous_wait_queue := [];
    autonomous_wait_queue_next_ticket := 0;
    record_autonomous_queue_depth 0)

let enqueue_autonomous_waiter ~(keeper_name : string) : int =
  with_autonomous_wait_queue (fun () ->
    let ticket = !autonomous_wait_queue_next_ticket in
    incr autonomous_wait_queue_next_ticket;
    autonomous_wait_queue :=
      !autonomous_wait_queue @ [{ ticket; keeper_name }];
    record_autonomous_queue_depth (List.length !autonomous_wait_queue);
    ticket)

let drop_autonomous_waiter ~(ticket : int) : unit =
  with_autonomous_wait_queue (fun () ->
    autonomous_wait_queue :=
      List.filter (fun waiter -> waiter.ticket <> ticket) !autonomous_wait_queue;
    record_autonomous_queue_depth (List.length !autonomous_wait_queue))

let autonomous_waiter_snapshot_for_test () : string list =
  with_autonomous_wait_queue (fun () ->
    List.map (fun waiter -> waiter.keeper_name) !autonomous_wait_queue)

let enqueue_autonomous_waiter_for_test keeper_name =
  enqueue_autonomous_waiter ~keeper_name

let drop_autonomous_waiter_for_test ticket =
  drop_autonomous_waiter ~ticket

let autonomous_waiter_head_ticket () : int option =
  with_autonomous_wait_queue (fun () ->
    match !autonomous_wait_queue with
    | head :: _ -> Some head.ticket
    | [] -> None)

let autonomous_waiter_position ~(ticket : int) : int option =
  with_autonomous_wait_queue (fun () ->
    let rec loop idx = function
      | [] -> None
      | waiter :: rest ->
          if waiter.ticket = ticket then Some idx
          else loop (idx + 1) rest
    in
    loop 0 !autonomous_wait_queue)

(** Wall-clock cap on [Eio.Semaphore.acquire] when waiting for a keeper
    turn slot. Without this, a keeper whose peers hold all slots while
    their LLM calls stall for the entire 1200s turn budget would block
    unboundedly, because [Eio.Semaphore.acquire] has no intrinsic timeout.

    Empirical motivation (2026-04-11): [semaphore_wait_ms] of 1.1-2.1 Ms
    observed in keeper decision logs — the sitting keeper waited past its
    own turn budget because peers held slots for the full outer wall-clock.

    Default 180s = enough headroom for a slow LLM turn ahead of a queued
    keeper to finish without forcing a tail-of-queue timeout cascade. The
    previous 60s default was tuned for a 3-keeper fleet and produced the
    245-WARN/30min storm observed at the 14-keeper scale (memory:
    feedback_keeper_starvation_capacity_vs_turn_duration_mismatch).

    Env: [MASC_KEEPER_SEMAPHORE_WAIT_TIMEOUT_SEC]. Default 180. Min 5. *)
let semaphore_wait_timeout_sec =
  Keeper_config.float_of_env_default
    "MASC_KEEPER_SEMAPHORE_WAIT_TIMEOUT_SEC"
    ~default:180.0 ~min_v:5.0 ~max_v:Float.max_float
;;

(** Per-keeper record of the last autonomous turn completion timestamp.
    Used by the fairness cooldown to prevent a fast-cycling keeper from
    monopolizing the autonomous slot when peers are waiting.

    Closes #6810: janitor was observed to complete 9 consecutive ~20s
    turns while cheolsu/sangsu/masc-improver/uranium666 all hit the 60s
    wait timeout. The queue is FIFO-fair in isolation, but a keeper that
    re-enters the queue immediately after releasing the semaphore can
    outpace peers whose heartbeat intervals are longer or whose fibers
    yield less aggressively. *)
let last_autonomous_completion : (string, float) Hashtbl.t = Hashtbl.create 16

(* Eio.Mutex: completion table is accessed from keeper Eio fibers in the
   same domain. The previous "different domains concurrently" comment was
   speculative — every actual caller (record_turn_start path in
   run_keepalive_unified_turn) runs under Eio_main. Stdlib.Mutex's
   PTHREAD_MUTEX_ERRORCHECK semantics turn fiber contention into EDEADLK. *)
let last_autonomous_completion_mutex = Eio.Mutex.create ()

let with_completion_table f =
  Eio.Mutex.use_rw ~protect:true last_autonomous_completion_mutex f

let record_autonomous_completion ~(keeper_name : string) : unit =
  with_completion_table (fun () ->
    Hashtbl.replace last_autonomous_completion keeper_name
      (Time_compat.now ()))

type keeper_turn_slot_state = {
  acquired_autonomous : bool ref;
  acquired_reactive : bool ref;
  acquired_turn : bool ref;
  autonomous_ticket : int option ref;
}

let release_keeper_turn_slot ~keeper_name state =
  Option.iter
    (fun ticket -> drop_autonomous_waiter ~ticket)
    !(state.autonomous_ticket);
  (* Release exactly what we acquired. The turn, autonomous, and reactive
     semaphores account for separate quotas, so release order does not affect
     permit ownership. *)
  if !(state.acquired_turn) then begin
    drop_holder ~label:"turn" ~keeper_name;
    Eio.Semaphore.release turn_semaphore
  end;
  if !(state.acquired_autonomous) then begin
    (* Stamp completion time BEFORE releasing the semaphore so that
       [maybe_yield_for_fairness] can measure the correct interval
       when this keeper's heartbeat loops back immediately. *)
    record_autonomous_completion ~keeper_name;
    drop_holder ~label:"autonomous" ~keeper_name;
    Eio.Semaphore.release autonomous_turn_semaphore
  end;
  if !(state.acquired_reactive) then begin
    drop_holder ~label:"reactive" ~keeper_name;
    Eio.Semaphore.release reactive_turn_semaphore
  end

let reset_autonomous_completion_for_test () : unit =
  with_completion_table (fun () ->
    Hashtbl.reset last_autonomous_completion)

(* PR-M (Leak 9): consecutive [oas_timeout_budget] cycle FAILED strikes
   per keeper.

   [oas_timeout_budget] means the keeper cycle hit its structural budget
   (see [Keeper_unified_turn.resolve_bounded_oas_timeout_budget_with_turn_budget]).
   Re-running on the same fiber gives the same context and the same
   shape of failure repeats — the budget does not magically grow
   between cycles. Pre-fix the only escape was
   [Keeper_supervisor.sweep_and_recover], which only triggers on
   [Keeper_fiber_crash]; with the fiber alive but cycle-failing, the
   sweep reports ["Alive — skip"] (see [keeper_supervisor.ml:599-602])
   and the keeper stays zombie for hours. Real evidence 2026-04-26:
   5 keepers were 4h+ silent post-budget-exhaustion in a 15-minute
   window with 0 restart.

   Promote to [Keeper_fiber_crash] after [oas_timeout_budget_strike_limit]
   consecutive strikes so the supervisor pauses the keeper instead of
   restarting into the same budget loop.

   Counter is in-memory for the common same-server case and is reset on
   any successful turn (see [Ok updated] branch). On first bump after a
   process restart, callers may seed it from the persisted
   [Oas_timeout_budget_loop] failure reason so restart cannot erase a
   partially observed loop. *)
let consecutive_budget_exhaustions : (string, int) Hashtbl.t =
  Hashtbl.create 16
let consecutive_budget_exhaustions_mutex = Eio.Mutex.create ()
let oas_timeout_budget_strike_limit = 3

let with_budget_exhaustions f =
  Eio.Mutex.use_rw ~protect:true consecutive_budget_exhaustions_mutex f

let bump_budget_exhaustion_seeded ~keeper_name ~prior_strikes : int =
  with_budget_exhaustions (fun () ->
    let prior =
      match Hashtbl.find_opt consecutive_budget_exhaustions keeper_name with
      | Some strikes -> strikes
      | None -> max 0 prior_strikes
    in
    let next = prior + 1 in
    Hashtbl.replace consecutive_budget_exhaustions keeper_name next;
    next)

let bump_budget_exhaustion ~keeper_name : int =
  bump_budget_exhaustion_seeded ~keeper_name ~prior_strikes:0

let reset_budget_exhaustion ~keeper_name : unit =
  with_budget_exhaustions (fun () ->
    Hashtbl.remove consecutive_budget_exhaustions keeper_name)

(* Test-only seam so unit tests can pre-load strike counts and exercise
   the promote/reset branches without driving a full keeper cycle. *)
let peek_budget_exhaustion_for_test ~keeper_name : int =
  with_budget_exhaustions (fun () ->
    Hashtbl.find_opt consecutive_budget_exhaustions keeper_name
    |> Option.value ~default:0)

let set_budget_exhaustion_for_test ~keeper_name ~strikes : unit =
  with_budget_exhaustions (fun () ->
    if strikes <= 0 then
      Hashtbl.remove consecutive_budget_exhaustions keeper_name
    else
      Hashtbl.replace consecutive_budget_exhaustions keeper_name strikes)

(** Test-only: stamp a completion time directly without going through
    [Time_compat.now].  Allows deterministic fairness-cooldown scenarios. *)
let record_autonomous_completion_at_for_test ~(keeper_name : string) ~(ts : float) : unit =
  with_completion_table (fun () ->
    Hashtbl.replace last_autonomous_completion keeper_name ts)

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
    ~default:5.0 ~min_v:0.0 ~max_v:60.0

let others_waiting_in_queue ~(keeper_name : string) : bool =
  with_autonomous_wait_queue (fun () ->
    List.exists (fun w -> w.keeper_name <> keeper_name)
      !autonomous_wait_queue)

(** Pure computation: how many seconds [keeper_name] should yield before
    re-entering the queue at time [now].  Returns [0.0] when no yield is
    needed.  Extracted so the delay logic is testable without Eio. *)
let fairness_delay_sec_at ~(now : float) ~(keeper_name : string) : float =
  if autonomous_fairness_cooldown_sec <= 0.0 then 0.0
  else if not (others_waiting_in_queue ~keeper_name) then 0.0
  else
    match
      with_completion_table (fun () ->
        Hashtbl.find_opt last_autonomous_completion keeper_name)
    with
    | None -> 0.0
    | Some last_done ->
      Float.max 0.0 (autonomous_fairness_cooldown_sec -. (now -. last_done))

(** Enforce fairness cooldown before re-entering the autonomous queue.
    If this keeper just completed a turn AND other keepers are waiting,
    yield for the remainder of [autonomous_fairness_cooldown_sec] before
    appending our ticket. Called from [with_keeper_turn_slot] before
    [enqueue_autonomous_waiter]. *)
let maybe_yield_for_fairness ~(keeper_name : string) : unit =
  let remaining = fairness_delay_sec_at ~now:(Time_compat.now ()) ~keeper_name in
  if remaining > 0.0 then begin
    Log.Keeper.info
      "fairness_cooldown: keeper=%s yielding %.2fs (queue has other waiters)"
      keeper_name remaining;
    match Eio_context.get_clock_opt () with
    | Some clock -> Eio.Time.sleep clock remaining
    | None -> Eio.Fiber.yield ()
  end

let rec wait_for_autonomous_queue_head ~(keeper_name : string) ~(ticket : int)
    ~(started_at : float) : (unit, [> `Semaphore_wait_timeout of float ]) result =
  if Option.equal Int.equal (autonomous_waiter_head_ticket ()) (Some ticket)
  then Ok ()
  else
    let waited_sec = Time_compat.now () -. started_at in
    if waited_sec >= semaphore_wait_timeout_sec
    then
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
        "semaphore_wait: autonomous fairness queue wait exceeded %.0fs (keeper=%s ahead=%d), skipping turn"
        semaphore_wait_timeout_sec keeper_name ahead;
      (* #9771: surface the timeout as a fleet-wide metric so
         operators can detect chronic slot starvation without
         scraping the WARN log. *)
      Prometheus.inc_counter
        Prometheus.metric_keeper_semaphore_wait_timeout
        ~labels:[ ("keeper", keeper_name);
                  ("channel", "autonomous_queue_head") ]
        ();
      Error (`Semaphore_wait_timeout semaphore_wait_timeout_sec)
    else (
      (match Eio_context.get_clock_opt () with
       | Some clock -> Eio.Time.sleep clock autonomous_queue_poll_sec
       | None ->
           (* Environment drift: production should always have an Eio clock.
              Yield cooperatively instead of using a blocking Unix sleep so
              the Eio convention guard remains satisfied. *)
           Eio.Fiber.yield ());
      wait_for_autonomous_queue_head ~keeper_name ~ticket ~started_at)

let with_keeper_turn_slot ~keeper_name ~channel f =
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
  let t0 = Time_compat.now () in
  let queue_depth = List.length (autonomous_waiter_snapshot_for_test ()) in
  Log.Keeper.routine "semaphore_acquire: keeper=%s channel=%s autonomous_available=%d turn_available=%d queue_depth=%d"
    keeper_name
    channel_label
    (Eio.Semaphore.get_value autonomous_turn_semaphore)
    (Eio.Semaphore.get_value turn_semaphore)
    queue_depth;
  Prometheus.set_gauge Prometheus.metric_keeper_turn_queue_depth
    ~labels:[("keeper", keeper_name); ("channel", channel_label)]
    (float_of_int queue_depth);
  (* Track acquisitions in mutable flags so the outer Fun.protect can
     release exactly the slots we hold — regardless of which result or
     exception path fires (Eio.Cancel.Cancelled or any other). This
     keeps resource cleanup independent of Eio.Semaphore's internal
     cancel-race handling. *)
  let slot_state =
    {
      acquired_autonomous = ref false;
      acquired_reactive = ref false;
      acquired_turn = ref false;
      autonomous_ticket = ref None;
    }
  in
  let acquire_bounded ~label sem =
    match Eio_context.get_clock_opt () with
    | Some clock ->
      (try
        Eio.Time.with_timeout_exn clock semaphore_wait_timeout_sec (fun () ->
          Eio.Semaphore.acquire sem);
        record_holder ~label ~keeper_name
          ~acquired_at:(Time_compat.now ());
        Ok ()
      with Eio.Time.Timeout ->
        (* Routine, not WARN: the keeper-specific heartbeat loop already
           emits the operator-facing skip warning with owner/cascade
           context, while the metric below preserves attribution.
           2026-05-05: also dump the actual holders so operators are
           not blind to *which* peer is starving the queue. *)
        let holders =
          snapshot_holders ~label ~now:(Time_compat.now ())
        in
        let holder_summary =
          match holders with
          | [] -> "(none — race or empty)"
          | _ ->
            holders
            |> List.map (fun (n, age) -> Printf.sprintf "%s/%.0fs" n age)
            |> String.concat ", "
        in
        Log.Keeper.routine
          "semaphore_wait: %s semaphore wait exceeded %.0fs \
           (channel=%s, holders=[%s]), skipping turn"
          label semaphore_wait_timeout_sec
          channel_label holder_summary;
        (* #9771: per-keeper × per-acquire-channel counter so
           operators can attribute slot starvation to autonomous
           vs turn semaphore pressure. *)
        Prometheus.inc_counter
          Prometheus.metric_keeper_semaphore_wait_timeout
          ~labels:[ ("keeper", keeper_name);
                    ("channel", label) ]
          ();
        Error (`Semaphore_wait_timeout semaphore_wait_timeout_sec))
    | None ->
      (* No Eio clock available: we are running outside an Eio main loop
         (e.g. Alcotest without [Eio_main.run]). Production masc-mcp
         always provides a clock via [Masc_eio_env.init]; reaching this
         branch at runtime would indicate an environment-setup drift,
         so log it prominently before falling back to unbounded acquire. *)
      Log.Keeper.warn
        "semaphore_wait: no Eio clock available — %s acquire will be unbounded (environment drift?)"
        label;
      Eio.Semaphore.acquire sem;
      record_holder ~label ~keeper_name ~acquired_at:(Time_compat.now ());
      Ok ()
  in
  Fun.protect
    ~finally:(fun () -> release_keeper_turn_slot ~keeper_name slot_state)
    (fun () ->
      let autonomous_result =
        if is_autonomous
        then begin
          (* Fairness cooldown: if this keeper recently completed a turn and
             other keepers are waiting, yield before re-entering the FIFO
             queue to give peers a chance to reach head-of-queue first.
             See [maybe_yield_for_fairness] and #6810. *)
          maybe_yield_for_fairness ~keeper_name;
          let ticket = enqueue_autonomous_waiter ~keeper_name in
          slot_state.autonomous_ticket := Some ticket;
          (* Reset the queue-head timeout clock to the moment we joined the
             queue, NOT [t0] (slot-entry). Otherwise [maybe_yield_for_fairness]
             above silently consumes the [semaphore_wait_timeout_sec] budget
             before we even appear in the FIFO, producing the symptom
             "skipping turn (semaphore wait > 60s, peers holding slot,
             autonomous_available=N)" with N>0 because the slot is genuinely
             free but we ran out of budget while sleeping in fairness yield. *)
          let queue_entered_at = Time_compat.now () in
          match
            wait_for_autonomous_queue_head ~keeper_name ~ticket
              ~started_at:queue_entered_at
          with
          | Error _ as e -> e
          | Ok () ->
            match acquire_bounded ~label:"autonomous" autonomous_turn_semaphore with
            | Error _ as e -> e
            | Ok () ->
              slot_state.acquired_autonomous := true;
              drop_autonomous_waiter ~ticket;
              slot_state.autonomous_ticket := None;
              Ok ()
        end
        else Ok ()
      in
      match autonomous_result with
      | Error _ as e -> e
      | Ok () ->
        let reactive_result =
          if is_autonomous then Ok ()
          else
            match acquire_bounded ~label:"reactive" reactive_turn_semaphore with
            | Error _ as e -> e
            | Ok () ->
              slot_state.acquired_reactive := true;
              Ok ()
        in
        match reactive_result with
        | Error _ as e -> e
        | Ok () ->
        match acquire_bounded ~label:"turn" turn_semaphore with
        | Error _ as e -> e
        | Ok () ->
          slot_state.acquired_turn := true;
          let semaphore_wait_ms =
            int_of_float ((Time_compat.now () -. t0) *. 1000.0) in
          Ok (f ~semaphore_wait_ms))
;;

let with_keeper_turn_slot_for_test ~keeper_name ~channel f =
  with_keeper_turn_slot ~keeper_name ~channel f
;;

let wait_for_autonomous_queue_head_for_test ~keeper_name ~ticket ~started_at =
  wait_for_autonomous_queue_head ~keeper_name ~ticket ~started_at
;;
