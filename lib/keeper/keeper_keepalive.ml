(** Keeper_keepalive — keeper heartbeat fiber and board-reactive wakeup.

    Per-keeper lifecycle (start, stop, wakeup) is managed through
    [Keeper_registry] (SSOT).  This module provides the heartbeat loop
    body, board-reactive wakeup filtering, and optional gRPC heartbeat
    fiber.

    [MASC_KEEPER_*] env vars read here (semaphore timeout, concurrency,
    fairness cooldown, autoboot max) can also be set in
    [<resolved config root>/keeper_runtime.toml].
    See {!Keeper_runtime_config} and [docs/BOOT-ENV-STATE-INVENTORY.md]
    section 1.3. *)

open Keeper_types
open Keeper_memory
open Keeper_execution

exception Semaphore_wait_timeout of float

(* #10008 fm3: canonical metric name for proactive-scheduler skip
   reasons.  Labels: [("keeper", <name>); ("reason", <skip_reason>)].
   [reason] is derived from
   [Keeper_world_observation.verdict_reasons_to_strings], which
   produces one of {keeper_paused, approval_pending,
   scheduled_autonomous_disabled, provider_cooldown_pending,
   idle_gate_pending, cooldown_pending, no_signal}. *)
let proactive_skip_reason_metric = "masc_keeper_proactive_skip_total"

let keepalive_interval_sec () =
  Runtime_params.get Governance_registry.keeper_keepalive_interval_sec
;;

(* ── Board-reactive policy constants ── *)

let board_reactive_debounce_sec = Env_config.KeeperKeepalive.board_debounce_sec

(* ── Heartbeat history fallback read limits ── *)
let max_history_read_bytes = 256 * 1024
let max_history_read_lines = 200

let status_tick_usage_json () =
  `Assoc
    [
      ("input_tokens", `Int 0);
      ("output_tokens", `Int 0);
      ("cache_creation_tokens", `Int 0);
      ("cache_read_tokens", `Int 0);
      ("total_tokens", `Int 0);
    ]

(* OAS Event_bus — delegated to Keeper_event_bus to avoid dependency cycles. *)
let set_bus bus = Keeper_event_bus.set bus
let get_bus () = Keeper_event_bus.get ()

let effective_keepalive_meta
    ~base_path
    ~(fallback : keeper_meta)
    ~(disk_meta_opt : keeper_meta option) : keeper_meta =
  match disk_meta_opt with
  | Some latest -> latest
  | None -> (
      match Keeper_registry.get ~base_path fallback.name with
      | Some entry -> entry.meta
      | None -> fallback)

let repair_identity_drift_for_keepalive ~(ctx : _ context) (meta : keeper_meta) :
    keeper_meta option =
  let expected_agent_name = keeper_agent_name meta.name in
  if String.equal expected_agent_name meta.agent_name then
    Some meta
  else
    let previous_trace_id = Keeper_id.Trace_id.to_string meta.runtime.trace_id in
    let new_trace_id_raw = Keeper_identity.generate_trace_id () in
    match Keeper_id.Trace_id.of_string new_trace_id_raw with
    | Error err ->
        Log.Keeper.error
          "keepalive identity repair failed for %s: invalid trace_id %s (%s)"
          meta.name new_trace_id_raw err;
        None
    | Ok new_trace_id ->
        let base_dir = session_base_dir ctx.config in
        let _session =
          Keeper_exec_context.create_session ~session_id:new_trace_id_raw
            ~base_dir
        in
        let repaired =
          {
            meta with
            agent_name = expected_agent_name;
            updated_at = now_iso ();
            runtime =
              {
                meta.runtime with
                trace_id = new_trace_id;
                trace_history =
                  Json_util.dedupe_keep_order
                    (previous_trace_id :: meta.runtime.trace_history);
                generation = meta.runtime.generation + 1;
              };
          }
        in
        (match write_meta ~force:true ctx.config repaired with
         | Ok () ->
             Log.Keeper.warn
               "keepalive repaired identity drift for %s: %s -> %s"
               meta.name meta.agent_name expected_agent_name;
             Some repaired
         | Error err ->
             Prometheus.inc_counter
               Prometheus.metric_keeper_write_meta_failures
               ~labels:[ ("keeper", meta.name); ("phase", "identity_repair") ]
               ();
             Log.Keeper.error
               "keepalive identity repair failed for %s: write_meta failed: %s"
               meta.name err;
             None)

(* Global turn slot cap. Safety ceiling for ALL keeper turns (autonomous
   + reactive). Default 12 = headroom for up to 12 keepers. *)
let keeper_turn_throttle_limit =
  Keeper_config.int_of_env_default
    "MASC_KEEPER_AUTOBOOT_MAX" ~default:12 ~min_v:1 ~max_v:20
;;

let turn_semaphore = Eio.Semaphore.make keeper_turn_throttle_limit

(* Autonomous turn concurrency cap. Prevents thundering-herd when all
   keepers fire scheduled turns simultaneously on a shared LLM server.
   Reactive turns (explicit mentions, board events) bypass this gate
   so they are never starved by slow autonomous turns.
   Default 3 = a conservative parallelism level for shared remote providers.
   Lower to 1 for single-slot local servers. For 8-slot servers,
   MASC_KEEPER_AUTONOMOUS_CONCURRENCY=3-4 is a reasonable range. *)
let autonomous_turn_limit =
  Keeper_config.int_of_env_default
    "MASC_KEEPER_AUTONOMOUS_CONCURRENCY" ~default:3 ~min_v:1 ~max_v:8
;;

let () =
  Log.Keeper.info "autonomous_turn_concurrency=%d (env=%s)"
    autonomous_turn_limit
    (Option.value ~default:"<unset>"
       (Env_config_core.raw_value_opt "MASC_KEEPER_AUTONOMOUS_CONCURRENCY"))

let autonomous_turn_semaphore = Eio.Semaphore.make autonomous_turn_limit

let turn_semaphore_value_for_test () =
  Eio.Semaphore.get_value turn_semaphore

let autonomous_turn_semaphore_value_for_test () =
  Eio.Semaphore.get_value autonomous_turn_semaphore

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

let autonomous_queue_poll_sec = 0.05

let with_autonomous_wait_queue f =
  Eio.Mutex.use_rw ~protect:true autonomous_wait_queue_mutex f

let reset_autonomous_turn_queue_for_test () =
  with_autonomous_wait_queue (fun () ->
    autonomous_wait_queue := [];
    autonomous_wait_queue_next_ticket := 0)

let enqueue_autonomous_waiter ~(keeper_name : string) : int =
  with_autonomous_wait_queue (fun () ->
    let ticket = !autonomous_wait_queue_next_ticket in
    incr autonomous_wait_queue_next_ticket;
    autonomous_wait_queue :=
      !autonomous_wait_queue @ [{ ticket; keeper_name }];
    ticket)

let drop_autonomous_waiter ~(ticket : int) : unit =
  with_autonomous_wait_queue (fun () ->
    autonomous_wait_queue :=
      List.filter (fun waiter -> waiter.ticket <> ticket) !autonomous_wait_queue)

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

    Default 60s = short enough that keepers fail fast and fall back to the
    next heartbeat cycle (giving real slot holders time to release), long
    enough that legitimate turn contention (3+ concurrent keepers on a
    fast provider) does not mis-trigger.

    Env: [MASC_KEEPER_SEMAPHORE_WAIT_TIMEOUT_SEC]. Default 60. Range [5, 600]. *)
let semaphore_wait_timeout_sec =
  Keeper_config.float_of_env_default
    "MASC_KEEPER_SEMAPHORE_WAIT_TIMEOUT_SEC"
    ~default:60.0 ~min_v:5.0 ~max_v:600.0
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
  acquired_turn : bool ref;
  autonomous_ticket : int option ref;
}

