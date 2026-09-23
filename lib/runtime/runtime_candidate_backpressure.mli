(** Process-local backpressure evidence per runtime candidate.

    A coarse HTTP 429 / provider rate limit names no credential scope, so it
    is held by the attempted runtime alone and read as ordering evidence by
    the lane walk (RFC-0370 §3.3, RFC-0433): a candidate under backpressure
    is demoted behind its lane siblings, never excluded. A server error,
    network failure, timeout, or access refusal is held the same way until the
    candidate answers (RFC-0458 §3.4). The observation cell lives on the
    materialized runtime; frozen attempts retain the same cell, and the runtime
    catalog owns its lifetime. *)

type rate_limit = Runtime_candidate_backpressure_state.rate_limit =
  | Unknown_scope_rate_limit of { noted_at : float; retry_after : float option }

type attempt_failure = Runtime_candidate_backpressure_state.attempt_failure =
  | Server_error
  | Network_transient
  | Provider_timeout
  | Access_refused

type failed_attempt = Runtime_candidate_backpressure_state.failed_attempt =
  | Failed_attempt of { noted_at : float; failure : attempt_failure }

type candidate_backpressure = Runtime_candidate_backpressure_state.candidate_backpressure =
  { rate_limit : rate_limit option
  ; failed_attempt : failed_attempt option
  }

type candidate_binding =
  | Resolved_http_binding of Agent_core.Binding_identity.t
  | Http_binding_unavailable of string
  | Official_client_binding
(** HTTP identity construction failure retains its reason separately from a
    native official client, which has no HTTP identity by design. *)

type candidate
(** One materialized dispatch identity and its process-local observation. The
    runtime catalog owns its lifetime; frozen attempts retain the same cell. *)

val create_candidate : binding:candidate_binding -> candidate
(** An unavailable binding still owns an isolated observation cell and does
    not introduce a dispatch gate, but cannot prove continuity on reload. *)

val same_candidate_binding : candidate -> candidate -> bool
(** Compare only frozen authoritative identities. An HTTP identity that could
    not be built never establishes equality. An official client has no HTTP
    identity: its dispatch is built from the provider and model alone, so two
    official-client candidates are the same binding here and the caller's
    provider, model and binding equality decides. Used at catalog publication
    to preserve unchanged rows. *)

val note_rate_limit : candidate:candidate -> retry_after:float option -> unit
(** Record coarse HTTP/Provider rate-limit evidence for this attempted runtime
    only. Siblings sharing a credential are not marked exhausted. *)

val note_failed_attempt : candidate:candidate -> failure:attempt_failure -> unit
(** Record that this attempted runtime failed without answering. It carries no
    time: it holds until the candidate answers. *)

val note_candidate_success : candidate:candidate -> unit
(** Clear this candidate's rate limit and failed attempt after it answered. *)

val candidate_backpressure : now:float -> candidate:candidate -> candidate_backpressure option
(** Ordering evidence only, [None] when the cell holds none. No candidate is
    excluded. Retry-After is retained when usable; no-hint rate limits and
    failed attempts have no invented deadline and are cleared by success. *)
