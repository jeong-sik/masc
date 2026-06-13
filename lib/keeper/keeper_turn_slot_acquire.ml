(* keeper_turn_slot — semaphores, autonomous wait queue, budget-exhaustion strikes, and the main [with_keeper_turn_slot] gate.  Extracted from keeper_keepalive.ml to isolate concurrency-control logic ... *)

open Keeper_types
open Keeper_meta_contract
open Keeper_types_profile

(** The three semaphore pools that gate keeper turn admission. Closed sum type: adding a new pool requires updating every match site, which the compiler enforces exhaustively. *)
type slot_pool = Keeper_turn_slot_types.slot_pool =
  | Turn_pool
  | Autonomous_pool
  | Reactive_pool

let slot_pool_to_string = Keeper_turn_slot_types.slot_pool_to_string

exception Semaphore_wait_timeout = Keeper_turn_slot_types.Semaphore_wait_timeout

type semaphore_wait_phase = Keeper_turn_slot_types.semaphore_wait_phase =
  | Autonomous_queue_head
  | Autonomous_slot
  | Reactive_slot
  | Turn_slot

let semaphore_wait_phase_to_string =
  Keeper_turn_slot_types.semaphore_wait_phase_to_string

type semaphore_wait_timeout = Keeper_turn_slot_types.semaphore_wait_timeout =
  { timeout_wait_sec : float
  ; timeout_phase : semaphore_wait_phase
  ; timeout_autonomous_available : int
  ; timeout_reactive_available : int
  ; timeout_turn_available : int
  ; timeout_queue_depth : int
  ; timeout_queue_ahead : int option
  ; timeout_holders : (string * float) list
  }

let int_of_env_default = Keeper_turn_slot_types.int_of_env_default

(* Global turn slot cap across autonomous + reactive pools.  Sized for the observed 14-keeper fleet plus burst headroom. Operators running larger fleets raise [MASC_KEEPER_AUTOBOOT_MAX] explicitly; th... *)