let release_keeper_turn_slot ~keeper_name state =
  Option.iter
    (fun ticket -> drop_autonomous_waiter ~ticket)
    !(state.autonomous_ticket);
  (* Release exactly what we acquired. Order does not matter because
     these two semaphores do not contend with each other. *)
  if !(state.acquired_turn) then Eio.Semaphore.release turn_semaphore;
  if !(state.acquired_autonomous) then begin
    (* Stamp completion time BEFORE releasing the semaphore so that
       [maybe_yield_for_fairness] can measure the correct interval
       when this keeper's heartbeat loops back immediately. *)
    record_autonomous_completion ~keeper_name;
    Eio.Semaphore.release autonomous_turn_semaphore
  end

let reset_autonomous_completion_for_test () : unit =
  with_completion_table (fun () ->
    Hashtbl.reset last_autonomous_completion)

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
  Log.Keeper.debug "semaphore_acquire: keeper=%s channel=%s autonomous_available=%d turn_available=%d queue_depth=%d"
    keeper_name
    channel_label
    (Eio.Semaphore.get_value autonomous_turn_semaphore)
    (Eio.Semaphore.get_value turn_semaphore)
    queue_depth;
  (* Track acquisitions in mutable flags so the outer Fun.protect can
     release exactly the slots we hold — regardless of which result or
     exception path fires (Eio.Cancel.Cancelled or any other). This
     keeps resource cleanup independent of Eio.Semaphore's internal
     cancel-race handling. *)
  let slot_state =
    {
      acquired_autonomous = ref false;
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
        Ok ()
      with Eio.Time.Timeout ->
        (* INFO not WARN: see commentary above — keeper skips this turn
           and the next heartbeat re-queues it. Per-event noise hurts
           operator signal more than it helps. *)
        Log.Keeper.info
          "semaphore_wait: %s semaphore wait exceeded %.0fs (channel=%s), \
           skipping turn"
          label semaphore_wait_timeout_sec
          channel_label;
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
          match wait_for_autonomous_queue_head ~keeper_name ~ticket ~started_at:t0 with
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

(** Optional gRPC client + env — WORM Atomic: set at server bootstrap
    when [MASC_AGENT_TRANSPORT=grpc]. *)
let grpc_client_ref : Masc_grpc_client.t option Atomic.t = Atomic.make None

let grpc_env_ref : Eio_unix.Stdenv.base option Atomic.t = Atomic.make None

let set_grpc_client ?(env : Eio_unix.Stdenv.base option) c =
  Atomic.set grpc_client_ref (Some c);
  Atomic.set grpc_env_ref env
;;

(* Skip log throttle removed with manual_reconcile blocker — no more
   sticky reconcile state means no flood of "reconcile pending" skip logs. *)

let format_since_last_scheduled_autonomous = function
  | Some s when s = max_int -> "never"
  | Some s -> string_of_int s
  | None -> "-"

(** Sleep in short chunks so [stop_keepalive] or [wakeup_keeper] takes
    effect within ~chunk_sec instead of waiting for the full interval. *)
let interruptible_sleep ~clock ~stop ~wakeup duration =
  let chunk_sec = Env_config.KeeperKeepalive.sleep_chunk_sec in
  let rec wait remaining =
    if Atomic.get stop
    then ()
    else if Atomic.compare_and_set wakeup true false
    then ()
    else if remaining <= 0.0
    then ()
    else (
      let chunk = Float.min chunk_sec remaining in
      Eio.Time.sleep clock chunk;
      wait (remaining -. chunk))
  in
  wait duration
;;

(** Wake up a specific keeper immediately, causing it to skip the rest of
    its sleep and run the next heartbeat cycle. Used by broadcast notification
    when a @mention targets a running keeper. *)
let wakeup_keeper ?base_path name =
  Keeper_registry.all ?base_path ()
  |> List.iter (fun (entry : Keeper_registry.registry_entry) ->
    if String.equal entry.name name && entry.phase = Keeper_state_machine.Running
    then Keeper_registry.wakeup ~base_path:entry.base_path name)
;;

(** Wake up all running keepers — used when a broadcast mentions @@all
    or when a system-wide event requires immediate attention.
    [None] preserves the legacy global wakeup behavior. *)
let wakeup_all_keepers ?base_path () =
  match base_path with
  | None -> Keeper_registry.wakeup_all ()
  | Some expected ->
      Keeper_registry.all ~base_path:expected ()
      |> List.iter (fun (entry : Keeper_registry.registry_entry) ->
           if entry.phase = Keeper_state_machine.Running then
             Keeper_registry.wakeup ~base_path:entry.base_path entry.name)

let board_reactive_wakeup_allowed ~base_path ~keeper_name ~post_id =
  Keeper_registry.board_wakeup_allowed
    ~base_path
    keeper_name
    ~post_id
    ~debounce_sec:board_reactive_debounce_sec
;;

let wakeup_relevant_keeper_for_board_signal
      ~(config : Coord.config)
      (signal : Board_dispatch.keeper_board_signal)
  =
  let running_names =
    Keeper_registry.all ~base_path:config.base_path ()
    |> List.filter_map (fun (e : Keeper_registry.registry_entry) ->
      if e.phase = Keeper_state_machine.Running then Some e.name else None)
  in
  let candidates =
    running_names
    |> List.filter_map (fun name ->
      match read_meta config name with
      | Ok (Some meta) ->
        let wake_reason =
          Keeper_world_observation.board_signal_wake_reason
            ~continuity_summary:meta.continuity_summary
            ~meta
            ~signal
        in
        Some (meta, wake_reason)
      | _ -> None)
  in
  let explicit =
    candidates
    |> List.filter
         (fun (_meta, wake_reason) -> wake_reason = Some "explicit_mention")
  in
  let wake_meta (meta : keeper_meta) reason =
    if
      board_reactive_wakeup_allowed
        ~base_path:config.base_path
        ~keeper_name:meta.name
        ~post_id:signal.post_id
    then (
      wakeup_keeper ~base_path:config.base_path meta.name;
      Log.Keeper.info
        "board signal wakeup: keeper=%s reason=%s post=%s"
        meta.name
        reason
        signal.post_id)
  in
  match explicit with
  | _ :: _ ->
    explicit |> List.iter (fun (meta, _wake_reason) -> wake_meta meta "explicit_mention")
  | [] ->
    candidates
    |> List.iter (fun (meta, wake_reason) ->
         match wake_reason with
         | Some reason -> wake_meta meta reason
         | None -> ())
;;

let max_consecutive_heartbeat_failures () =
  Runtime_params.get Governance_registry.keeper_max_hb_failures
;;

let max_consecutive_turn_failures () =
  Runtime_params.get Governance_registry.keeper_max_turn_failures
;;

(* Per-stage timing accumulator for Phase 0 profiling.
   In-memory ring of last 100 cycles. Flushed as aggregate at snapshot cadence.
   No additional file I/O — appended to existing snapshot JSON. *)
type stage_timing =
  { presence_ms : float
  ; snapshot_ms : float
  ; board_ms : float
  ; turn_ms : float
  ; recurring_ms : float
  }

let stage_timing_ring_size () =
  Runtime_params.get Governance_registry.keeper_stage_timing_ring_size
;;

let percentile arr p =
  let n = Array.length arr in
  if n = 0
  then 0.0
  else (
    let sorted = Array.copy arr in
    Array.sort Float.compare sorted;
    let idx = Float.to_int (Float.round (float_of_int (n - 1) *. p)) in
    sorted.(min idx (n - 1)))
;;

let stage_timing_to_json ~ring ~count =
  let n = min count (Array.length ring) in
  if n = 0
  then `Null
  else (
    let extract field =
      let arr = Array.init n (fun i -> field ring.(i)) in
      `Assoc
        [ "p50", `Float (percentile arr 0.5)
        ; "p95", `Float (percentile arr 0.95)
        ; "max", `Float (percentile arr 1.0)
        ; "samples", `Int n
        ]
    in
    `Assoc
      [ "presence", extract (fun t -> t.presence_ms)
      ; "snapshot", extract (fun t -> t.snapshot_ms)
      ; "board", extract (fun t -> t.board_ms)
      ; "turn", extract (fun t -> t.turn_ms)
      ; "recurring", extract (fun t -> t.recurring_ms)
      ])
;;

let keepalive_entry_accepts_late_event ~(ctx : _ context) ~(keeper_name : string) =
  match Keeper_registry.get_phase ~base_path:ctx.config.base_path keeper_name with
  | None -> true
  | Some (Keeper_state_machine.Stopped | Keeper_state_machine.Dead) -> false
  | Some _ -> true

let dispatch_keepalive_event ~(ctx : _ context) ~(keeper_name : string) event =
  if keepalive_entry_accepts_late_event ~ctx ~keeper_name then
    ignore (Keeper_registry.dispatch_event
      ~base_path:ctx.config.base_path keeper_name event)

let dispatch_keepalive_event_with_audit
      ~(ctx : _ context)
      ~(keeper_name : string)
      ~snapshot
      ~events_fired
      ~selected_event
      event
  =
  if keepalive_entry_accepts_late_event ~ctx ~keeper_name then
    ignore (Keeper_registry.dispatch_event_with_audit
      ~base_path:ctx.config.base_path
      ~snapshot
      ~events_fired
      ~selected_event
      keeper_name
      event)

let write_heartbeat_snapshot
      ~(ctx : _ context)
      ~(meta_current : keeper_meta)
      ~(now_ts : float)
      ~(consecutive_hb_failures : int)
      ~(timing_ring : stage_timing array)
      ~(timing_filled : int)
  : unit
  =
  let metrics_store = keeper_metrics_store ctx.config meta_current.name in
  let cascade_models =
    Cascade_runtime.models_of_cascade_name meta_current.cascade_name
  in
  let max_cascade_context =
    let resolution =
      Keeper_exec_context.resolve_max_context_resolution
        ~requested_override:meta_current.max_context_override
        cascade_models
    in
    resolution.effective_budget
  in
  let base_dir = session_base_dir ctx.config in
  ignore (Keeper_fs.ensure_dir (Filename.concat base_dir (Keeper_id.Trace_id.to_string meta_current.runtime.trace_id)));
  let _session, ctx_opt =
    load_context_from_checkpoint
      ~max_checkpoint_messages:meta_current.compaction.max_checkpoint_messages
      ~trace_id:(Keeper_id.Trace_id.to_string meta_current.runtime.trace_id)
      ~primary_model_max_tokens:max_cascade_context
      ~base_dir
  in
  (* Fallback: when OAS checkpoint is absent (e.g. after server restart
     mid-turn), load messages from history.jsonl to recover continuity.
     This prevents the "orphan user" problem where interrupted turns
     leave user-only entries and continuity_summary stays empty forever.
     Read is bounded to avoid large allocations during heartbeats. *)
  let messages_for_continuity = match ctx_opt with
    | Some c -> Keeper_exec_context.messages_of_context c
    | None ->
      let history_path =
        Keeper_types.keeper_history_path ctx.config
          (Keeper_id.Trace_id.to_string meta_current.runtime.trace_id)
      in
      let internal_history_path =
        Keeper_types.keeper_internal_history_path ctx.config
          (Keeper_id.Trace_id.to_string meta_current.runtime.trace_id)
      in
      (let parse_errors = ref 0 in
       let messages =
         try
           [ history_path; internal_history_path ]
           |> List.concat_map (fun path ->
                read_file_tail_lines path
                  ~max_bytes:max_history_read_bytes
                  ~max_lines:max_history_read_lines)
           |> List.filter_map (fun line ->
             try
               let json = Yojson.Safe.from_string line in
               let source =
                 Safe_ops.json_string ~default:"" "source" json |> String.trim
               in
               let content =
                 Safe_ops.json_string ~default:"" "content" json |> String.trim
               in
               if Keeper_types.is_prompt_history_source source
                  || Keeper_context_core.has_world_state_signature content
               then None
               else Some (Keeper_context_core.message_of_json json)
             with
             | Eio.Cancel.Cancelled _ as e -> raise e
             | _exn ->
               incr parse_errors;
               None)
         with
         | Eio.Cancel.Cancelled _ as e -> raise e
         | exn ->
           Log.Keeper.warn "write_heartbeat_snapshot: history.jsonl load error (%s): %s"
             meta_current.name (Printexc.to_string exn);
           []
       in
       if !parse_errors > 0 then
         Log.Keeper.warn
           "write_heartbeat_snapshot: failed to parse %d message(s) from history logs for keeper=%s trace_id=%s path=%s"
           !parse_errors meta_current.name
           (Keeper_id.Trace_id.to_string meta_current.runtime.trace_id)
           history_path;
       messages)
  in
  let c_messages = messages_for_continuity in
  let latest_user_message =
    latest_message_content_by_role ~role:Oas.Types.User c_messages
  in
  let latest_assistant_message =
    latest_message_content_by_role ~role:Oas.Types.Assistant c_messages
    in
    let continuity_snapshot = latest_state_snapshot_from_messages c_messages in
    let continuity_summary =
      match continuity_snapshot with
      | Some s -> keeper_state_snapshot_to_summary_text s
      | None ->
        continuity_fallback_summary_text
          ~continuity_summary:meta_current.continuity_summary
          ~last_continuity_update_ts:meta_current.runtime.last_continuity_update_ts
    in
    let repetition_risk =
      repetition_risk_score ~messages:c_messages ~candidate_reply:None
    in
    let goal_alignment =
      goal_alignment_score
        ~meta:meta_current
        ~user_message:latest_user_message
        ~assistant_reply:latest_assistant_message
    in
    let response_alignment =
      match latest_user_message, latest_assistant_message with
      | Some user_message, Some assistant_message ->
        jaccard_similarity user_message assistant_message
      | _ ->
        (* Unmeasurable (status_tick, heartbeat, empty reply): use the
           sentinel [1.0] so the plan gate [<= 0.100] and guardrail gate
           [<= floor] do NOT fire. [0.0] was a permissive default that
           conflated "no alignment measurable" with "no alignment at
           all", triggering auto_plan on every status_tick (#10012).
           CLAUDE.md anti-pattern #2: Unknown → Permissive Default. *)
        1.0
    in
    (* status_tick / heartbeat turns lack a user/assistant pair, so the 0.0
       fallbacks above are sentinels, not measurements. Mark the snapshot
       non-measurable and let Keeper_guard fail-closed on similarity gates. *)
    let similarity_measurable =
      Option.is_some latest_user_message
      && Option.is_some latest_assistant_message
    in
    let context_ratio_v = match ctx_opt with
      | Some c -> Keeper_exec_context.context_ratio c
      | None -> 0.0
    in
    let message_count_v = match ctx_opt with
      | Some c -> Keeper_exec_context.message_count c
      | None -> List.length c_messages
    in
    let token_count_v = match ctx_opt with
      | Some c -> Keeper_exec_context.token_count c
      | None -> 0
    in
    let turn_fail_count =
      Keeper_registry.get_turn_failures
        ~base_path:ctx.config.base_path
        meta_current.name
    in
    let since_last_compaction_sec =
      if meta_current.runtime.compaction_rt.last_ts <= 0.0
      then now_ts
      else max 0.0 (now_ts -. meta_current.runtime.compaction_rt.last_ts)
    in
    let since_last_handoff_sec =
      if meta_current.runtime.last_handoff_ts <= 0.0
      then now_ts
      else max 0.0 (now_ts -. meta_current.runtime.last_handoff_ts)
    in
    (* RFC-0002: build measurement_snapshot via pure capture function.
       Timing/failure inputs now come from the live keepalive loop and
       registry so audit reflects the real runtime decision surface. *)
    let thresholds : Keeper_measurement.threshold_params =
      { compaction_ratio_gate = meta_current.compaction.ratio_gate
      ; compaction_message_gate = meta_current.compaction.message_gate
      ; compaction_token_gate = meta_current.compaction.token_gate
      ; compaction_cooldown_sec = meta_current.compaction.cooldown_sec
      ; handoff_threshold = meta_current.handoff_threshold
      ; handoff_cooldown_sec = meta_current.handoff_cooldown_sec
      ; auto_handoff_enabled = meta_current.auto_handoff
      ; reflect_repetition_threshold =
          Keeper_config.keeper_rule_reflect_repetition_threshold ()
      ; plan_goal_alignment_threshold =
          Keeper_config.keeper_rule_plan_goal_alignment_threshold ()
      ; plan_response_alignment_threshold =
          Keeper_config.keeper_rule_plan_response_alignment_threshold ()
      ; guardrail_repetition_threshold =
          Keeper_config.keeper_rule_guardrail_repetition_threshold ()
      ; guardrail_goal_alignment_threshold =
          Keeper_config.keeper_rule_guardrail_goal_alignment_threshold ()
      ; guardrail_response_alignment_threshold =
          Keeper_config.keeper_rule_guardrail_response_alignment_threshold ()
      ; guardrail_context_threshold =
          Keeper_config.keeper_rule_guardrail_context_threshold ()
      ; max_consecutive_hb_failures = max_consecutive_heartbeat_failures ()
      ; max_consecutive_turn_failures = max_consecutive_turn_failures ()
      ; model_ratio_multiplier = 1.0
      ; model_handoff_multiplier = 1.0
      }
    in
    let measurement =
      Keeper_measurement.capture
        ~snapshot_id:
          (Printf.sprintf "msnap-%s-%Ld"
             meta_current.name
             (Int64.of_float (now_ts *. 1000.0)))
        ~keeper_name:meta_current.name
        ~generation:meta_current.runtime.generation
        ~timestamp:now_ts
        ~thresholds
        ~context_ratio:context_ratio_v
        ~message_count:message_count_v
        ~token_count:token_count_v
        ~max_tokens:
          (match ctx_opt with
           | Some c -> Keeper_context_core.max_tokens_of_context c
           | None -> max_cascade_context)
        ~repetition_risk
        ~goal_alignment
        ~response_alignment
        ~similarity_measurable
        ~now_ts
        ~idle_seconds:0
        ~since_last_compaction_sec
        ~since_last_handoff_sec
        ~proactive_warmup_elapsed:false
        ~consecutive_hb_failures
        ~consecutive_turn_failures:turn_fail_count
        ()
    in
    let guard_events = Keeper_guard.evaluate measurement in
    let auto_rules =
      keeper_auto_rule_eval_of_measurement ~events:guard_events measurement
    in
    let selected_guard_event = Keeper_guard.prioritized_event guard_events in
    (* RFC-0002: dispatch Context_measured event through state machine *)
    let () =
      dispatch_keepalive_event_with_audit
        ~ctx
        ~keeper_name:meta_current.name
        ~snapshot:measurement
        ~events_fired:guard_events
        ~selected_event:selected_guard_event
        (Keeper_state_machine.Context_measured {
          context_ratio = context_ratio_v;
          message_count = message_count_v;
          token_count = token_count_v;
          auto_rules = {
            Keeper_state_machine.reflect = auto_rules.reflect;
            plan = auto_rules.plan;
            compact = auto_rules.compact;
            handoff = auto_rules.handoff;
            guardrail_stop = auto_rules.guardrail_stop;
            guardrail_reason = auto_rules.guardrail_reason;
            goal_drift = auto_rules.goal_drift;
          };
        })
    in
    (* B1: Guard → Thompson bridge. When guardrail fires, record a negative
       signal in Thompson β. Penalty cap 1/cycle is naturally enforced: guard
       evaluates once per heartbeat call. Gated by MASC_DECISION_LAYER_LEVEL >= 2. *)
    if auto_rules.guardrail_stop
       && Keeper_decision_audit.decision_layer_level () >= 2
    then
      (try Thompson_sampling.record_guard_penalty ~agent_name:meta_current.name
       with
       | Eio.Cancel.Cancelled _ as e -> raise e
       | exn ->
         Log.Keeper.warn "guard→thompson penalty failed for %s: %s"
           meta_current.name (Printexc.to_string exn));
    let snapshot =
      `Assoc
        [ "ts", `String (now_iso ())
        ; "ts_unix", `Float now_ts
        ; "channel", `String "heartbeat"
        ; "name", `String meta_current.name
        ; "agent_name", `String meta_current.agent_name
        ; "trace_id", `String (Keeper_id.Trace_id.to_string meta_current.runtime.trace_id)
        ; "generation", `Int meta_current.runtime.generation
        ; (* #10018 follow-up: [model_used] is also snapshot-stale.
             last_model_used is the *previous turn's* provider label;
             emitting it on every heartbeat made
             per-provider latency histograms and dashboards show
             ghost provider names long after the binary that wrote
             them was rebuilt (observed qa-king / nick0cave stuck on
             "deterministic_required_tool_fallback" across
             post-#9967 rebuild).  Emit empty string here so
             downstream per-provider aggregation ignores heartbeat
             records.  `last_model_used_label` on the keeper state
             JSON still reflects the last real turn for dashboard
             snapshot panels. *)
          "model_used", `String ""
        ; (* #10018: status_tick is a snapshot, not an LLM-call event.
             Emitting [runtime.usage.last_*_tokens] and [last_latency_ms]
             caused the last turn's per-turn values to be repeat-emitted
             on every heartbeat — observed analyst heartbeats 5 min
             apart both reported [input=273325, output=8067,
             total=281392, latency_ms=191894] while no LLM call ran.
             Downstream daily token aggregates and p50 latency were
             inflated by ~heartbeat-count per turn. Same "snapshot vs
             event" boundary fix as #9950 for compaction fields.
             [total_cost_usd] is a running total and remains emitted. *)
          "usage", status_tick_usage_json ()
        ; "latency_ms", `Int 0
        ; "cost_usd", `Float meta_current.runtime.usage.total_cost_usd
        ; "context_ratio", `Float context_ratio_v
        ; "context_tokens", `Int token_count_v
        ; "context_max",
          `Int
            (match ctx_opt with
             | Some c -> Keeper_context_core.max_tokens_of_context c
             | None -> max_cascade_context)
        ; "message_count", `Int message_count_v
        ; ( "continuity_state"
          , match continuity_snapshot with
            | None -> `Null
            | Some s -> keeper_state_snapshot_to_json s )
        ; "continuity_summary", `String continuity_summary
        ; "compacted", `Bool false
        ; (* #9943: status_tick is a snapshot, not a compaction
             event. Emitting [before = after = token_count_v]
             caused 956/972 (98.4%) of daily metric entries to
             look like compaction attempts with zero savings —
             a false signal that drowned actual compactions.
             Zero marks the record as "not a compaction event";
             the dashboard already skips records with
             compacted=false, but analysts running ad-hoc jq over
             the ledger no longer mistake status_tick for a
             failed compaction. *)
          "compaction_before_tokens", `Int 0
        ; "compaction_after_tokens", `Int 0
        ; "work_kind", `String "status_tick"
        ; "tool_call_count", `Int 0
        ; "tools_used", `List []
        ; "snapshot_source", `String "keeper_context_status"
        ; "memory_check", memory_check_default_json ()
        ; "auto_rules", keeper_auto_rule_eval_to_json auto_rules
        ; "reflection", keeper_reflection_payload_of_auto_rules auto_rules
        ; "auto_reflect", `Bool auto_rules.reflect
        ; "auto_plan", `Bool auto_rules.plan
        ; "auto_compact", `Bool auto_rules.compact
        ; "auto_handoff", `Bool auto_rules.handoff
        ; "repetition_risk", `Float repetition_risk
        ; "goal_alignment", `Float goal_alignment
        ; "response_alignment", `Float response_alignment
        ; "goal_drift", `Float auto_rules.goal_drift
        ; "guardrail_stop", `Bool auto_rules.guardrail_stop
        ; ( "guardrail_stop_reason"
          , match auto_rules.guardrail_reason with
            | Some reason -> `String reason
            | None -> `Null )
        ; "handoff", `Assoc [ "performed", `Bool false ]
        ; "stage_timing", stage_timing_to_json ~ring:timing_ring ~count:timing_filled
        ]
    in
    Dated_jsonl.append metrics_store snapshot;
    (try
       Sse.broadcast
         (`Assoc
             [ "type", `String "keeper_heartbeat"
             ; "name", `String meta_current.name
             ; "generation", `Int meta_current.runtime.generation
             ; "context_ratio", `Float context_ratio_v
             ; "ts_unix", `Float now_ts
             ])
     with
     | Eio.Cancel.Cancelled _ as e -> raise e
     | exn ->
       Log.Keeper.error "heartbeat SSE broadcast failed: %s" (Printexc.to_string exn));
    (match Keeper_event_bus.get () with
     | Some bus ->
       Oas_events.publish_keeper_snapshot
         bus
         ~keeper_name:meta_current.name
         ~generation:meta_current.runtime.generation
         ~context_ratio:context_ratio_v
         ~message_count:message_count_v
     | None -> ());
    (try
       Keeper_registry.flush_tool_usage ~base_path:ctx.config.base_path meta_current.name
     with
     | Eio.Cancel.Cancelled _ as e -> raise e
     | exn ->
       Log.Keeper.warn "keeper:%s flush_tool_usage failed: %s"
         meta_current.name (Printexc.to_string exn))
;;

let keeper_agent_status (meta : keeper_meta) =
  if meta.paused
  then Types.Inactive
  else (
    match meta.current_task_id with
    | Some _ -> Types.Busy
    | None -> Types.Active)
;;

(** Reset stale turn failures so the keeper can exit Failing phase.
    Called unconditionally after presence sync (whether I/O was skipped or not).
    If the underlying issue persists, the next turn will re-fail.
    Manual reconcile blocker logic removed — see plan:
    enchanted-strolling-bonbon. *)
let maybe_recover_from_failing ~(ctx : _ context) ~(meta : keeper_meta) =
  let stale_turn_failures =
    Keeper_registry.get_turn_failures
      ~base_path:ctx.config.base_path meta.name
  in
  if stale_turn_failures > 0 then begin
    Keeper_registry.reset_turn_failures
      ~base_path:ctx.config.base_path meta.name;
    ignore (Keeper_registry.dispatch_event
      ~base_path:ctx.config.base_path meta.name
      Keeper_state_machine.Heartbeat_ok);
    dispatch_keepalive_event ~ctx ~keeper_name:meta.name
      Keeper_state_machine.Turn_succeeded;
    Log.Keeper.info
      "heartbeat recovery: reset %d stale turn failures for %s"
      stale_turn_failures meta.name
  end

let sync_keeper_presence
      ~(ctx : _ context)
      ~(meta_current : keeper_meta)
      ~(t_presence_start : float)
      ~(consecutive_failures : int ref)
      ~(last_successful_heartbeat_ts : float ref)
      ~(work_as_hb : unit -> bool)
      ~(max_silence : unit -> float)
  : keeper_meta
  =
  let presence_fresh =
    work_as_hb () && t_presence_start -. !last_successful_heartbeat_ts < max_silence ()
  in
  if presence_fresh
  then (
    Log.Keeper.debug
      "presence sync skipped: fresh heartbeat %.0fs ago"
      (t_presence_start -. !last_successful_heartbeat_ts);
    maybe_recover_from_failing ~ctx ~meta:meta_current;
    meta_current)
  else (
    try
      let synced = ensure_keeper_room_presence ctx.config meta_current in
      if synced.joined_room_ids = []
      then (
        incr consecutive_failures;
        (* RFC-0001 Gate A: record failure streak *)
        Agent_stress.record {
          agent_name = meta_current.name;
          room_id = (match meta_current.joined_room_ids with r :: _ -> r | [] -> "");
          kind = Failure_streak !consecutive_failures;
          timestamp = Unix.gettimeofday ();
        };
        Log.Keeper.warn
          "room presence returned empty rooms (%d/%d)"
          !consecutive_failures
          (max_consecutive_heartbeat_failures ());
        (* RFC-0002: dispatch heartbeat failure *)
        Prometheus.inc_counter Prometheus.metric_keeper_heartbeat_failures
          ~labels:[("keeper", meta_current.name)] ();
        ignore (Keeper_registry.dispatch_event
          ~base_path:ctx.config.base_path meta_current.name
          (Keeper_state_machine.Heartbeat_failed {
            consecutive = !consecutive_failures;
            max_allowed = max_consecutive_heartbeat_failures ();
          })))
      else (
        consecutive_failures := 0;
        last_successful_heartbeat_ts := Time_compat.now ();
        (* RFC-0002: dispatch heartbeat success *)
        ignore (Keeper_registry.dispatch_event
          ~base_path:ctx.config.base_path meta_current.name
          Keeper_state_machine.Heartbeat_ok);
        Prometheus.inc_counter Prometheus.metric_keeper_heartbeat_successes
          ~labels:[("keeper", meta_current.name)] ();
        maybe_recover_from_failing ~ctx ~meta:meta_current);
      match write_meta ctx.config synced with
      | Ok () -> synced
      | Error e ->
        Prometheus.inc_counter Prometheus.metric_keeper_write_meta_failures
          ~labels:[("keeper", synced.name); ("phase", "heartbeat")] ();
        Log.Keeper.warn "write_meta failed (heartbeat): %s" e;
        synced
    with
    | Eio.Cancel.Cancelled _ as e -> raise e
    | exn ->
      incr consecutive_failures;
      Log.Keeper.error
        "room heartbeat failed (%d/%d): %s"
        !consecutive_failures
        (max_consecutive_heartbeat_failures ())
        (Printexc.to_string exn);
      (* RFC-0002: dispatch heartbeat failure *)
      ignore (Keeper_registry.dispatch_event
        ~base_path:ctx.config.base_path meta_current.name
        (Keeper_state_machine.Heartbeat_failed {
          consecutive = !consecutive_failures;
          max_allowed = max_consecutive_heartbeat_failures ();
        }));
      meta_current)
;;

let collect_keepalive_board_events
      ~(ctx : _ context)
      ~(meta_current : keeper_meta)
      ~(proactive_warmup_elapsed : bool)
  =
  if not proactive_warmup_elapsed
  then [], meta_current
  else (
    let pending_board_events =
      try
        let events, _new_count, _mention_count =
          Keeper_world_observation.collect_board_events
            ~base_path:ctx.config.base_path
            ~meta:meta_current
            ~continuity_summary:meta_current.continuity_summary
        in
        events
      with
      | Eio.Cancel.Cancelled _ as e -> raise e
      | exn ->
        Log.Keeper.warn "keepalive: board count query failed: %s" (Printexc.to_string exn);
        []
    in
    pending_board_events, meta_current)
;;

let in_turn_liveness_pulse_interval_sec () =
  max 5.0 (min 30.0 (float_of_int (keepalive_interval_sec ())))
;;

let with_in_turn_liveness_pulse_for_test ~sw:_sw ~clock ~interval_sec ~tick f =
  let interval_sec = max 0.001 interval_sec in
  Eio.Switch.run (fun pulse_sw ->
    let pulse_stop = Atomic.make false in
    Eio.Switch.on_release pulse_sw (fun () -> Atomic.set pulse_stop true);
    Eio.Fiber.fork ~sw:pulse_sw (fun () ->
      let rec loop () =
        Eio.Time.sleep clock interval_sec;
        if not (Atomic.get pulse_stop) then (
          (try tick ()
           with
           | Eio.Cancel.Cancelled _ as e -> raise e
           | exn ->
               Log.Keeper.warn "in-turn liveness pulse failed: %s"
                 (Printexc.to_string exn));
          loop ())
      in
      loop ());
    f ())
;;

let emit_in_turn_liveness_pulse ~(ctx : _ context) ~(meta : keeper_meta) =
  match Keeper_registry.get ~base_path:ctx.config.base_path meta.name with
  | Some entry when Option.is_some entry.current_turn_observation ->
      (try
         ignore (Coord.heartbeat ctx.config ~agent_name:meta.agent_name)
       with
       | Eio.Cancel.Cancelled _ as e -> raise e
       | exn ->
           Log.Keeper.debug "in-turn heartbeat failed for %s: %s"
             meta.name (Printexc.to_string exn));
      let now_ts = Time_compat.now () in
      (try
         Sse.broadcast
           (`Assoc
              [ "type", `String "keeper_heartbeat"
              ; "name", `String meta.name
              ; "generation", `Int meta.runtime.generation
              ; "ts_unix", `Float now_ts
              ; "phase", `String "turn_running"
              ; "in_turn", `Bool true
              ])
       with
       | Eio.Cancel.Cancelled _ as e -> raise e
       | exn ->
           Log.Keeper.error "in-turn heartbeat SSE broadcast failed: %s"
             (Printexc.to_string exn))
  | _ -> ()
;;

let with_in_turn_liveness_pulse
      ~(ctx : _ context)
      ~(meta : keeper_meta)
      ~(stop : bool Atomic.t)
      f
  =
  with_in_turn_liveness_pulse_for_test
    ~sw:ctx.sw
    ~clock:ctx.clock
    ~interval_sec:(in_turn_liveness_pulse_interval_sec ())
    ~tick:(fun () ->
      if not (Atomic.get stop) then emit_in_turn_liveness_pulse ~ctx ~meta)
    f
;;

let run_keepalive_unified_turn
      ~(ctx : _ context)
      ~(meta_after_triage : keeper_meta)
      ~pending_board_events
      ~(stop : bool Atomic.t)
      ~(proactive_warmup_elapsed : bool)
      ~(shared_context : Oas.Context.t)
  : keeper_meta
  =
  if not proactive_warmup_elapsed
  then meta_after_triage
  else (
    try
      let obs =
        let allowed_tool_names =
          Keeper_tool_policy.keeper_allowed_tool_names meta_after_triage
        in
        Keeper_world_observation.observe
          ~allowed_tool_names:(Some allowed_tool_names)
          ~pending_board_events:(Some pending_board_events)
          ~config:ctx.config
          ~meta:meta_after_triage
      in
      let has_message_signal =
        obs.pending_mentions <> [] || obs.pending_scope_messages <> []
      in
      let turn_decision =
        Keeper_world_observation.keeper_cycle_decision
          ~meta:meta_after_triage
          obs
      in
      (* Manual reconcile blocker check removed — keepers no longer get
         stuck behind sticky blockers. Failed turns record evidence via
         Keeper_registry; recovery is autonomous (next turn's observation)
         or operator-driven (board/keeper_chat), not blocker-driven. *)
      let should_run_turn =
        (not (Atomic.get stop))
        && turn_decision.should_run
      in
      let meta_after_observe =
        Keeper_world_observation.apply_message_cursor_updates
          meta_after_triage
          obs.message_cursor_updates
      in
      let format_opt_int = function
        | Some value -> string_of_int value
        | None -> "-"
      in
      let verdict_strs = Keeper_world_observation.verdict_reasons_to_strings turn_decision.verdict in
      let channel_str = Keeper_world_observation.channel_to_string turn_decision.channel in
      if not should_run_turn then (
        (* #10008 fm3: emit per-reason skip counter so operators can
           see why proactive scheduler never fires for a given keeper.
           scholar/executor stayed at [proactive_count_total=0,
           last_proactive_ts=0.0] for 45+ min despite
           proactive_enabled=true — the info log alone buried the
           reason across many lines.  Labelled counter lets Grafana
           split [no_signal] vs [cooldown_pending] vs
           [scheduled_autonomous_disabled] so the bootstrap problem
           ("need signals to fire, need to fire to generate signals")
           is visible fleet-wide. *)
        List.iter (fun reason_str ->
          Prometheus.inc_counter
            proactive_skip_reason_metric
            ~labels:[
              ("keeper", meta_after_triage.name);
              ("reason", reason_str);
            ] ())
          verdict_strs;
        let log_not_scheduled =
          match turn_decision.verdict with
          | Keeper_world_observation.Skip { reasons = (Keeper_world_observation.Scheduled_autonomous_disabled, []) } ->
              Log.Keeper.debug
          | _ -> Log.Keeper.info
        in
        log_not_scheduled
          "keepalive turn not scheduled for %s: should_run=%b channel=%s reasons=[%s] idle=%ds since_last=%s idle_gate=%s cooldown=%s task_cooldown=%s"
          meta_after_triage.name
          turn_decision.should_run channel_str
          (String.concat "," verdict_strs)
          obs.idle_seconds
          (format_since_last_scheduled_autonomous
             turn_decision.since_last_scheduled_autonomous)
          (format_opt_int turn_decision.idle_gate_sec)
          (format_opt_int turn_decision.effective_cooldown)
          (format_opt_int turn_decision.task_reactive_cooldown));
      if should_run_turn then
        Log.Keeper.info
          "keepalive turn scheduled for %s: channel=%s reasons=%s"
          meta_after_triage.name channel_str
          (String.concat "," verdict_strs);
      (* Phase A2: record decision in audit trail (skip all work when disabled) *)
      if Keeper_decision_audit.audit_enabled () then begin
        let audit_wall_clock = Time_compat.now () in
        let tool_diversity_entropy =
          let entries =
            Keeper_registry.tool_usage_of
              ~base_path:ctx.config.base_path meta_after_triage.name
          in
          if entries = [] then None
          else
            let stats = Keeper_tool_diversity.stats_of_registry_entries entries in
            let available_tools =
              Keeper_tool_policy.keeper_allowed_tool_names meta_after_triage
            in
            let summary =
              Keeper_tool_diversity.compute_diversity ~available_tools stats
            in
            Some summary.normalized_entropy
        in
        Keeper_decision_audit.append
          ~keeper_name:meta_after_triage.name
          (Keeper_decision_audit.make
             ~cycle_id:(Printf.sprintf "cycle-%s-%Ld"
                meta_after_triage.name
                (Int64.of_float (audit_wall_clock *. 1000.0)))
             ~keeper_name:meta_after_triage.name
             ~generation:meta_after_triage.runtime.generation
             ~heartbeat_verdict:Heartbeat_smart.Emit
             ~turn_verdict:turn_decision.verdict
             ~wall_clock:audit_wall_clock
             ?tool_diversity_entropy ());
        Keeper_decision_audit.flush_if_needed
          ~base_path:ctx.config.base_path
          ~keeper_name:meta_after_triage.name
      end;
      if (not should_run_turn)
         && (not has_message_signal)
         && obs.message_cursor_updates <> []
      then (
        match write_meta ctx.config meta_after_observe with
        | Ok () -> ()
        | Error e ->
            Prometheus.inc_counter Prometheus.metric_keeper_write_meta_failures
              ~labels:[("keeper", meta_after_observe.name); ("phase", "cursor_update")] ();
            Log.Keeper.warn "write_meta failed (message cursor update): %s" e);
      if Atomic.get stop
      then meta_after_triage
      else if should_run_turn
      then (
        match
          with_keeper_turn_slot ~keeper_name:meta_after_triage.name
            ~channel:turn_decision.channel (fun ~semaphore_wait_ms ->
            match
              with_in_turn_liveness_pulse ~ctx ~meta:meta_after_observe ~stop
                (fun () ->
                  Keeper_unified_turn.run_keeper_cycle
                    ~config:ctx.config
                    ~meta:meta_after_observe
                    ~observation:obs
                    ~generation:meta_after_observe.runtime.generation
                    ~channel:turn_decision.channel
                    ~semaphore_wait_ms:semaphore_wait_ms
                    ~shared_context
                    ())
            with
            | Error err ->
              let e_str = Oas.Error.to_string err in
              (* The inner [run_keeper_cycle] already emits a detailed ERROR
                 ("keeper cycle FAILED cascade=... max_context=... error=...")
                 for every Error path, so re-logging at ERROR here duplicates
                 the line for the same event. Keep a debug trace for local
                 readers; escalate to ERROR only on the fatal-environment
                 branch, which is the real signal this layer owns. *)
              Log.Keeper.debug "%s: keeper cycle failed: %s"
                meta_after_observe.name e_str;
              if String_util.contains_substring e_str "Eio switch not available"
                 || String_util.contains_substring e_str "Eio net not available"
              then begin
                Log.Keeper.error
                  "%s: fatal environment error — promoting to Keeper_fiber_crash: %s"
                  meta_after_observe.name e_str;
                Keeper_registry.set_failure_reason
                  ~base_path:ctx.config.base_path meta_after_observe.name
                  (Some (Keeper_registry.Exception
                    (Printf.sprintf "fatal environment error: %s" e_str)));
                raise Keeper_registry.Keeper_fiber_crash
              end;
              (match read_meta ctx.config meta_after_observe.name with
               | Ok (Some latest) -> latest
               | Ok None ->
                 Log.Keeper.error "keeper:%s read_meta returned None after turn failure, using stale meta"
                   meta_after_observe.name;
                 meta_after_observe
               | Error e ->
                 Log.Keeper.error "keeper:%s read_meta failed after turn failure (%s), using stale meta"
                   meta_after_observe.name e;
                 meta_after_observe)
            | Ok updated ->
              updated)
        with
        | Ok meta -> meta
        | Error (`Semaphore_wait_timeout wait_sec) ->
          (* Peers held the turn semaphore longer than the wait cap — not a
             keeper failure. Skip this cycle and let the next heartbeat retry
             once a slot opens up. Meta is left untouched so failure counters
             do not tick. *)
          Log.Keeper.warn
            "%s: skipping turn (semaphore wait > %.0fs, peers holding slot)"
            meta_after_triage.name wait_sec;
          meta_after_triage)
      else if (not has_message_signal) && obs.message_cursor_updates <> [] then
        meta_after_observe
      else
        meta_after_triage
    with
    | Eio.Cancel.Cancelled _ as e -> raise e
    | Keeper_registry.Keeper_fiber_crash as e -> raise e
    | exn ->
      Log.Keeper.error "%s: keeper cycle exception: %s"
        meta_after_triage.name (Printexc.to_string exn);
      meta_after_triage)
