(** Process-local backpressure evidence per runtime candidate.

    A coarse HTTP 429 / provider rate limit names no credential scope, so it
    is held by the attempted runtime alone and read as ordering evidence by
    the lane walk (RFC-0370 §3.3, RFC-0433): a candidate under backpressure
    is demoted behind its lane siblings, never excluded. The observation cell
    lives on the materialized runtime; frozen attempts retain the same cell,
    and the runtime catalog owns its lifetime. *)

type candidate_backpressure = Runtime_candidate_backpressure_state.candidate_backpressure =
  | Unknown_scope_rate_limit of { noted_at : float; retry_after : float option }

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
(** Compare only frozen authoritative identities. Unknown identities never
    establish equality. Used at catalog publication to preserve unchanged rows. *)

val note_rate_limit : candidate:candidate -> retry_after:float option -> unit
(** Record coarse HTTP/Provider rate-limit evidence for this attempted runtime
    only. Siblings sharing a credential are not marked exhausted. *)

val note_candidate_success : candidate:candidate -> unit
(** Clear this candidate's backpressure after an observed successful call. *)

val candidate_backpressure : now:float -> candidate:candidate -> candidate_backpressure option
(** Ordering evidence only. No candidate is excluded and no wait is imposed.
    Retry-After is retained when usable; no-hint observations have no invented
    deadline and are cleared by success. *)
