(* keeper_turn_slot — admitted-turn holder diagnostics and compatibility helpers.

   Per-keeper isolation, fleet-wide capacity, and fleet stop policy live in
   [Keeper_turn_admission]. This module records holder rows only after
   admission grants a token. *)

open Keeper_types
open Keeper_meta_contract
open Keeper_types_profile

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

type throttle_source = Keeper_turn_admission.throttle_source =
  | Env_override
  | Toml
  | Default

let keeper_turn_throttle_limit = Keeper_turn_admission.keeper_turn_throttle_limit
let keeper_turn_throttle_source = Keeper_turn_admission.keeper_turn_throttle_source
let throttle_source_to_string = Keeper_turn_admission.throttle_source_to_string
let effective_turn_throttle_limit = Keeper_turn_admission.effective_turn_throttle_limit

(* Holder tracking — preserved for diagnostics. *)
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

let force_release_holder_records ~keeper_name =
  with_holder_lock (fun () ->
    let now = Time_compat.now () in
    purge_expired_force_released_holders_locked ~now;
    let table = Atomic.get holder_table_atomic in
    let matches =
      Holder_map.fold
        (fun key acquired_at acc ->
           if String.equal key.holder_keeper_name keeper_name
           then (key, now -. acquired_at) :: acc
           else acc)
        table
        []
    in
    let next_table =
      List.fold_left
        (fun acc (key, _) -> Holder_map.remove key acc)
        table
        matches
    in
    Atomic.set holder_table_atomic next_table;
    List.iter
      (fun (key, _) -> Hashtbl.replace force_released_holders key now)
      matches;
    matches
    |> List.map (fun (key, age) -> slot_pool_to_string key.holder_label, age)
    |> List.sort (fun (a, _) (b, _) -> String.compare a b))
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

let turn_slot_holders ~now = snapshot_holders ~label:Turn_pool ~now
let autonomous_slot_holders ~now = snapshot_holders ~label:Autonomous_pool ~now
let reactive_slot_holders ~now = snapshot_holders ~label:Reactive_pool ~now

let complete_force_release ~keeper_name released =
  match released with
  | [] -> []
  | _ :: _ ->
    (* See Keeper_turn_admission.force_release_keeper: holder labels are the
       caller-visible result; the bool only says whether a token was active. *)
    let (_token_was_active : bool) =
      Keeper_turn_admission.force_release_keeper ~keeper_name
    in
    released
;;

let force_release_stale_holder ~keeper_name =
  complete_force_release ~keeper_name (force_release_holder_records ~keeper_name)
  |> List.map fst
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

(* Semaphore wait timeout — preserved for backward compat. *)
let semaphore_wait_timeout_sec = Keeper_turn_admission.semaphore_wait_timeout_sec

let semaphore_wait_timeout_snapshot ~phase ?queue_ahead ?(holders = []) () =
  let global_available =
    Keeper_turn_admission.available_turns ~limit:effective_turn_throttle_limit
  in
  { timeout_wait_sec = semaphore_wait_timeout_sec
  ; timeout_phase = phase
  ; timeout_autonomous_available = global_available
  ; timeout_reactive_available = global_available
  ; timeout_turn_available = global_available
  ; timeout_queue_depth = 0
  ; timeout_queue_ahead = queue_ahead
  ; timeout_holders = holders
  }
;;

type keeper_turn_slot_state =
  { acquired_turn : bool ref
  ; turn_acquisition_id : int option ref
  ; channel_holder_label : slot_pool option
  ; channel_acquisition_id : int option ref
  ; admission_token : Keeper_turn_admission.token option ref
  }

type keeper_turn_slot_control =
  { is_held : unit -> bool
  }

let make_keeper_turn_slot_state ~channel_holder_label =
  { acquired_turn = ref false
  ; turn_acquisition_id = ref None
  ; channel_holder_label
  ; channel_acquisition_id = ref None
  ; admission_token = ref None
  }

let keeper_turn_slot_is_held state =
  match !(state.turn_acquisition_id) with
  | None -> !(state.acquired_turn)
  | Some acquisition_id ->
    let key =
      { holder_label = Turn_pool
      ; holder_keeper_name = ""
      ; holder_acquisition_id = acquisition_id
      }
    in
    let table = Atomic.get holder_table_atomic in
    Holder_map.exists
      (fun candidate _ ->
         candidate.holder_label = key.holder_label
         && candidate.holder_acquisition_id = key.holder_acquisition_id)
      table

let after_acquire_flag_hook_for_test
  : (label:string -> keeper_name:string -> unit) option ref
  =
  ref None

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