;;

let refresh_work_as_heartbeat
      ~(ctx : _ context)
      ~(meta_after_proactive : keeper_meta)
      ~(proactive_warmup_elapsed : bool)
      ~(work_as_hb : unit -> bool)
      ~(last_successful_heartbeat_ts : float ref)
      ~(consecutive_failures : int ref)
  : unit
  =
  if work_as_hb () && proactive_warmup_elapsed
  then (
    let hb_ok =
      List.exists
        (fun _room_id ->
           try
             ignore
               (Coord.heartbeat
                  ctx.config
                  ~agent_name:meta_after_proactive.agent_name);
             true
           with
           | Eio.Cancel.Cancelled _ as e -> raise e
           | exn ->
             Log.Keeper.debug
               "heartbeat failed for %s: %s"
               meta_after_proactive.name
               (Printexc.to_string exn);
             false)
        meta_after_proactive.joined_room_ids
    in
    if hb_ok
    then (
      last_successful_heartbeat_ts := Time_compat.now ();
      consecutive_failures := 0))
;;

let dispatch_recurring_keepalive
      ~(ctx : _ context)
      ~(meta_after_proactive : keeper_meta)
      ~(now_ts : float)
  : int
  =
  try
    Keeper_recurring.dispatch_due
      ~keeper_name:meta_after_proactive.name
      ~now_ts
      ~dispatch:(fun task action ->
        match action with
        | Keeper_recurring.Broadcast msg ->
          (try
             let _ =
               Coord.broadcast
                 ctx.config
                 ~from_agent:meta_after_proactive.agent_name
                 ~content:(Printf.sprintf "[loop:%s] %s" task.label msg)
             in
             Log.Keeper.info "[recurring] %s dispatched: %s" task.id task.label;
             Ok ()
           with
           | exn ->
             Log.Keeper.warn "[recurring] %s failed: %s" task.id (Printexc.to_string exn);
             Error (Printexc.to_string exn)))
  with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | exn ->
    Log.Keeper.warn "[recurring] dispatch error: %s" (Printexc.to_string exn);
    0
