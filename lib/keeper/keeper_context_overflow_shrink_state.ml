(** Keeper_context_overflow_shrink_state — process-local memory of the last
    prompt byte capacity that completed a turn successfully for a given
    (keeper, runtime) pair on an official-client lane; see the interface.

    #27320: the official-client lanes retry a provider-reported context
    overflow on the SAME runtime with a halved capacity
    ({!Keeper_turn_driver_try_provider.context_overflow_shrink_sequence}).
    Remembering the capacity that last succeeded lets the next turn on that
    (keeper, runtime) start from it instead of re-discovering it by shrinking
    again from the full declared cap every time.

    Deliberately not durable: this is a same-process optimization to avoid
    repeated rediscovery, not a state transition anything depends on for
    correctness. A process restart, an unseen (keeper, runtime) pair, or a
    remembered value above the lane's current declaration all fall back to
    that declaration via {!starting_capacity}. *)

module Key = struct
  type t = { keeper_name : string; runtime_id : string }

  let compare left right =
    match String.compare left.keeper_name right.keeper_name with
    | 0 -> String.compare left.runtime_id right.runtime_id
    | nonzero -> nonzero
  ;;
end

module Capacity_map = Map.Make (Key)

type t =
  { mutable last_successful_capacity : int Capacity_map.t
  ; mutex : Eio.Mutex.t
  }

let global = { last_successful_capacity = Capacity_map.empty; mutex = Eio.Mutex.create () }

let starting_capacity ~keeper_name ~runtime_id ~max_capacity =
  let key = { Key.keeper_name; runtime_id } in
  let remembered =
    Eio.Mutex.use_ro global.mutex (fun () ->
      Capacity_map.find_opt key global.last_successful_capacity)
  in
  match remembered with
  | Some remembered when remembered > 0 && remembered <= max_capacity -> remembered
  | Some _ (* stale: now exceeds the lane's current declaration, or non-positive *)
  | None -> max_capacity
;;

let record_success ~keeper_name ~runtime_id ~capacity =
  let key = { Key.keeper_name; runtime_id } in
  Eio.Mutex.use_rw ~protect:true global.mutex (fun () ->
    global.last_successful_capacity <-
      Capacity_map.add key capacity global.last_successful_capacity)
;;

module For_testing = struct
  let reset () =
    Eio.Mutex.use_rw ~protect:true global.mutex (fun () ->
      global.last_successful_capacity <- Capacity_map.empty)
  ;;
end
