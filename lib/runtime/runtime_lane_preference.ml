(** Process-local sticky candidate preference for runtime lane failover.

    See the [.mli] for the contract.  Implementation notes:

    - One immutable state value is swapped under [Stdlib.Mutex] (record/read
      may be called outside Eio fibers, so [Eio.Mutex] is not required).
    - The shell observes clock and TTL once before locking. The pure state
      transition resolves absence versus expiry and prunes stale entries. *)

module State = Runtime_lane_preference_state

let state = ref State.empty
let mu = Stdlib.Mutex.create ()

let ttl_s = Env_config_runtime.Lane.preference_ttl_s

(* NDT-OK: the wall clock is the explicit time boundary for TTL expiry; no
   deterministic replay logic branches on these timestamps. *)
let now () = Unix.gettimeofday ()

let apply_transition transition =
  Stdlib.Mutex.protect mu (fun () ->
    let next, output = transition !state in
    state := next;
    output)
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
  Stdlib.Mutex.protect mu (fun () -> state := State.empty)