;;

(** Whether a smart-heartbeat decision should allow the keepalive
    cycle to continue evaluating turns.

    Pure for testability. The full [run_smart_heartbeat_gate] layers
    side-effects (sleep, cycle-timestamp update) on top of this
    decision. Regression guard for the "claim-holding keeper
    starvation" bug: [Skip_busy] must NOT gate cycle execution,
    otherwise any keeper with [current_task_id=Some _] is blocked
    from ever running a turn (discovered 2026-04-25 — 8/14 keepers
    frozen with claimed tasks). *)
let smart_heartbeat_cycle_continues (d : Heartbeat_smart.decision) : bool =
  match d with
  | Heartbeat_smart.Skip_busy | Heartbeat_smart.Emit -> true
  | Heartbeat_smart.Skip_idle _ -> false
;;

let run_smart_heartbeat_gate
      ~(clock : _ Eio.Time.clock)
      ~(stop : bool Atomic.t)
      ~(wakeup : bool Atomic.t)
      ~(meta_current : keeper_meta)
      ~(smart_hb_enabled : unit -> bool)
      ~(smart_hb_config : Heartbeat_smart.config)
      ~(last_successful_heartbeat_ts : float ref)
      ~(last_heartbeat_cycle_ts : float ref)
  : bool
  =
  let smart_hb_decision =
    if smart_hb_enabled ()
    then (
      let agent_status = keeper_agent_status meta_current in
      Heartbeat_smart.should_emit
        ~config:smart_hb_config
        ~agent_status
        ~last_activity:!last_successful_heartbeat_ts
        ~last_heartbeat:!last_heartbeat_cycle_ts)
    else Heartbeat_smart.Emit
  in
  (* Run side-effects (idle sleep, cycle-timestamp update) per the
     decision, then use [smart_heartbeat_cycle_continues] (pure, see
     .mli) as the authoritative gate answer. This split exists so the
     regression guard lives in a pure function that unit tests can
     exercise without an Eio runtime. *)
  (match smart_hb_decision with
   | Heartbeat_smart.Skip_busy ->
     Log.Keeper.debug
       "smart heartbeat: busy (task=%s) — cycle continues, broadcast may be debounced"
       (match meta_current.current_task_id with Some t -> Keeper_id.Task_id.to_string t | None -> "?");
     last_heartbeat_cycle_ts := Time_compat.now ()
   | Heartbeat_smart.Skip_idle next_time ->
     let wait = Float.max 1.0 (next_time -. Time_compat.now ()) in
     Log.Keeper.debug "smart heartbeat: skip (idle, next in %.1fs)" wait;
     let jitter = wait *. 0.1 *. Random.float 1.0 in
     interruptible_sleep ~clock ~stop ~wakeup (wait +. jitter)
   | Heartbeat_smart.Emit ->
     last_heartbeat_cycle_ts := Time_compat.now ());
  smart_heartbeat_cycle_continues smart_hb_decision
