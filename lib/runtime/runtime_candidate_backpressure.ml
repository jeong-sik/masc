(** Process-local backpressure evidence per runtime candidate.

    See the [.mli] for the contract. The observation is one atomic cell on the
    materialized runtime, published by compare-and-set, so record/read calls
    need no Eio runtime or lock. The opaque binding identity permits reuse on
    unchanged catalog publication; rebound or removed rows leave no global
    registry behind. *)

module State = Runtime_candidate_backpressure_state

(* NDT-OK: the wall clock stamps the observation; no deterministic replay
   logic branches on these timestamps. *)
let now () = Unix.gettimeofday ()

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
