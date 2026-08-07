(** Keeper_context_overflow_shrink_state — process-local memory of the last
    model-input windowing capacity that completed a turn successfully for a
    given (keeper, runtime) pair.

    #27320: {!Keeper_turn_driver_try_provider.run_try_provider_with_context_overflow_shrink}
    retries a provider-reported context overflow on the SAME runtime with a
    halved windowing capacity. Remembering the capacity that last succeeded
    lets the next turn on that (keeper, runtime) start from it instead of
    re-discovering it by shrinking again from the full declared request-body
    cap every time.

    Deliberately not durable: this is a same-process optimization to avoid
    repeated rediscovery, not a state transition anything depends on for
    correctness. A process restart, an unseen (keeper, runtime) pair, or a
    remembered value above the runtime's current declared cap all fall back
    to that cap via {!starting_capacity_bytes}. *)

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
  { mutable last_successful_capacity_bytes : int Capacity_map.t
  ; mutex : Eio.Mutex.t
  }

let global = { last_successful_capacity_bytes = Capacity_map.empty; mutex = Eio.Mutex.create () }

let starting_capacity_bytes ~keeper_name ~runtime_id ~max_capacity_bytes =
  let key = { Key.keeper_name; runtime_id } in
  let remembered =
    Eio.Mutex.use_ro global.mutex (fun () ->
      Capacity_map.find_opt key global.last_successful_capacity_bytes)
  in
  match remembered with
  | Some remembered_bytes
    when remembered_bytes > 0 && remembered_bytes <= max_capacity_bytes ->
    remembered_bytes
  | Some _ (* stale: now exceeds the runtime's current declared cap, or non-positive *)
  | None -> max_capacity_bytes
;;

let record_success ~keeper_name ~runtime_id ~capacity_bytes =
  let key = { Key.keeper_name; runtime_id } in
  Eio.Mutex.use_rw ~protect:true global.mutex (fun () ->
    global.last_successful_capacity_bytes <-
      Capacity_map.add key capacity_bytes global.last_successful_capacity_bytes)
;;

module For_testing = struct
  let reset () =
    Eio.Mutex.use_rw ~protect:true global.mutex (fun () ->
      global.last_successful_capacity_bytes <- Capacity_map.empty)
  ;;
end