;;

let maybe_write_heartbeat_snapshot
      ~(ctx : _ context)
      ~(meta_current : keeper_meta)
      ~(now_ts : float)
      ~(consecutive_hb_failures : int)
      ~(last_snapshot_ts : float ref)
      ~(snapshot_interval_sec : int)
      ~(timing_ring : stage_timing array)
      ~(timing_filled : int)
  : unit
  =
  if now_ts -. !last_snapshot_ts >= float_of_int snapshot_interval_sec
  then (
    (try
       write_heartbeat_snapshot
         ~ctx
         ~meta_current
         ~now_ts
         ~consecutive_hb_failures
         ~timing_ring
         ~timing_filled
     with
     | Eio.Cancel.Cancelled _ as e -> raise e
     | exn ->
       Log.Keeper.error "heartbeat snapshot write failed: %s" (Printexc.to_string exn));
    last_snapshot_ts := now_ts)
;;

let record_keepalive_stage_timing
      ~(timing_ring : stage_timing array)
      ~(timing_cursor : int ref)
      ~(timing_filled : int ref)
      ~(ring_sz : int)
      ~(t_presence_start : float)
      ~(t_presence_end : float)
      ~(t_snapshot_start : float)
      ~(t_snapshot_end : float)
      ~(t_board_start : float)
      ~(t_board_end : float)
      ~(t_turn_start : float)
      ~(t_turn_end : float)
      ~(t_recurring_start : float)
      ~(t_recurring_end : float)
  : unit
  =
  let timing =
    { presence_ms = (t_presence_end -. t_presence_start) *. 1000.0
    ; snapshot_ms = (t_snapshot_end -. t_snapshot_start) *. 1000.0
    ; board_ms = (t_board_end -. t_board_start) *. 1000.0
    ; turn_ms = (t_turn_end -. t_turn_start) *. 1000.0
    ; recurring_ms = (t_recurring_end -. t_recurring_start) *. 1000.0
    }
  in
  timing_ring.(!timing_cursor) <- timing;
  timing_cursor := (!timing_cursor + 1) mod ring_sz;
  if !timing_filled < ring_sz then incr timing_filled
