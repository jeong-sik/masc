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

type rate_limit = State.rate_limit =
  | Unknown_scope_rate_limit of { noted_at : float; retry_after : float option }

type attempt_failure = State.attempt_failure =
  | Server_error
  | Network_transient
  | Provider_timeout
  | Access_refused

type failed_attempt = State.failed_attempt =
  | Failed_attempt of { noted_at : float; failure : attempt_failure }

type candidate_backpressure = State.candidate_backpressure =
  { rate_limit : rate_limit option
  ; failed_attempt : failed_attempt option
  }

type candidate_binding =
  | Resolved_http_binding of Agent_core.Binding_identity.t
  | Http_binding_unavailable of string
  | Official_client_binding

type candidate =
  { binding : candidate_binding
  ; backpressure : candidate_backpressure Atomic.t
  }

let create_candidate ~binding = { binding; backpressure = Atomic.make State.empty }

let same_candidate_binding left right =
  match left.binding, right.binding with
  | Resolved_http_binding left, Resolved_http_binding right ->
      Agent_core.Binding_identity.equal left right
  | Official_client_binding, Official_client_binding -> true
  | Resolved_http_binding _, (Http_binding_unavailable _ | Official_client_binding)
  | Http_binding_unavailable _,
      (Resolved_http_binding _ | Http_binding_unavailable _ | Official_client_binding)
  | Official_client_binding, (Resolved_http_binding _ | Http_binding_unavailable _) -> false

let rec update_candidate candidate transition =
  let current = Atomic.get candidate.backpressure in
  let next = transition current in
  if Atomic.compare_and_set candidate.backpressure current next then next
  else update_candidate candidate transition

let note_rate_limit ~candidate ~retry_after =
  let noted_at = now () in
  (* See update_candidate: CAS publishes the observation; discard its read-back value, not an error. *)
  ignore (update_candidate candidate (State.note_rate_limit ~noted_at ~retry_after))

let note_failed_attempt ~candidate ~failure =
  let noted_at = now () in
  (* See update_candidate: CAS publishes the observation; discard its read-back value, not an error. *)
  ignore (update_candidate candidate (State.note_failed_attempt ~noted_at ~failure))

let note_candidate_success ~candidate = Atomic.set candidate.backpressure State.empty

let candidate_backpressure ~now ~candidate =
  let observed = update_candidate candidate (State.observe ~now) in
  if State.is_empty observed then None else Some observed
