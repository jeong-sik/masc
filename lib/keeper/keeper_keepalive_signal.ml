(* keeper_keepalive_signal — gRPC client refs, FSM guard identity helpers,
   interruptible sleep, wakeup dispatch, board-reactive wakeup filtering,
   stage_timing type, event dispatch helpers.

   Extracted from keeper_keepalive.ml. *)

open Keeper_types
open Keeper_memory
open Keeper_execution

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

(* ── KeeperHeartbeat.tla spec-action runtime guards (Cycle 43) ────────

   Identity helpers carrying [@@fsm_guard] payloads that mirror the
   honest actions of [specs/keeper-state-machine/KeeperHeartbeat.tla].
   Each helper is wrapped at the call site by
   [Keeper_fsm_guard_runtime.wrap_unit], so an [Assert_failure] from a
   PPX-injected guard becomes a Prometheus counter increment by default
   (counter mode) and a re-raise when [MASC_FSM_GUARD_ASSERT=1]
   (assert mode for tests / CI). The bug-action [MissedWakeup] is
   intentionally NOT instrumented — it is the failure mode these guards
   are designed to detect, not to enforce. *)

(* Heartbeat turn lifecycle flag, mirroring KeeperHeartbeat.tla's
   [turn_state] in the {"idle", "running"} alphabet. Read inside
   identity helpers; written by the caller around [run_heartbeat_loop]
   and the dispatch sites. Single-fiber by construction — only the
   keeper's own heartbeat loop touches its [turn_running] ref. *)
let pre_turn_complete_heartbeat ~(turn_running : bool ref) = ignore turn_running
  [@@fsm_guard "!turn_running = true"]

let post_turn_complete_heartbeat ~(turn_running : bool ref) = ignore turn_running
  [@@fsm_guard "!turn_running = false"]

(* WakeupSignal: external code sets the wakeup atomic to TRUE. Spec
   says the post-condition is [wakeup_signaled = TRUE]. The OCaml
   [Atomic.set] is idempotent so the assert is trivially true on the
   honest path; the guard catches a regression where someone replaces
   [Atomic.set ... true] with [Atomic.set ... false] or forgets the
   set entirely. *)
let post_wakeup_signal ~(wakeup : bool Atomic.t) = ignore wakeup
  [@@fsm_guard "Atomic.get wakeup = true"]

(* SubmitTask (KeeperTaskAcquisition.tla, Cycle 44): an external
   producer (operator directive in this case) attaches a task_id to the
   keeper's [current_task_id]. The post-action invariant is that the
   meta carries the assigned id after [persist_directive_meta_update]
   returns. The honest path is trivially true; the guard catches a
   regression where someone updates [persist_directive_meta_update] to
   skip the [current_task_id] field or persist a different id. *)
let post_submit_task ~(meta : keeper_meta) ~(task_id : Keeper_id.Task_id.t) =
  ignore meta; ignore task_id
  [@@fsm_guard "meta.Keeper_types.current_task_id = Some task_id"]

(* HeartbeatTick: the [compare_and_set wakeup true false] in
   [interruptible_sleep] succeeded — wakeup transitioned TRUE -> FALSE
   and the sleep returned so the loop can dispatch. Spec post-condition
   is [wakeup_signaled = FALSE]. False-positive risk: a producer that
   re-sets the atomic to TRUE between the CAS and this read would make
   the guard fire. The [interruptible_sleep] body is single-fiber and
   the only producer is external, so the window is one tick and the
   counter signal is operationally meaningful — a non-zero count means
   producers are racing the consumer, which is itself a bug class. *)
let post_heartbeat_tick ~(wakeup : bool Atomic.t) = ignore wakeup
  [@@fsm_guard "Atomic.get wakeup = false"]

type sleep_outcome =
  | Stopped
  | Woken
  | Timeout

(** Sleep in short chunks so [stop_keepalive] or [wakeup_keeper] takes
    effect within ~chunk_sec instead of waiting for the full interval. *)
let interruptible_sleep ~clock ~stop ~wakeup duration : sleep_outcome =
  let chunk_sec = Env_config.KeeperKeepalive.sleep_chunk_sec in
  let rec wait remaining =
    if Atomic.get stop
    then Stopped
    else if (* Spec: KeeperHeartbeat.tla HeartbeatTick action — wakeup is
              consumed (TRUE -> FALSE) and the caller proceeds to dispatch.
              Returning [Woken] lets [run_smart_heartbeat_gate] honour
              the spec's [turn_state' = "running"] postcondition; without
              the discriminator the [Skip_idle] branch would consume the
              CAS and then skip the cycle (the [MissedWakeup] bug-action). *)
            Atomic.compare_and_set wakeup true false
    then (
      (* Cycle 43: post-action guard mirrors the spec's [wakeup_signaled =
         FALSE] postcondition. Counter-mode by default. *)
      Keeper_fsm_guard_runtime.wrap_unit
        ~action:"HeartbeatTick" ~stage:"post"
        (fun () -> post_heartbeat_tick ~wakeup);
      Woken)
    else if remaining <= 0.0
    then Timeout
    else (
      let chunk = Float.min chunk_sec remaining in
      Eio.Time.sleep clock chunk;
      wait (remaining -. chunk))
  in
  wait duration
;;

(** Wake up a specific keeper immediately, causing it to skip the rest of
    its sleep and run the next heartbeat cycle. Used by broadcast notification
    when a @mention targets a running keeper.

    When [?stimulus] is provided, the stimulus is appended to the keeper's
    Event Layer queue ([Keeper_registry.enqueue_event]) before the wakeup
    flag flips. This is RFC-0020 Rule 1 (enqueue is independent of policy)
    + the data-channel half of the layer split — [fiber_wakeup] remains the
    hint signal, the queue is the authoritative payload. *)
let wakeup_keeper ?base_path ?stimulus name =
  Keeper_registry.all ?base_path ()
  |> List.iter (fun (entry : Keeper_registry.registry_entry) ->
    if String.equal entry.name name && entry.phase = Keeper_state_machine.Running
    then begin
      Option.iter
        (fun s ->
          Keeper_registry.enqueue_event ~base_path:entry.base_path name s)
        stimulus;
      Keeper_registry.wakeup ~base_path:entry.base_path name
    end)
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

(* ── Board-reactive policy constants ── *)

let board_reactive_debounce_sec = Env_config.KeeperKeepalive.board_debounce_sec

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
    ignore (Keeper_registry.dispatch_event_and_log
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
    ignore (Keeper_registry.dispatch_event_with_audit_and_log
      ~base_path:ctx.config.base_path
      ~snapshot
      ~events_fired
      ~selected_event
      keeper_name
      event)