;;

let run_heartbeat_loop
      ~proactive_warmup_sec
      (ctx : _ context)
      (m : keeper_meta)
      (stop : bool Atomic.t)
      ~(wakeup : bool Atomic.t)
  : unit
  =
  let keepalive_started_ts = Time_compat.now () in
  let snapshot_interval_sec () =
    Runtime_params.get Governance_registry.keeper_snapshot_sec
  in
  let last_snapshot_ts = ref 0.0 in
  let consecutive_failures = ref 0 in
  (* Phase 0: per-stage timing ring buffer.
     ring_size is read once at fiber start — mid-flight resize requires
     ring buffer reallocation, so new values apply on next fiber restart. *)
  let ring_sz = stage_timing_ring_size () in
  let timing_ring =
    Array.make
      ring_sz
      { presence_ms = 0.0
      ; snapshot_ms = 0.0
      ; board_ms = 0.0
      ; turn_ms = 0.0
      ; recurring_ms = 0.0
      }
  in
  let timing_cursor = ref 0 in
  let timing_filled = ref 0 in
  (* Phase 1: work-as-heartbeat freshness tracking.
     Updated ONLY on Coord.heartbeat success after turn. *)
  let last_successful_heartbeat_ts = ref (Time_compat.now ()) in
  let work_as_hb () = Runtime_params.get Governance_registry.keeper_work_as_hb_enabled in
  let max_silence () =
    Runtime_params.get Governance_registry.keeper_work_as_hb_max_silence_sec
  in
  (* Phase 2: smart heartbeat — adaptive scheduling via Heartbeat_smart *)
  let smart_hb_enabled () =
    Runtime_params.get Governance_registry.keeper_smart_hb_enabled
  in
  let smart_hb_config = Heartbeat_smart.default_config in
  let last_heartbeat_cycle_ts = ref 0.0 in
  (* Persistent OAS Context.t — created once per keeper lifecycle.
     OAS Context.t is a mutable cross-turn state container for values
     written directly into the shared context. This preserves shared
     metadata across turns, but per-turn context_injector-local timing
     and tool-call counters are recreated inside run_turn and therefore
     do not accumulate for the full keeper lifecycle. *)
  let shared_context = Oas.Context.create () in
  (* Mtime-based change detection for keeper meta disk reads.
     Avoids re-parsing the JSON file on every heartbeat cycle when
     no operator has modified it.  Initialized to 0.0 so the first
     cycle always reads. *)
  let last_meta_mtime = ref 0.0 in
  let rec loop () =
    if Atomic.get stop
    then ()
    else (
      (* Yield before each heartbeat cycle to prevent N keeper fibers
               from monopolizing the Eio scheduler during CPU-bound phases
               (tool filtering, snapshot construction, prompt building). *)
      Eio.Fiber.yield ();
      (* Phase 0: timing markers *)
      let t_presence_start = Time_compat.now () in
      let disk_meta_opt, new_meta_mtime =
        match read_meta_if_changed ctx.config m.name ~last_mtime:!last_meta_mtime with
        | Some (latest, new_mtime) ->
          Some latest, Some new_mtime
        | None -> None, None
      in
      Option.iter (fun new_mtime -> last_meta_mtime := new_mtime) new_meta_mtime;
      let meta_current =
        effective_keepalive_meta
          ~base_path:ctx.config.base_path
          ~fallback:m
          ~disk_meta_opt
      in
      let meta_current =
        match repair_identity_drift_for_keepalive ~ctx meta_current with
        | Some repaired -> repaired
        | None -> meta_current
      in
      (* Sync disk meta to registry so dashboard reads live values.  #5364.
         When disk meta is unchanged we still prefer the registry copy because
         runtime writes update it via the write_meta hook. This keeps
         continuity/runtime fields fresh even if disk mtime does not advance
         between rapid writes inside a single loop window. *)
      let registry_meta =
        match Keeper_registry.get ~base_path:ctx.config.base_path meta_current.name with
        | Some entry -> entry.meta
        | None -> m
      in
      if meta_current != registry_meta then
        Keeper_registry.update_meta
          ~base_path:ctx.config.base_path meta_current.name meta_current;
      if
        run_smart_heartbeat_gate
          ~clock:ctx.clock
          ~stop
          ~wakeup
          ~meta_current
          ~smart_hb_enabled
          ~smart_hb_config
          ~last_successful_heartbeat_ts
          ~last_heartbeat_cycle_ts
      then (
        (* Phase 1: skip presence sync when recent room heartbeat proves freshness *)
        let meta_current =
          sync_keeper_presence
            ~ctx
            ~meta_current
            ~t_presence_start
            ~consecutive_failures
            ~last_successful_heartbeat_ts
            ~work_as_hb
            ~max_silence
        in
        (* RFC-0002: fiber crash on heartbeat threshold breach *)
        if !consecutive_failures >= max_consecutive_heartbeat_failures ()
        then begin
          Keeper_registry.set_failure_reason
            ~base_path:ctx.config.base_path m.name
            (Some (Keeper_registry.Heartbeat_consecutive_failures
                     !consecutive_failures));
          raise Keeper_registry.Keeper_fiber_crash
        end;
        let t_presence_end = Time_compat.now () in
        let now_ts = t_presence_end in
        let t_snapshot_start = now_ts in
        maybe_write_heartbeat_snapshot
          ~ctx
          ~meta_current
          ~now_ts
          ~consecutive_hb_failures:!consecutive_failures
          ~last_snapshot_ts
          ~snapshot_interval_sec:(snapshot_interval_sec ())
          ~timing_ring
          ~timing_filled:!timing_filled;
        let t_snapshot_end = Time_compat.now () in
        let t_board_start = t_snapshot_end in
        (* Compute warmup state BEFORE board collection so cursor
                 is not advanced while keeper cannot act on events. *)
        let proactive_warmup_elapsed =
          proactive_warmup_sec <= 0
          || now_ts -. keepalive_started_ts >= float_of_int proactive_warmup_sec
        in
        let pending_board_events, meta_after_triage =
          collect_keepalive_board_events ~ctx ~meta_current ~proactive_warmup_elapsed
        in
        let t_board_end = Time_compat.now () in
        let t_turn_start = t_board_end in
        let meta_after_proactive =
          run_keepalive_unified_turn
            ~ctx
            ~meta_after_triage
            ~pending_board_events
            ~stop
            ~proactive_warmup_elapsed
            ~shared_context
        in
        (* Turn failure threshold: registry tracks count (via unified_turn),
                 keepalive raises to terminate the fiber for supervisor restart. *)
        let turn_fail_count =
          Keeper_registry.get_turn_failures ~base_path:ctx.config.base_path m.name
        in
        (* RFC-0002: dispatch turn status event *)
        if turn_fail_count > 0 then
          dispatch_keepalive_event ~ctx ~keeper_name:m.name
            (Keeper_state_machine.Turn_failed {
              consecutive = turn_fail_count;
              max_allowed = max_consecutive_turn_failures ();
            })
        else
          dispatch_keepalive_event ~ctx ~keeper_name:m.name
            Keeper_state_machine.Turn_succeeded;
        if turn_fail_count >= max_consecutive_turn_failures ()
        then begin
          Keeper_registry.set_failure_reason
            ~base_path:ctx.config.base_path m.name
            (Some (Keeper_registry.Turn_consecutive_failures turn_fail_count));
          raise Keeper_registry.Keeper_fiber_crash
        end;
        (* Phase 1: work-as-heartbeat — renew point (b).
                 After turn, call Coord.heartbeat to prove room I/O health.
                 On success: refresh freshness lease + reset consecutive_failures.
                 On failure: leave timestamp unchanged → presence sync resumes next cycle. *)
        refresh_work_as_heartbeat
          ~ctx
          ~meta_after_proactive
          ~proactive_warmup_elapsed
          ~work_as_hb
          ~last_successful_heartbeat_ts
          ~consecutive_failures;
        let t_turn_end = Time_compat.now () in
        let t_recurring_start = t_turn_end in
        (* Recurring task dispatch (#3190) *)
        let _recurring_dispatched =
          dispatch_recurring_keepalive ~ctx ~meta_after_proactive ~now_ts
        in
        let t_recurring_end = Time_compat.now () in
        let base =
          if smart_hb_enabled ()
          then
            Heartbeat_smart.effective_interval
              ~config:smart_hb_config
              ~last_activity:!last_successful_heartbeat_ts
          else float_of_int (keepalive_interval_sec ())
        in
        (* Phase 0: push stage timing to ring buffer *)
        record_keepalive_stage_timing
          ~timing_ring
          ~timing_cursor
          ~timing_filled
          ~ring_sz
          ~t_presence_start
          ~t_presence_end
          ~t_snapshot_start
          ~t_snapshot_end
          ~t_board_start
          ~t_board_end
          ~t_turn_start
          ~t_turn_end
          ~t_recurring_start
          ~t_recurring_end;
        let jitter =
          base *. Env_config.KeeperKeepalive.jitter_factor *. Random.float 1.0
        in
        interruptible_sleep ~clock:ctx.clock ~stop ~wakeup (base +. jitter));
      if Atomic.get stop then () else loop ())
  in
  loop ()
;;

let with_keeper_entry_by_identity ~identity ~on_missing f =
  match Keeper_registry.find_by_agent_name identity with
  | Some entry -> f entry
  | None ->
    (match Keeper_registry.find_by_name identity with
     | Some entry -> f entry
     | None -> on_missing ())
;;

let persist_directive_meta_update
    (entry : Keeper_registry.registry_entry)
    ~(updated_meta : keeper_meta) : unit =
  let keeper_filename = entry.name ^ ".json" in
  let masc_root = Coord_utils.masc_dir_from_base_path ~base_path:entry.base_path in
  let default_path = Filename.concat (Filename.concat masc_root "keepers") keeper_filename in
  let persisted_path =
    if Fs_compat.file_exists default_path then
      default_path
    else
      let clusters_dir = Filename.concat masc_root "clusters" in
      let cluster_paths =
        match Safe_ops.list_dir_safe clusters_dir with
        | Ok names ->
            names
            |> List.map (fun cluster_name ->
                   Filename.concat
                     (Filename.concat (Filename.concat clusters_dir cluster_name) "keepers")
                     keeper_filename)
            |> List.filter Fs_compat.file_exists
        | Error _ -> []
      in
      match cluster_paths with
      | [] -> default_path
      | [ path ] -> path
      | paths ->
          let by_mtime_desc a b =
            let a_mtime = Option.value ~default:0.0 (Fs_compat.file_mtime a) in
            let b_mtime = Option.value ~default:0.0 (Fs_compat.file_mtime b) in
            Float.compare b_mtime a_mtime
          in
          (match List.sort by_mtime_desc paths with
           | latest_path :: _ -> latest_path
           | [] -> default_path)
  in
  match Keeper_fs.save_json_atomic persisted_path (meta_to_json updated_meta) with
  | Ok () ->
    Keeper_registry.update_meta
      ~base_path:entry.base_path
      entry.name
      updated_meta
  | Error msg ->
    Log.Keeper.warn
      "directive meta persist failed for %s: %s"
      entry.name
      msg;
    Keeper_registry.update_meta
      ~base_path:entry.base_path
      entry.name
        updated_meta

let set_keeper_paused_state ~agent_name paused =
  with_keeper_entry_by_identity
    ~identity:agent_name
    ~on_missing:(fun () ->
      let action = if paused then "pause" else "resume" in
      Log.Keeper.warn "directive %s: agent %s not in registry" action agent_name)
    (fun entry ->
       let updated_meta =
         {
           entry.meta with
           paused;
           updated_at = now_iso ();
         }
       in
       persist_directive_meta_update entry ~updated_meta;
       ignore
         (Keeper_registry.dispatch_event
            ~base_path:entry.base_path entry.name
            (if paused
             then Keeper_state_machine.Operator_pause
             else Keeper_state_machine.Operator_resume));
       if not paused then Atomic.set entry.fiber_wakeup true)
;;

let wakeup_keeper_by_agent_name ~agent_name =
  with_keeper_entry_by_identity
    ~identity:agent_name
    ~on_missing:(fun () ->
      Log.Keeper.warn "directive wakeup: agent %s not in registry" agent_name)
    (fun entry -> wakeup_keeper ~base_path:entry.base_path entry.name)
;;

let assign_keeper_task_from_directive ~agent_name ~task_id =
  with_keeper_entry_by_identity
    ~identity:agent_name
    ~on_missing:(fun () ->
      Log.Keeper.warn "directive claim: agent %s not in registry" agent_name)
    (fun entry ->
       let updated_meta =
         {
           entry.meta with
           current_task_id = Some task_id;
           updated_at = now_iso ();
         }
       in
       persist_directive_meta_update entry ~updated_meta;
       wakeup_keeper ~base_path:entry.base_path entry.name)
;;

(** Process a single directive received from a gRPC HeartbeatAck.
    Directives are string commands: "pause", "resume", "wakeup",
    "claim:<task_id>". Unknown directives are logged and ignored. *)
let process_directive ~agent_name directive =
  match directive with
  | "pause" ->
    Log.Keeper.info "directive: pausing keeper %s" agent_name;
    set_keeper_paused_state ~agent_name true
  | "resume" ->
    Log.Keeper.info "directive: resuming keeper %s" agent_name;
    set_keeper_paused_state ~agent_name false
  | "wakeup" ->
    Log.Keeper.debug "directive: waking up %s" agent_name;
    wakeup_keeper_by_agent_name ~agent_name
  | s when String.length s > 6 && String.sub s 0 6 = "claim:" ->
    let task_id = String.sub s 6 (String.length s - 6) in
    (match Keeper_id.Task_id.of_string task_id with
     | Ok parsed_task_id ->
       Log.Keeper.info "directive: server assigned task %s to %s" task_id agent_name;
       assign_keeper_task_from_directive ~agent_name ~task_id:parsed_task_id
     | Error err ->
       Log.Keeper.warn
         "directive: ignoring invalid task assignment for %s (%s): %s"
         agent_name task_id err)
  | unknown -> Log.Keeper.warn "unknown gRPC directive for %s: %s" agent_name unknown
;;

let current_task_id_for_agent agent_name =
  match Keeper_registry.find_by_agent_name agent_name with
  | Some e -> (match e.meta.current_task_id with Some t -> Keeper_id.Task_id.to_string t | None -> "")
  | None -> ""
;;

let make_grpc_heartbeat_ping ~agent_name ~session_id =
  Masc_grpc_types.HeartbeatPing.
    { agent_name
    ; session_id
    ; timestamp_ms = Int64.of_float (Time_compat.now () *. 1000.0)
    ; current_task_id = current_task_id_for_agent agent_name
    }
;;

let handle_grpc_heartbeat_ack ~agent_name (ack : Masc_grpc_types.HeartbeatAck.t) =
  Log.Keeper.debug
    "gRPC bidi heartbeat: agent=%s agents=%d tasks=%d directives=%d"
    agent_name
    ack.active_agent_count
    ack.pending_task_count
    (List.length ack.directives);
  List.iter (process_directive ~agent_name) ack.directives
;;

let run_grpc_heartbeat_stream
      ~stop
      ~close_ref
      ~clock
      ~interval_sec
      ~agent_name
      ~session_id
      send
      recv
  =
  let rec tick () =
    if Atomic.get stop || Atomic.get close_ref
    then ()
    else (
      (try
         send (make_grpc_heartbeat_ping ~agent_name ~session_id);
         match recv () with
         | Ok ack -> handle_grpc_heartbeat_ack ~agent_name ack
         | Error err -> Log.Keeper.warn "gRPC heartbeat recv: %s" err
       with
       | Eio.Cancel.Cancelled _ as e -> raise e
       | End_of_file -> raise End_of_file
       | exn -> Log.Keeper.error "gRPC heartbeat tick error: %s" (Printexc.to_string exn));
      if not (Atomic.get stop || Atomic.get close_ref)
      then (
        let no_wakeup = Atomic.make false in
        interruptible_sleep ~clock ~stop ~wakeup:no_wakeup interval_sec;
        tick ()))
  in
  tick ()
;;

let log_grpc_heartbeat_stream_failure ~agent_name ~attempts = function
  | `Closed ->
    Log.Keeper.warn
      "gRPC heartbeat stream closed for %s (attempt %d/%d)"
      agent_name
      (attempts + 1)
      Env_config.KeeperGrpc.max_reconnect_attempts
  | `Error exn ->
    Log.Keeper.warn
      "gRPC heartbeat stream error for %s: %s (attempt %d/%d)"
      agent_name
      (Printexc.to_string exn)
      (attempts + 1)
      Env_config.KeeperGrpc.max_reconnect_attempts
;;

(** Run a gRPC heartbeat sender in a background fiber.
    Opens a bidirectional [Heartbeat] stream and sends [HeartbeatPing]
    messages at the configured interval. Reads [HeartbeatAck] responses,
    logs agent/task counts, and dispatches directives. Reconnects on
    stream failure up to 5 times. Stops when [stop] is set.

    Requires [grpc_client_ref] to be set (via [set_grpc_client])
    and Eio switch/env to be available in [Eio_context]. *)
let max_reconnect_attempts = Env_config.KeeperGrpc.max_reconnect_attempts

let reconnect_backoff_sec = Env_config.KeeperGrpc.reconnect_backoff_sec

let run_grpc_heartbeat_fiber
      ~sw
      ~stop
      ~(grpc_client : Masc_grpc_client.t)
      ~(agent_name : string)
      ~(session_id : string)
      ~(interval_sec : float)
      ~(clock : _ Eio.Time.clock)
  =
  match Eio_context.get_switch_opt (), Atomic.get grpc_env_ref with
  | None, _ | _, None ->
    Log.Keeper.warn "gRPC heartbeat: Eio context or env not available";
    None
  | Some grpc_sw, Some env ->
    let close_ref = Atomic.make false in
    Eio.Fiber.fork ~sw (fun () ->
      (* Outer loop: reconnect on stream failure *)
      let rec connect_loop attempts =
        if Atomic.get stop || Atomic.get close_ref
        then ()
        else if attempts >= max_reconnect_attempts
        then
          Log.Keeper.error
            "gRPC heartbeat: exceeded %d reconnect attempts for %s, stopping"
            max_reconnect_attempts
            agent_name
        else (
          let send, recv, close_stream =
            Masc_grpc_client.heartbeat_stream grpc_client ~sw:grpc_sw ~env
          in
          (try
             run_grpc_heartbeat_stream
               ~stop
               ~close_ref
               ~clock
               ~interval_sec
               ~agent_name
               ~session_id
               send
               recv
           with
           | Eio.Cancel.Cancelled _ as e ->
             close_stream ();
             raise e
           | End_of_file ->
             log_grpc_heartbeat_stream_failure ~agent_name ~attempts `Closed;
             close_stream ()
           | exn ->
             log_grpc_heartbeat_stream_failure ~agent_name ~attempts (`Error exn);
             close_stream ());
          if not (Atomic.get stop || Atomic.get close_ref)
          then (
            Eio.Time.sleep clock reconnect_backoff_sec;
            connect_loop (attempts + 1)))
      in
      connect_loop 0);
    Some (fun () -> Atomic.set close_ref true)
;;

let start_keeper_grpc_heartbeat
      ~(ctx : _ context)
      ~(m : keeper_meta)
      ~(stop : bool Atomic.t)
  : (unit -> unit) option
  =
  match Masc_grpc_transport.from_env (), Atomic.get grpc_client_ref with
  | Masc_grpc_transport.Grpc, Some client ->
    Log.Keeper.info "keeper %s: starting gRPC heartbeat fiber" m.name;
    let interval = float_of_int (keepalive_interval_sec ()) in
    let session_id =
      Printf.sprintf
        "keeper-%s-%Ld"
        m.name
        (Int64.of_float (Time_compat.now () *. 1000.0))
    in
    run_grpc_heartbeat_fiber
      ~sw:ctx.sw
      ~stop
      ~grpc_client:client
      ~agent_name:m.agent_name
      ~session_id
      ~interval_sec:interval
      ~clock:ctx.clock
  | Masc_grpc_transport.Grpc, None ->
    Log.Keeper.warn "keeper %s: gRPC transport requested but no client configured" m.name;
    None
  | _ -> None
;;

let bootstrap_live_keeper_meta ~(ctx : _ context) (m : keeper_meta) : keeper_meta =
  try
    if not (Coord_utils.is_initialized ctx.config)
    then (
      let (_init_msg : string) = Coord.init ctx.config ~agent_name:None in
      ());
    let m =
      match repair_identity_drift_for_keepalive ~ctx m with
      | Some repaired -> repaired
      | None -> m
    in
    let synced = ensure_keeper_room_presence ctx.config m in
    (* Reset stale timestamp from previous server lifecycle.
       Without this, the stale watchdog reads the old last_turn_ts
       and immediately terminates the fiber on server restart. *)
    let synced =
      { synced with
        runtime = { synced.runtime with
          usage = { synced.runtime.usage with last_turn_ts = 0.0 };
        };
      }
    in
    (match write_meta ~force:true ctx.config synced with
     | Ok () -> ()
     | Error e ->
       Prometheus.inc_counter Prometheus.metric_keeper_write_meta_failures
         ~labels:[("keeper", synced.name); ("phase", "bootstrap")] ();
       Log.Keeper.warn "write_meta failed (bootstrap): %s" e);
    synced
  with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | exn ->
    Log.Keeper.error "room presence bootstrap failed: %s" (Printexc.to_string exn);
    m
;;

(* #8856: hook takes the unified
   [Keeper_lifecycle_events.lifecycle_event] variant. *)
let publish_keeper_lifecycle
    ~(event : Keeper_lifecycle_events.lifecycle_event)
    ~keeper_name ~detail () : unit =
  match get_bus () with
  | Some bus ->
    Oas_events.publish_keeper_lifecycle
      bus
      ~event
      ~keeper_name
      ~detail
      ()
  | None -> ()
;;

(** Phase-event helper: the wire event name IS the phase name. *)
let publish_keeper_phase_lifecycle ~phase ~keeper_name ~detail () : unit =
  publish_keeper_lifecycle
    ~event:(Keeper_lifecycle_events.Phase_event phase)
    ~keeper_name ~detail ()
;;

let publish_keeper_started ~(live_meta : keeper_meta) : unit =
  publish_keeper_lifecycle
    ~event:(Keeper_lifecycle_events.Custom_event
              { verb = Keeper_lifecycle_events.Started;
                phase = Some Keeper_state_machine.Running })
    ~keeper_name:live_meta.name
    ~detail:"keepalive"
    ()
;;

let dispatch_fiber_started ~base_path keeper_name =
  match Keeper_registry.prepare_fiber_launch ~base_path keeper_name with
  | Ok _ -> ()
  | Error err ->
      Log.Keeper.warn
        "keeper %s: Fiber_started rejected during launch: %s"
        keeper_name
        (Keeper_state_machine.transition_error_to_string err)
;;

let resolve_registry_done
      (entry : Keeper_registry.registry_entry)
      (value : [ `Stopped | `Crashed of string ])
  : bool
  =
  if Option.is_none (Eio.Promise.peek entry.done_p)
  then (
    Eio.Promise.resolve entry.done_r value;
    true)
  else false
;;

let record_keeper_stopped
      (entry : Keeper_registry.registry_entry)
      ~base_path
      ~keeper_name
      ~detail
  : bool
  =
  if resolve_registry_done entry `Stopped
  then (
    ignore (Keeper_registry.dispatch_event ~base_path keeper_name
      Keeper_state_machine.Stop_requested);
    ignore (Keeper_registry.dispatch_event ~base_path keeper_name
      Keeper_state_machine.Drain_complete);
    publish_keeper_phase_lifecycle ~phase:Keeper_state_machine.Stopped
      ~keeper_name ~detail ();
    true)
  else
    false
;;

let record_keeper_crashed
      (entry : Keeper_registry.registry_entry)
      ~base_path
      ~keeper_name
      ~failure_reason
  : unit
  =
  let reason = Keeper_registry.failure_reason_to_string failure_reason in
  if resolve_registry_done entry (`Crashed reason)
  then (
    Keeper_registry.set_failure_reason ~base_path keeper_name (Some failure_reason);
    ignore (Keeper_registry.dispatch_event ~base_path keeper_name
      (Keeper_state_machine.Fiber_terminated { outcome = reason }));
    Keeper_registry.record_crash ~base_path keeper_name (Time_compat.now ()) reason;
    Keeper_registry.record_error ~base_path keeper_name reason;
    publish_keeper_phase_lifecycle ~phase:Keeper_state_machine.Crashed
      ~keeper_name ~detail:reason ())