(** Which configuration layer supplied the effective throttle limit. Used by operator surfaces to warn when an env override silently differs from the operator's TOML intent (issue #17192). *)
type throttle_source =
  | Env_override
  | Toml
  | Default

let keeper_turn_throttle_limit, keeper_turn_throttle_source =
  let env_name = "MASC_KEEPER_AUTOBOOT_MAX" in
  let default = 32 in
  let min_v = 1 in
  let max_v = max_int in
  let parse raw =
    let v = Option.value ~default (int_of_string_opt (String.trim raw)) in
    Keeper_config.clamp_int v ~min_v ~max_v
  in
  if Env_config_core.running_under_test_executable () then
    (default, Default)
  else
    match Sys.getenv_opt env_name with
    | Some raw when String.trim raw <> "" -> parse raw, Env_override
    | _ -> (
      match Env_config_core.raw_value_opt env_name with
      | Some raw when String.trim raw <> "" -> parse raw, Toml
      | _ -> default, Default)
;;
let throttle_source_to_string = function
  | Env_override -> "env_override"
  | Toml -> "toml"
  | Default -> "default"
;;

(** Hard cap applied when the env override exceeds 2x the TOML baseline. Prevents accidental fleet overload from a typo or stale env var. Only applies when the source is [Env_override] and a TOML value... *)
let effective_turn_throttle_limit =
  match keeper_turn_throttle_source with
  | Env_override -> (
    match Keeper_runtime_config.toml_value_opt "MASC_KEEPER_AUTOBOOT_MAX" with
    | Some toml_raw -> (
      match int_of_string_opt (String.trim toml_raw) with
      | Some toml_val when toml_val > 0 ->
        let hard_cap = toml_val * 2 in
        if keeper_turn_throttle_limit > hard_cap
        then hard_cap
        else keeper_turn_throttle_limit
      | _ -> keeper_turn_throttle_limit)
    | None -> keeper_turn_throttle_limit)
  | Toml | Default -> keeper_turn_throttle_limit

(** Warn when the env override significantly exceeds the operator's TOML intent.  Factor >= 2 is the threshold: a fleet sized for N keepers that silently runs at 2N+ is the overload pattern reported in... *)
let check_throttle_divergence () =
  if Env_config_core.running_under_test_executable () then
    ()
  else
    match keeper_turn_throttle_source with
    | Env_override -> (
      match Keeper_runtime_config.toml_value_opt "MASC_KEEPER_AUTOBOOT_MAX" with
      | None ->
        Log.Keeper.info
          "autoboot: env MASC_KEEPER_AUTOBOOT_MAX=%d (no TOML override, effective=%d)"
          keeper_turn_throttle_limit
          effective_turn_throttle_limit
      | Some toml_raw -> (
        match int_of_string_opt (String.trim toml_raw) with
        | None -> ()
        | Some toml_val when toml_val <= 0 -> ()
        | Some toml_val ->
          let env_val = keeper_turn_throttle_limit in
          let factor = float_of_int env_val /. float_of_int toml_val in
          if effective_turn_throttle_limit < env_val
          then
            Log.Keeper.warn
              "autoboot divergence: env MASC_KEEPER_AUTOBOOT_MAX=%d capped to %d (2x \
               TOML baseline %d, factor %.1fx); fleet overload prevented."
              env_val
              effective_turn_throttle_limit
              toml_val
              factor
          else if factor >= 2.0
          then
            Log.Keeper.warn
              "autoboot divergence: env MASC_KEEPER_AUTOBOOT_MAX=%d is %.1fx the TOML \
               value (%d); fleet may be overloaded. Either unset the env var to honour \
               TOML, or update TOML to match the intended cap."
              env_val
              factor
              toml_val
          else if env_val > toml_val
          then
            Log.Keeper.info
              "autoboot divergence: env MASC_KEEPER_AUTOBOOT_MAX=%d exceeds TOML (%d) \
               by a smaller margin (factor %.1fx); monitor fleet capacity."
              env_val
              toml_val
              factor))
    | Toml | Default -> ()
;;
let () = check_throttle_divergence ()
let turn_semaphore = Eio.Semaphore.make effective_turn_throttle_limit

(* 2026-05-05 fleet-stuck diagnosis: when a peer holds the semaphore for 60+ seconds the wait timeout WARN says "peers holding slot" but never names *which* peer.  Operators are then blind to which ke... *)
type holder_key =
  { holder_label : slot_pool
  ; holder_keeper_name : string
  ; holder_acquisition_id : int
  }

module Holder_key = struct
  type t = holder_key
  let compare = Stdlib.compare
end

module Holder_map = Map.Make (Holder_key)

(** Active-holder table.  Tier-A perf change: previously [(holder_key, float) Hashtbl.t] behind [holder_mutex] for both reads and writes.  [snapshot_holders] is a hot read path — every acquire / releas... *)
let holder_table_atomic : float Holder_map.t Atomic.t =
  Atomic.make Holder_map.empty

let force_released_holders : (holder_key, float) Hashtbl.t = Hashtbl.create 32
let next_holder_acquisition_id = ref 0
let holder_mutex = Eio.Mutex.create ()
let force_release_marker_ttl_sec = Masc_time_constants.hour
let with_holder_lock f = Eio.Mutex.use_rw ~protect:true holder_mutex f
let purge_expired_force_released_holders_locked ~now =
  Hashtbl.filter_map_inplace
    (fun _ marked_at ->
       if now -. marked_at > force_release_marker_ttl_sec then None else Some marked_at)
    force_released_holders
;;
let force_released_marker_ttl_sec_for_test = force_release_marker_ttl_sec
let force_released_marker_count_for_test () =
  with_holder_lock (fun () -> Hashtbl.length force_released_holders)
;;
let add_force_released_marker_for_test ~label ~keeper_name ~acquisition_id ~marked_at =
  with_holder_lock (fun () ->
    Hashtbl.replace
      force_released_holders
      { holder_label = label
      ; holder_keeper_name = keeper_name
      ; holder_acquisition_id = acquisition_id
      }
      marked_at)
;;
let purge_force_released_markers_for_test ~now =
  with_holder_lock (fun () -> purge_expired_force_released_holders_locked ~now)
;;
let clear_force_released_markers_for_test () =
  with_holder_lock (fun () -> Hashtbl.reset force_released_holders)
;;
let record_holder ~label ~keeper_name ~acquired_at =
  with_holder_lock (fun () ->
    incr next_holder_acquisition_id;
    let acquisition_id = !next_holder_acquisition_id in
    let key =
      { holder_label = label
      ; holder_keeper_name = keeper_name
      ; holder_acquisition_id = acquisition_id
      }
    in
    Atomic.set holder_table_atomic
      (Holder_map.add key acquired_at (Atomic.get holder_table_atomic));
    acquisition_id)
;;
let mark_holder_force_released ~label ~keeper_name =
  with_holder_lock (fun () ->
    let now = Time_compat.now () in
    purge_expired_force_released_holders_locked ~now;
    let table = Atomic.get holder_table_atomic in
    let keys =
      Holder_map.fold
        (fun key _ acc ->
           if key.holder_label = label && String.equal key.holder_keeper_name keeper_name
           then key :: acc
           else acc)
        table
        []
    in
    let next_table =
      List.fold_left
        (fun acc key -> Holder_map.remove key acc)
        table
        keys
    in
    Atomic.set holder_table_atomic next_table;
    List.iter
      (fun key -> Hashtbl.replace force_released_holders key now)
      keys;
    List.length keys)
;;
let consume_force_release ~label ~keeper_name ~acquisition_id =
  with_holder_lock (fun () ->
    let key =
      { holder_label = label
      ; holder_keeper_name = keeper_name
      ; holder_acquisition_id = acquisition_id
      }
    in
    match Hashtbl.find_opt force_released_holders key with
    | Some _ ->
      Hashtbl.remove force_released_holders key;
      true
    | None ->
      Atomic.set holder_table_atomic
        (Holder_map.remove key (Atomic.get holder_table_atomic));
      false)
;;

(** [snapshot_holders ~label ~now] returns [(keeper_name, held_for_sec)] pairs for the given [label] sorted by descending hold time.  Used by [acquire_bounded] to attribute timeouts to the longest-held... *)
let snapshot_holders ~label ~now =
  let table = Atomic.get holder_table_atomic in
  Holder_map.fold
    (fun key ts acc ->
       if key.holder_label = label
       then (key.holder_keeper_name, now -. ts) :: acc
       else acc)
    table
    []
  |> List.sort (fun (_, a) (_, b) -> compare b a)
;;

(* Autonomous turn concurrency. Reactive turns use a separate pool so explicit mentions / board events stay responsive even when scheduled turns saturate.  Provider rate limits (and any future cost ca... *)
let turn_concurrency_env_opt name =
  if Env_config_core.running_under_test_executable ()
  then None
  else Env_config_core.raw_value_opt name
;;
let turn_concurrency_int_of_env_default name ~default ~min_v ~max_v =
  match turn_concurrency_env_opt name with
  | None -> default
  | Some raw ->
    let v = Option.value ~default (int_of_string_opt (String.trim raw)) in
    max min_v (min max_v v)
;;
let turn_concurrency_int_of_env_default_for_test = turn_concurrency_int_of_env_default
let autonomous_turn_limit =
  turn_concurrency_int_of_env_default
    "MASC_KEEPER_AUTONOMOUS_CONCURRENCY"
    ~default:16
    ~min_v:1
    ~max_v:max_int
;;
let () =
  Log.Keeper.info
    "autonomous_turn_concurrency=%d (env=%s)"
    autonomous_turn_limit
    (Option.value
       ~default:"<unset>"
       (turn_concurrency_env_opt "MASC_KEEPER_AUTONOMOUS_CONCURRENCY"))
;;
let autonomous_turn_semaphore = Eio.Semaphore.make autonomous_turn_limit
let reactive_turn_limit =
  turn_concurrency_int_of_env_default
    "MASC_KEEPER_REACTIVE_CONCURRENCY"
    ~default:16
    ~min_v:1
    ~max_v:max_int
;;
let () =
  Log.Keeper.info
    "reactive_turn_concurrency=%d (env=%s)"
    reactive_turn_limit
    (Option.value
       ~default:"<unset>"
       (turn_concurrency_env_opt "MASC_KEEPER_REACTIVE_CONCURRENCY"))
;;
let reactive_turn_semaphore = Eio.Semaphore.make reactive_turn_limit
let turn_semaphore_value_for_test () = Eio.Semaphore.get_value turn_semaphore
let autonomous_turn_semaphore_value_for_test () =
  Eio.Semaphore.get_value autonomous_turn_semaphore
;;
let reactive_turn_semaphore_value_for_test () =
  Eio.Semaphore.get_value reactive_turn_semaphore
;;
let turn_slot_holders ~now = snapshot_holders ~label:Turn_pool ~now
let autonomous_slot_holders ~now = snapshot_holders ~label:Autonomous_pool ~now
let reactive_slot_holders ~now = snapshot_holders ~label:Reactive_pool ~now
let force_release_stale_holder ~keeper_name =
  let released = ref [] in
  let release_if_held ~label sem =
    let release_count = mark_holder_force_released ~label ~keeper_name in
    for _ = 1 to release_count do
      Eio.Semaphore.release sem;
      released := slot_pool_to_string label :: !released
    done
  in
  release_if_held ~label:Turn_pool turn_semaphore;
  release_if_held ~label:Autonomous_pool autonomous_turn_semaphore;
  release_if_held ~label:Reactive_pool reactive_turn_semaphore;
  List.rev !released
;;
let format_slot_holders ?(limit = 5) holders =
  let limit = max 1 limit in
  let rec take n = function
    | [] -> []
    | _ when n <= 0 -> []
    | x :: xs -> x :: take (n - 1) xs
  in
  match holders with
  | [] -> "[]"
  | _ ->
    let shown = take limit holders in
    let rendered =
      List.map
        (fun (name, held_for_sec) ->
           Printf.sprintf "%s/%.0fs" name (max 0.0 held_for_sec))
        shown
    in
    let extra = List.length holders - List.length shown in
    let items =
      if extra > 0 then rendered @ [ Printf.sprintf "+%d more" extra ] else rendered
    in
    "[" ^ String.concat ", " items ^ "]"
;;

(** [snapshot_all_holders ~now] reads every pool from a single [Atomic.get] of [holder_table_atomic] and returns the three lists consistent with that snapshot.  Previously held [holder_mutex] for the w... *)
let snapshot_all_holders ~now =
  let table = Atomic.get holder_table_atomic in
  Holder_map.fold
    (fun key ts (turn, auto, reactive) ->
       let held = now -. ts in
       match key.holder_label with
       | Turn_pool -> (key.holder_keeper_name, held) :: turn, auto, reactive
       | Autonomous_pool -> turn, (key.holder_keeper_name, held) :: auto, reactive
       | Reactive_pool -> turn, auto, (key.holder_keeper_name, held) :: reactive)
    table
    ([], [], [])
  |> fun (t, a, r) ->
  let by_held = List.sort (fun (_, x) (_, y) -> compare y x) in
  by_held t, by_held a, by_held r
;;
let slot_holders_summary ?(limit = 5) ~now () =
  let turn, autonomous, reactive = snapshot_all_holders ~now in
  Printf.sprintf
    "turn_holders=%s autonomous_holders=%s reactive_holders=%s"
    (format_slot_holders ~limit turn)
    (format_slot_holders ~limit autonomous)
    (format_slot_holders ~limit reactive)
;;
type autonomous_waiter =
  { ticket : int
  ; keeper_name : string
  }

(* Eio.Mutex: queue operations are pure/non-yielding. Stdlib.Mutex is PTHREAD_MUTEX_ERRORCHECK on OCaml 5 and raises "Resource deadlock avoided" whenever two Eio fibers on the same OS thread contend, ... *)
let autonomous_wait_queue_mutex = Eio.Mutex.create ()

(* FIFO waiters use an append-only queue plus an active-ticket table. Removing a middle waiter only tombstones its ticket; the physical queue is pruned lazily from the head. This keeps enqueue/drop O(... *)
let autonomous_wait_queue : autonomous_waiter Queue.t = Queue.create ()
let autonomous_wait_queue_active_tickets : (int, unit) Hashtbl.t = Hashtbl.create 32
let autonomous_wait_queue_active_count = ref 0
let autonomous_wait_queue_next_ticket = ref 0

(* Routed through Env_config_keeper so operators can tune cadence without a rebuild (same fragmentation class as the watchdog thresholds extracted in #10740). The value is read once at module load — r... *)
let autonomous_queue_poll_sec =
  Env_config_keeper.KeeperPollIntervals.autonomous_queue_poll_sec
;;
let with_autonomous_wait_queue f =
  Eio.Mutex.use_rw ~protect:true autonomous_wait_queue_mutex f
;;
let autonomous_queue_depth_labels = [ "channel", "autonomous_queue" ]
let record_autonomous_queue_depth depth =
  Otel_metric_store.set_gauge
    Keeper_metrics.(to_string TurnQueueDepth)
    ~labels:autonomous_queue_depth_labels
    (float_of_int depth)
;;
let autonomous_queue_peek_opt () =
  try Some (Queue.peek autonomous_wait_queue) with
  | Queue.Empty -> None
;;
let prune_autonomous_wait_queue_locked () =
  let rec loop () =
    match autonomous_queue_peek_opt () with
    | None -> ()
    | Some waiter ->
      if Hashtbl.mem autonomous_wait_queue_active_tickets waiter.ticket
      then ()
      else (
        (* fire-and-forget: drain queue element *)
        ignore (Queue.take autonomous_wait_queue);
        loop ())
  in
  loop ()
;;
let active_autonomous_waiters_locked () =
  prune_autonomous_wait_queue_locked ();
  let active = ref [] in
  Queue.iter
    (fun waiter ->
       if Hashtbl.mem autonomous_wait_queue_active_tickets waiter.ticket
       then active := waiter :: !active)
    autonomous_wait_queue;
  List.rev !active
;;
let autonomous_wait_queue_depth () =
  with_autonomous_wait_queue (fun () ->
    prune_autonomous_wait_queue_locked ();
    !autonomous_wait_queue_active_count)
;;
let reset_autonomous_turn_queue_for_test () =
  with_autonomous_wait_queue (fun () ->
    Queue.clear autonomous_wait_queue;
    Hashtbl.reset autonomous_wait_queue_active_tickets;
    autonomous_wait_queue_active_count := 0;
    autonomous_wait_queue_next_ticket := 0;
    record_autonomous_queue_depth 0)
;;
let enqueue_autonomous_waiter ~(keeper_name : string) : int =
  with_autonomous_wait_queue (fun () ->
    let ticket = !autonomous_wait_queue_next_ticket in
    incr autonomous_wait_queue_next_ticket;
    Queue.add { ticket; keeper_name } autonomous_wait_queue;
    Hashtbl.replace autonomous_wait_queue_active_tickets ticket ();
    incr autonomous_wait_queue_active_count;
    record_autonomous_queue_depth !autonomous_wait_queue_active_count;
    ticket)
;;
let drop_autonomous_waiter ~(ticket : int) : unit =
  with_autonomous_wait_queue (fun () ->
    if Hashtbl.mem autonomous_wait_queue_active_tickets ticket
    then (
      Hashtbl.remove autonomous_wait_queue_active_tickets ticket;
      decr autonomous_wait_queue_active_count);
    prune_autonomous_wait_queue_locked ();
    record_autonomous_queue_depth !autonomous_wait_queue_active_count)
;;
let autonomous_waiter_snapshot_for_test () : string list =
  with_autonomous_wait_queue (fun () ->
    List.map (fun waiter -> waiter.keeper_name) (active_autonomous_waiters_locked ()))
;;
let enqueue_autonomous_waiter_for_test keeper_name =
  enqueue_autonomous_waiter ~keeper_name
;;
let drop_autonomous_waiter_for_test ticket = drop_autonomous_waiter ~ticket
let autonomous_waiter_head_ticket () : int option =
  with_autonomous_wait_queue (fun () ->
    prune_autonomous_wait_queue_locked ();
    match autonomous_queue_peek_opt () with
    | Some head -> Some head.ticket
    | None -> None)
;;
let autonomous_waiter_position ~(ticket : int) : int option =
  with_autonomous_wait_queue (fun () ->
    prune_autonomous_wait_queue_locked ();
    let position = ref None in
    let idx = ref 0 in
    Queue.iter
      (fun waiter ->
         if
           Option.is_none !position
           && Hashtbl.mem autonomous_wait_queue_active_tickets waiter.ticket
         then if waiter.ticket = ticket then position := Some !idx else incr idx)
      autonomous_wait_queue;
    !position)
;;

(** Wall-clock cap on [Eio.Semaphore.acquire] when waiting for a keeper turn slot. Without this, a keeper whose peers hold all slots while their LLM calls stall for the entire 1200s turn budget would b... *)
let semaphore_wait_timeout_sec =
  Keeper_config.float_of_env_default
    "MASC_KEEPER_SEMAPHORE_WAIT_TIMEOUT_SEC"
    ~default:180.0
    ~min_v:5.0
    ~max_v:Float.max_float
;;
let semaphore_wait_timeout_snapshot ~phase ?queue_ahead ?(holders = []) ()
  : semaphore_wait_timeout
  =
  { timeout_wait_sec = semaphore_wait_timeout_sec
  ; timeout_phase = phase
  ; timeout_autonomous_available = Eio.Semaphore.get_value autonomous_turn_semaphore
  ; timeout_reactive_available = Eio.Semaphore.get_value reactive_turn_semaphore
  ; timeout_turn_available = Eio.Semaphore.get_value turn_semaphore
  ; timeout_queue_depth = autonomous_wait_queue_depth ()
  ; timeout_queue_ahead = queue_ahead
  ; timeout_holders = holders
  }
;;

(** Per-keeper record of the last autonomous turn completion timestamp. Used by the fairness cooldown to prevent a fast-cycling keeper from monopolizing the autonomous slot when peers are waiting.  Clo... *)
let last_autonomous_completion : (string, float) Hashtbl.t = Hashtbl.create 16

(* Eio.Mutex: completion table is accessed from keeper Eio fibers in the same domain. The previous "different domains concurrently" comment was speculative — every actual caller (record_turn_start pat... *)
let last_autonomous_completion_mutex = Eio.Mutex.create ()
let with_completion_table f =
  Eio.Mutex.use_rw ~protect:true last_autonomous_completion_mutex f
;;
let record_autonomous_completion ~(keeper_name : string) : unit =
  with_completion_table (fun () ->
    Hashtbl.replace last_autonomous_completion keeper_name (Time_compat.now ()))
;;
type keeper_turn_slot_state =
  { acquired_autonomous : bool ref
  ; acquired_reactive : bool ref
  ; acquired_turn : bool ref
  ; autonomous_acquisition_id : int option ref
  ; reactive_acquisition_id : int option ref
  ; turn_acquisition_id : int option ref
  ; autonomous_ticket : int option ref
  }

type keeper_turn_slot_control =
  { release_for_retry : unit -> unit
  ; reacquire_after_retry :
      unit -> (int, [ `Semaphore_wait_timeout of semaphore_wait_timeout ]) result
  }

let make_keeper_turn_slot_state () =
  { acquired_autonomous = ref false
  ; acquired_reactive = ref false
  ; acquired_turn = ref false
  ; autonomous_acquisition_id = ref None
  ; reactive_acquisition_id = ref None
  ; turn_acquisition_id = ref None
  ; autonomous_ticket = ref None
  }
;;
let keeper_turn_slot_is_held state =
  !(state.acquired_autonomous)
  || !(state.acquired_reactive)
  || !(state.acquired_turn)
  || Option.is_some !(state.autonomous_ticket)
;;
let after_acquire_flag_hook_for_test
  : (label:string -> keeper_name:string -> unit) option ref
  =
  ref None
;;
let set_after_acquire_flag_hook_for_test hook = after_acquire_flag_hook_for_test := hook
let run_after_acquire_flag_hook_for_test ~label ~keeper_name =
  match !after_acquire_flag_hook_for_test with
  | None -> ()
  | Some hook -> hook ~label ~keeper_name
;;
let observe_bookkeeping_failure ~op ~(kind : Keeper_bookkeeping_failure_kind.t) =
  Otel_metric_store.inc_counter
    Keeper_metrics.(to_string TurnSlotBookkeepingFailures)
    ~labels:[ "op", op; "kind", Keeper_bookkeeping_failure_kind.to_label kind ]
    ()
;;

(* Cancel-safe wrapper for bookkeeping calls that touch [Eio.Mutex.use_rw]. Reached from [Fun.protect ~finally] in [with_keeper_turn_slot] when the keeper fiber is being cancelled.  If a mutex acquisi... *)
let safe_bookkeeping ~op f =
  try f () with
  | Eio.Cancel.Cancelled _ ->
(* Bookkeeping (holder table / waiter queue / completion stamp) is advisory and self-healing; skipping under fiber cancellation is acceptable.  The semaphore release that follows must still run. *)
    observe_bookkeeping_failure ~op ~kind:Keeper_bookkeeping_failure_kind.Cancelled;
    Log.Keeper.warn "release_keeper_turn_slot: %s skipped (Cancelled)" op
  | exn ->
    observe_bookkeeping_failure ~op ~kind:Keeper_bookkeeping_failure_kind.Exception;
    Log.Keeper.warn "release_keeper_turn_slot: %s failed: %s" op (Printexc.to_string exn)
;;

