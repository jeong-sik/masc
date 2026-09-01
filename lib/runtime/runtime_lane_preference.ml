(** Process-local sticky candidate preference for runtime lane failover.

    See the [.mli] for the contract.  Implementation notes:

    - One immutable state value is published through an atomic compare-and-set
      transition, so record/read calls need no Eio runtime or lock.
    - The shell observes clock and TTL once before the transition. The pure
      state function resolves absence versus expiry and prunes stale entries. *)

module State = Runtime_lane_preference_state

let state = Atomic.make State.empty

let ttl_s = Env_config_runtime.Lane.preference_ttl_s

(* NDT-OK: the wall clock is the explicit time boundary for TTL expiry; no
   deterministic replay logic branches on these timestamps. *)
let now () = Unix.gettimeofday ()

let rec apply_transition transition =
  let current = Atomic.get state in
  let next, output = transition current in
  if Atomic.compare_and_set state current next
  then output
  else apply_transition transition
;;

let observe ~lane_id =
  let observed_at = now () in
  let ttl = ttl_s () in
  apply_transition (State.observe ~now:observed_at ~ttl_s:ttl ~lane_id)
;;

let prefer_order ~lane_id candidates =
  State.reorder (observe ~lane_id) candidates

let note_success ~lane_id ~candidate =
  let noted_at = now () in
  apply_transition (fun state ->
    State.remember ~lane_id ~candidate ~noted_at state, ())

let preferred_of_lane ~lane_id =
  State.preferred (observe ~lane_id)

let reset_for_testing () =
  Atomic.set state State.empty