;;

let start_keepalive ?(proactive_warmup_sec = 0) (ctx : _ context) (m : keeper_meta) : unit
  =
  match repair_identity_drift_for_keepalive ~ctx m with
  | None ->
      Log.Keeper.error
        "start_keepalive skipped %s: identity drift could not be repaired"
        m.name
  | Some m -> (
  let existing_entry =
    Keeper_registry.get ~base_path:ctx.config.base_path m.name
  in
  let reclaim_stale_stopped_entry (entry : Keeper_registry.registry_entry) =
    entry.phase = Keeper_state_machine.Stopped
    && Eio.Promise.peek entry.done_p = Some `Stopped
  in
  (match existing_entry with
   | Some entry when reclaim_stale_stopped_entry entry ->
       Log.Keeper.info
         "start_keepalive: reclaiming stale stopped entry %s"
         m.name;
       Keeper_registry.unregister ~base_path:ctx.config.base_path m.name
   | _ -> ());
  if Keeper_registry.is_registered ~base_path:ctx.config.base_path m.name
  then Log.Keeper.info "start_keepalive: skipped %s (already registered)" m.name
  else if not (Keeper_registry.spawn_slots_available ())
  then Log.Keeper.info "start_keepalive: skipped %s (no spawn slots)" m.name
  else (
    (* Register in Keeper_registry first — single source of truth. *)
    let reg = Keeper_registry.register_offline ~base_path:ctx.config.base_path m.name m in
    (* Restore persisted tool usage stats from previous session *)
    Keeper_registry.restore_tool_usage ~base_path:ctx.config.base_path m.name;
    let stop = reg.fiber_stop in
    let wakeup = reg.fiber_wakeup in
    (* Start optional gRPC heartbeat fiber *)
    let grpc_close = start_keeper_grpc_heartbeat ~ctx ~m ~stop in
    (match grpc_close with
     | Some _ ->
       Keeper_registry.set_grpc_close ~base_path:ctx.config.base_path m.name grpc_close
     | None -> ());
    let live_meta = bootstrap_live_keeper_meta ~ctx m in
    Keeper_registry.update_meta ~base_path:ctx.config.base_path m.name live_meta;
    (* Telemetry feedback refresh loop removed in #6814:
       behavioral_stats no longer consumed by build_prompt. *)
    dispatch_fiber_started ~base_path:ctx.config.base_path live_meta.name;
    publish_keeper_started ~live_meta;
    Keeper_stale_watchdog.fork_stale_watchdog ctx live_meta reg;
    Eio.Fiber.fork ~sw:ctx.sw (fun () ->
      let record_crash failure_reason =
        record_keeper_crashed
          reg
          ~base_path:ctx.config.base_path
          ~keeper_name:live_meta.name
          ~failure_reason
      in
      let record_stopped detail =
        ignore
          (record_keeper_stopped
             reg
             ~base_path:ctx.config.base_path
             ~keeper_name:live_meta.name
             ~detail)
      in
      (* Cancel-safe finally (#9747 iter 2): [cleanup_tracking] touches
         registry state that can raise transiently during shutdown.
         Stdlib [Fun.protect] would wrap that as [Fun.Finally_raised],
         masking the body's Cancelled / Keeper_fiber_crash. Swallow
         Cancelled (the outer one is in flight) and log non-cancel
         exceptions instead of propagating them. Mirrors
         keeper_agent_run.ml and keeper_unified_turn.ml:990. *)
      let safe_cleanup_tracking () =
        try
          Keeper_registry.cleanup_tracking
            ~base_path:ctx.config.base_path live_meta.name
        with
        | Eio.Cancel.Cancelled _ -> ()
        | e ->
          Log.Keeper.warn
            "%s: cleanup_tracking in heartbeat finally raised: %s"
            live_meta.name (Printexc.to_string e)
      in
      Fun.protect
        (fun () ->
          try
            run_heartbeat_loop ~proactive_warmup_sec ctx live_meta stop ~wakeup;
            record_stopped "normal exit"
          with
          | Keeper_registry.Keeper_fiber_crash ->
            if Atomic.get stop then
              record_stopped "manual stop"
            else
              let reason =
                match Keeper_registry.get
                        ~base_path:ctx.config.base_path live_meta.name with
                | Some e ->
                  Option.value
                    ~default:(Keeper_registry.Exception "fiber_crash")
                    e.last_failure_reason
                | None -> Keeper_registry.Exception "fiber_crash"
              in
              record_crash reason
          | Eio.Cancel.Cancelled _ as e -> raise e
          | exn ->
            if Atomic.get stop then
              record_stopped "manual stop"
            else begin
              Log.Keeper.error
                "heartbeat loop for %s crashed: %s"
                live_meta.name
                (Printexc.to_string exn);
              record_crash (Keeper_registry.Exception (Printexc.to_string exn))
            end)
        ~finally:safe_cleanup_tracking))
  )
;;

let stop_keepalive ?base_path name =
  let entries =
    Keeper_registry.all ?base_path ()
    |> List.filter (fun (e : Keeper_registry.registry_entry) ->
         String.equal e.name name)
  in
  List.iter
    (fun (entry : Keeper_registry.registry_entry) ->
       Atomic.set entry.fiber_stop true;
       Atomic.set entry.fiber_wakeup true;
       (match Atomic.get entry.grpc_close with
       | Some close_fn ->
          (try close_fn () with
           | Eio.Cancel.Cancelled _ as e -> raise e
           | _exn -> ())
        | None -> ());
       (match entry.phase with
        | Keeper_state_machine.Crashed | Keeper_state_machine.Dead -> ()
        | _ ->
          if
            record_keeper_stopped
              entry
              ~base_path:entry.base_path
              ~keeper_name:entry.name
              ~detail:"manual stop"
          then
            Keeper_registry.cleanup_tracking ~base_path:entry.base_path entry.name))
    entries
;;

(** Stop all running keepers. Used in test cleanup to prevent orphaned
    keepalive loops from blocking process exit. *)
let stop_all_keepalives () =
  Keeper_registry.all ()
  |> List.iter (fun (entry : Keeper_registry.registry_entry) ->
       stop_keepalive entry.name)
;;
