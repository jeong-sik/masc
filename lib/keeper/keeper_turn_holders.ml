(* keeper_turn_holders — in-turn holder diagnostics.

   Keeper turn execution no longer enters a keeper-owned runtime gate. This
   module only records holder rows while a keeper turn body is
   executing. *)

open Keeper_types
open Keeper_meta_contract
open Keeper_types_profile

type holder_pool =
  | Turn_holder
  | Autonomous_holder
  | Reactive_holder

let holder_pool_to_string = function
  | Turn_holder -> "turn"
  | Autonomous_holder -> "autonomous"
  | Reactive_holder -> "reactive"

(* Holder tracking — preserved for diagnostics. *)
type holder_key =
  { holder_label : holder_pool
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
    |> List.map (fun (key, age) -> holder_pool_to_string key.holder_label, age)
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

let turn_holders ~now = snapshot_holders ~label:Turn_holder ~now
let autonomous_holders ~now = snapshot_holders ~label:Autonomous_holder ~now
let reactive_holders ~now = snapshot_holders ~label:Reactive_holder ~now

let complete_force_release ~keeper_name released =
  match released with
  | [] -> []
  | _ :: _ -> released
;;

let force_release_stale_holder ~keeper_name =
  complete_force_release ~keeper_name (force_release_holder_records ~keeper_name)
  |> List.map fst
;;

let format_holders ?(limit = 5) holders =
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
       | Turn_holder -> (key.holder_keeper_name, held) :: turn, auto, reactive
       | Autonomous_holder -> turn, (key.holder_keeper_name, held) :: auto, reactive
       | Reactive_holder -> turn, auto, (key.holder_keeper_name, held) :: reactive)
    table
    ([], [], [])
  |> fun (t, a, r) ->
  let by_held = List.sort (fun (_, x) (_, y) -> compare y x) in
  by_held t, by_held a, by_held r
;;

let holders_summary ?(limit = 5) ~now () =
  let turn, autonomous, reactive = snapshot_all_holders ~now in
  Printf.sprintf
    "turn_holders=%s autonomous_holders=%s reactive_holders=%s"
    (format_holders ~limit turn)
    (format_holders ~limit autonomous)
    (format_holders ~limit reactive)
;;

type turn_holder_state =
  { acquired_turn : bool ref
  ; turn_acquisition_id : int option ref
  ; channel_holder_label : holder_pool option
  ; channel_acquisition_id : int option ref
  }

type turn_holder_control =
  { is_held : unit -> bool
  }

let make_turn_holder_state ~channel_holder_label =
  { acquired_turn = ref false
  ; turn_acquisition_id = ref None
  ; channel_holder_label
  ; channel_acquisition_id = ref None
  }

let turn_holder_is_held state =
  match !(state.turn_acquisition_id) with
  | None -> !(state.acquired_turn)
  | Some acquisition_id ->
    let key =
      { holder_label = Turn_holder
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
    Keeper_metrics.(to_string TurnHolderBookkeepingFailures)
    ~labels:[ "op", op; "kind", Keeper_bookkeeping_failure_kind.to_label kind ]
    ()
;;

let safe_bookkeeping ~op f =
  try f () with
  | Eio.Cancel.Cancelled _ ->
    observe_bookkeeping_failure ~op ~kind:Keeper_bookkeeping_failure_kind.Cancelled;
    Log.Keeper.warn "release_turn_holder: %s skipped (Cancelled)" op
  | exn ->
    observe_bookkeeping_failure ~op ~kind:Keeper_bookkeeping_failure_kind.Exception;
    Log.Keeper.warn "release_turn_holder: %s exception: %s" op (Printexc.to_string exn)
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
       Log.Keeper.warn "release_turn_holder: drop_holder skipped (Cancelled)"
     | exn ->
       observe_bookkeeping_failure ~op:"drop_holder" ~kind:Keeper_bookkeeping_failure_kind.Exception;
       Log.Keeper.warn "release_turn_holder: drop_holder exception: %s" (Printexc.to_string exn));
    !was_force_released
;;

let release_turn_holder_impl ~keeper_name state =
  let turn_was_force_released =
    release_recorded_holder
      ~keeper_name
      ~label:Turn_holder
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
  (* See release_recorded_holder: force-release state is logged and only needs cleanup here. *)
  ignore (turn_was_force_released || channel_was_force_released : bool)
;;

let release_turn_holder ~keeper_name state =
  if !(state.acquired_turn) then (
    state.acquired_turn := false;
    release_turn_holder_impl ~keeper_name state)
;;

let release_turn_holder_for_retry ~keeper_name state =
  release_turn_holder ~keeper_name state
;;

let force_release_holder_for ~keeper_name =
  complete_force_release ~keeper_name (force_release_holder_records ~keeper_name)
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

let channel_holder_label = function
  | Keeper_world_observation.Reactive -> Some Reactive_holder
  | Keeper_world_observation.Scheduled_autonomous -> Some Autonomous_holder
;;

let run_with_recorded_holder
      ~keeper_name
      ~channel
      ~started_at
      f
  =
  let holder_state =
    make_turn_holder_state ~channel_holder_label:(channel_holder_label channel)
  in
  holder_state.acquired_turn := true;
  let cleanup () = release_turn_holder ~keeper_name holder_state in
  let body () =
    run_after_acquire_flag_hook_for_test
      ~label:(holder_pool_to_string Turn_holder)
      ~keeper_name;
    let acquired_at = Time_compat.now () in
    let turn_acquisition_id =
      record_holder ~label:Turn_holder ~keeper_name ~acquired_at
    in
    holder_state.turn_acquisition_id := Some turn_acquisition_id;
    (match holder_state.channel_holder_label with
     | None -> ()
     | Some label ->
       run_after_acquire_flag_hook_for_test
         ~label:(holder_pool_to_string label)
         ~keeper_name;
       let acquisition_id = record_holder ~label ~keeper_name ~acquired_at in
       holder_state.channel_acquisition_id := Some acquisition_id);
    let holder_wait_sec = Time_compat.now () -. started_at in
    let holder_wait_ms =
      int_of_float
        ((if holder_wait_sec < 0.0 then 0.0 else holder_wait_sec) *. 1000.0)
    in
    let holder_control =
      { is_held = (fun () -> turn_holder_is_held holder_state) }
    in
    f ~holder_wait_ms ~holder_control
  in
  if Eio_guard.is_ready ()
  then
    Eio.Switch.run (fun turn_sw ->
      Eio.Switch.on_release turn_sw cleanup;
      body ())
  else Fun.protect ~finally:cleanup body
;;

let with_recorded_turn_holder_control ~keeper_name ~channel f =
  let t0 = Time_compat.now () in
  run_with_recorded_holder
    ~keeper_name
    ~channel
    ~started_at:t0
    f
;;

let with_recorded_turn_holder ~keeper_name ~channel f =
  with_recorded_turn_holder_control
    ~keeper_name
    ~channel
    (fun ~holder_wait_ms ~holder_control:_ -> f ~holder_wait_ms)
;;