let safe_bookkeeping ~op f =
  try f () with
  | Eio.Cancel.Cancelled _ ->
    observe_bookkeeping_failure ~op ~kind:Keeper_bookkeeping_failure_kind.Cancelled;
    Log.Keeper.warn "release_keeper_turn_slot: %s skipped (Cancelled)" op
  | exn ->
    observe_bookkeeping_failure ~op ~kind:Keeper_bookkeeping_failure_kind.Exception;
    Log.Keeper.warn "release_keeper_turn_slot: %s exception: %s" op (Printexc.to_string exn)
;;

let release_recorded_holder ~keeper_name ~label ~acquisition_id =
  match acquisition_id with
  | None -> false
  | Some id ->
    let key = { holder_label = label; holder_keeper_name = keeper_name; holder_acquisition_id = id } in
    let was_force_released = ref false in
    (try
       let wfr = consume_force_release ~label ~keeper_name ~acquisition_id:id in
       was_force_released := wfr;
       if not wfr then
         Atomic.set holder_table_atomic
           (Holder_map.remove key (Atomic.get holder_table_atomic))
     with
     | Eio.Cancel.Cancelled _ ->
       observe_bookkeeping_failure ~op:"drop_holder" ~kind:Keeper_bookkeeping_failure_kind.Cancelled;
       Log.Keeper.warn "release_keeper_turn_slot: drop_holder skipped (Cancelled)"
     | exn ->
       observe_bookkeeping_failure ~op:"drop_holder" ~kind:Keeper_bookkeeping_failure_kind.Exception;
       Log.Keeper.warn "release_keeper_turn_slot: drop_holder exception: %s" (Printexc.to_string exn));
    !was_force_released
;;

let release_keeper_turn_slot_impl ~keeper_name state =
  let turn_was_force_released =
    release_recorded_holder
      ~keeper_name
      ~label:Turn_pool
      ~acquisition_id:!(state.turn_acquisition_id)
  in
  let channel_was_force_released =
    match state.channel_holder_label with
    | None -> false
    | Some label ->
      release_recorded_holder
        ~keeper_name
        ~label
        ~acquisition_id:!(state.channel_acquisition_id)
  in
  if not (turn_was_force_released || channel_was_force_released) then (
    match !(state.admission_token) with
    | None -> ()
    | Some token ->
      Keeper_turn_admission.release_turn token;
      state.admission_token := None)
;;

let release_keeper_turn_slot ~keeper_name state =
  if !(state.acquired_turn) then (
    state.acquired_turn := false;
    release_keeper_turn_slot_impl ~keeper_name state)
;;

let release_keeper_turn_slot_for_retry ~keeper_name state =
  release_keeper_turn_slot ~keeper_name state
;;

let force_release_holder_for ~keeper_name =
  complete_force_release ~keeper_name (force_release_holder_records ~keeper_name)
;;

let autonomous_completion_for_test_mutex = Eio.Mutex.create ()
let autonomous_completion_for_test : (string, float) Hashtbl.t = Hashtbl.create 16

let reset_autonomous_completion_for_test () =
  Eio.Mutex.use_rw ~protect:true autonomous_completion_for_test_mutex (fun () ->
    Hashtbl.reset autonomous_completion_for_test)
;;

let record_autonomous_completion_at_for_test ~keeper_name ~ts =
  Eio.Mutex.use_rw ~protect:true autonomous_completion_for_test_mutex (fun () ->
    Hashtbl.replace autonomous_completion_for_test keeper_name ts)
;;

let autonomous_queue_for_test_mutex = Eio.Mutex.create ()
let autonomous_queue_for_test : (int * string) list ref = ref []
let autonomous_queue_next_ticket_for_test = ref 0

let with_autonomous_queue_for_test f =
  Eio.Mutex.use_rw ~protect:true autonomous_queue_for_test_mutex f
;;

(* Provider timeout strikes — preserved. *)
let provider_timeout_strike_limit = 3

type provider_timeout_strike_outcome =
  | Provider_timeout_warn
  | Provider_timeout_soft_backoff

let classify_provider_timeout_strike ~strikes =
  if strikes >= provider_timeout_strike_limit then Provider_timeout_soft_backoff
  else Provider_timeout_warn
;;

let budget_exhaustions_mutex = Stdlib.Mutex.create ()
let budget_exhaustions : (string, int) Hashtbl.t = Hashtbl.create 16

let update_budget_exhaustions f =
  Stdlib.Mutex.lock budget_exhaustions_mutex;
  Fun.protect
    ~finally:(fun () -> Stdlib.Mutex.unlock budget_exhaustions_mutex)
    f
