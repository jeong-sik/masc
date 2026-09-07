(** Process-local sticky candidate preference for runtime lane failover.

    See the [.mli] for the contract.  Implementation notes:

    - One immutable state value is published through an atomic compare-and-set
      transition, so record/read calls need no Eio runtime or lock.
    - The shell observes clock and TTL once before the transition. The pure
      state function resolves absence versus expiry and prunes stale entries.
    - Candidate backpressure is held by the materialized runtime itself. The
      opaque binding identity permits reuse on unchanged catalog publication;
      rebound/removed rows leave no global candidate registry behind. *)

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

type candidate_backpressure = State.candidate_backpressure =
  | Unknown_scope_rate_limit of { noted_at : float; retry_after : float option }

type candidate_binding =
  | Resolved_http_binding of Agent_core.Binding_identity.t
  | Http_binding_unavailable of string
  | Official_client_binding

type candidate =
  { binding : candidate_binding
  ; backpressure : candidate_backpressure option Atomic.t
  }

let create_candidate ~binding = { binding; backpressure = Atomic.make None }

let same_candidate_binding left right =
  match left.binding, right.binding with
  | Resolved_http_binding left, Resolved_http_binding right ->
      Agent_core.Binding_identity.equal left right
  | Resolved_http_binding _, (Http_binding_unavailable _ | Official_client_binding)
  | (Http_binding_unavailable _ | Official_client_binding),
      (Resolved_http_binding _ | Http_binding_unavailable _ | Official_client_binding) -> false

let rec update_candidate candidate transition =
  let current = Atomic.get candidate.backpressure in
  let next = transition current in
  if Atomic.compare_and_set candidate.backpressure current next then next
  else update_candidate candidate transition

let note_rate_limit ~candidate ~retry_after =
  let noted_at = now () in
  (* See update_candidate: CAS publishes the observation; discard its read-back value, not an error. *)
  ignore (update_candidate candidate (State.note_rate_limit ~noted_at ~retry_after))

let note_candidate_success ~candidate = Atomic.set candidate.backpressure None

let candidate_backpressure ~now ~candidate =
  update_candidate candidate (State.observe_rate_limit ~now)