;;

let bump_budget_exhaustion_seeded ~keeper_name ~prior_strikes =
  update_budget_exhaustions (fun () ->
    (* DET-OK: budget_exhaustions is advisory; absence = 0 strikes (no exhaustion recorded) *)
    let current = Option.value ~default:0 (Hashtbl.find_opt budget_exhaustions keeper_name) in
    let next = max current prior_strikes + 1 in
    Hashtbl.replace budget_exhaustions keeper_name next;
    next)
;;

let bump_budget_exhaustion ~keeper_name =
  bump_budget_exhaustion_seeded ~keeper_name ~prior_strikes:0
;;

let reset_budget_exhaustion ~keeper_name =
  update_budget_exhaustions (fun () ->
    Hashtbl.remove budget_exhaustions keeper_name)
;;

let peek_budget_exhaustion_for_test ~keeper_name =
  update_budget_exhaustions (fun () ->
    (* DET-OK: budget_exhaustions is advisory; absence = 0 strikes (no exhaustion recorded) *)
    Option.value ~default:0 (Hashtbl.find_opt budget_exhaustions keeper_name))
;;

let set_budget_exhaustion_for_test ~keeper_name ~strikes =
  update_budget_exhaustions (fun () ->
    Hashtbl.replace budget_exhaustions keeper_name strikes)
;;

(* Semaphore wait metrics — preserved. *)
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

let channel_holder_label = function
  | Keeper_world_observation.Reactive -> Some Reactive_pool
  | Keeper_world_observation.Scheduled_autonomous -> Some Autonomous_pool
;;

let remaining_global_capacity () =
  Keeper_turn_admission.available_turns ~limit:effective_turn_throttle_limit
;;

let run_with_acquired_slot
      ~runtime_profile
      ~keeper_name
      ~channel
      ~channel_label
      ~admission_token
      ~started_at
      f
  =
  let slot_state =
    make_keeper_turn_slot_state ~channel_holder_label:(channel_holder_label channel)
  in
  slot_state.acquired_turn := true;
  slot_state.admission_token := Some admission_token;
  let cleanup () = release_keeper_turn_slot ~keeper_name slot_state in
  let body () =
    run_after_acquire_flag_hook_for_test
      ~label:(slot_pool_to_string Turn_pool)
      ~keeper_name;
    let acquired_at = Time_compat.now () in
    let turn_acquisition_id =
      record_holder ~label:Turn_pool ~keeper_name ~acquired_at
    in
    slot_state.turn_acquisition_id := Some turn_acquisition_id;
    (match slot_state.channel_holder_label with
     | None -> ()
     | Some label ->
       run_after_acquire_flag_hook_for_test
         ~label:(slot_pool_to_string label)
         ~keeper_name;
       let acquisition_id = record_holder ~label ~keeper_name ~acquired_at in
       slot_state.channel_acquisition_id := Some acquisition_id);
    let semaphore_wait_sec = Time_compat.now () -. started_at in
    observe_semaphore_wait_seconds
      ~keeper_name
      ~runtime_profile
      ~channel:channel_label
      semaphore_wait_sec;
    let semaphore_wait_ms =
      int_of_float
        ((if semaphore_wait_sec < 0.0 then 0.0 else semaphore_wait_sec) *. 1000.0)
    in
    let slot_control =
      { is_held = (fun () -> keeper_turn_slot_is_held slot_state) }
    in
    Ok (f ~semaphore_wait_ms ~slot_control)
  in
  if Eio_guard.is_ready ()
  then
    Eio.Switch.run (fun turn_sw ->
      Eio.Switch.on_release turn_sw cleanup;
      Eio.Fiber.fork_daemon ~sw:turn_sw (fun () ->
        Eio.Promise.await (Keeper_turn_admission.token_cancel_p admission_token);
        Eio.Switch.fail turn_sw Keeper_turn_admission.Fleet_stopped_by_operator;
        `Stop_daemon);
      body ())
  else Fun.protect ~finally:cleanup body
;;

(* Main entry point: admission grants both fleet capacity and keeper isolation. *)
let with_keeper_turn_slot_control ?(runtime_profile = "unknown") ~keeper_name ~channel f =
  let channel_label = Keeper_world_observation.channel_to_string channel in
  let t0 = Time_compat.now () in
  match
    Keeper_turn_admission.acquire_turn
      ~limit:effective_turn_throttle_limit
      ~timeout_s:semaphore_wait_timeout_sec
      ~keeper_name
      ~runtime_profile
      ~channel:channel_label
      ()
  with
  | Ok (admission_token, _admission_wait_ms) ->
    run_with_acquired_slot
      ~runtime_profile
      ~keeper_name
      ~channel
      ~channel_label
      ~admission_token
      ~started_at:t0
      f
  | Error Keeper_turn_admission.Global_inflight_exceeded ->
    let holders = snapshot_holders ~label:Turn_pool ~now:t0 in
    Error
      (`Semaphore_wait_timeout
         (semaphore_wait_timeout_snapshot
            ~phase:Turn_slot
            ~holders
            ()))
  | Error (Keeper_turn_admission.Fleet_paused | Keeper_turn_admission.Fleet_stopped as rejection) ->
    Error (`Turn_admission_rejected rejection)
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

(* Test-only: expose global admission state. *)
let global_inflight_for_test () = Keeper_turn_admission.global_inflight ()
let global_turn_limit_for_test () = effective_turn_throttle_limit

(* Legacy pool-specific helpers now expose the shared global admission budget. *)
let turn_semaphore_value_for_test () = remaining_global_capacity ()
let autonomous_turn_semaphore_value_for_test () = remaining_global_capacity ()
let reactive_turn_semaphore_value_for_test () = remaining_global_capacity ()
let turn_concurrency_int_of_env_default_for_test name ~default ~min_v ~max_v =
  Keeper_turn_admission.turn_concurrency_int_of_env_default_for_test
    name
    ~default
    ~min_v
    ~max_v
;;

let reset_autonomous_turn_queue_for_test () =
  with_autonomous_queue_for_test (fun () ->
    autonomous_queue_for_test := [];
    autonomous_queue_next_ticket_for_test := 0)
;;

let autonomous_waiter_snapshot_for_test () =
  with_autonomous_queue_for_test (fun () ->
    List.map snd !autonomous_queue_for_test)
;;

let enqueue_autonomous_waiter_for_test ?runtime_id:_ keeper_name =
  with_autonomous_queue_for_test (fun () ->
    let ticket = !autonomous_queue_next_ticket_for_test in
    incr autonomous_queue_next_ticket_for_test;
    autonomous_queue_for_test := !autonomous_queue_for_test @ [ ticket, keeper_name ];
    ticket)
;;

let drop_autonomous_waiter_for_test ticket =
  with_autonomous_queue_for_test (fun () ->
    autonomous_queue_for_test
    := List.filter (fun (candidate, _) -> candidate <> ticket) !autonomous_queue_for_test)
;;

let autonomous_waiter_head_ticket_for_test ~runtime_id:_ =
  with_autonomous_queue_for_test (fun () ->
    match !autonomous_queue_for_test with
    | [] -> None
    | (ticket, _) :: _ -> Some ticket)
;;

let autonomous_wait_queue_depth_for_test () = 0
let wait_for_autonomous_queue_head_for_test
      ?runtime_id:_ ~keeper_name:_ ~ticket ~started_at ()
  =
  let queue_ahead =
    with_autonomous_queue_for_test (fun () ->
      let rec loop idx = function
        | [] -> None
        | (candidate, _) :: _ when candidate = ticket -> Some idx
        | _ :: rest -> loop (idx + 1) rest
      in
      loop 0 !autonomous_queue_for_test)
  in
  if Time_compat.now () -. started_at >= semaphore_wait_timeout_sec then
    Error
      (`Semaphore_wait_timeout
          (semaphore_wait_timeout_snapshot
             ~phase:Autonomous_queue_head
             ?queue_ahead
             ()))
  else
    match autonomous_waiter_head_ticket_for_test ~runtime_id:"test" with
    | Some head when head <> ticket -> Ok ()
    | _ -> Ok ()
;;

let autonomous_fairness_cooldown_sec_for_test = 5.0

let fairness_delay_sec_at ~now ~keeper_name =
  let last_completion =
    Eio.Mutex.use_rw ~protect:true autonomous_completion_for_test_mutex (fun () ->
      Hashtbl.find_opt autonomous_completion_for_test keeper_name)
  in
  match last_completion with
  | None -> 0.0
  | Some completed_at ->
    let others_waiting =
      with_autonomous_queue_for_test (fun () ->
        List.exists
          (fun (_, waiting_keeper) -> not (String.equal waiting_keeper keeper_name))
          !autonomous_queue_for_test)
    in
    if not others_waiting then 0.0
    else (
      let elapsed = now -. completed_at in
      let remaining = autonomous_fairness_cooldown_sec_for_test -. elapsed in
      if remaining <= 0.0 then 0.0 else remaining)
;;
