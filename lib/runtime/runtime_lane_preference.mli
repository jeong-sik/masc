(** Process-local sticky candidate preference for runtime lane failover.

    Lane failover walks candidates in declared order every turn, so a dead
    head candidate (e.g. an hourly provider rate-limit window) is hit on
    every turn before the lane fails over.  This module remembers the last
    successful candidate per lane so later turns start from it instead.

    The immutable registry is keyed by lane id and shared across keepers on purpose:
    one keeper's successful failover discovery benefits every keeper routed
    through the same lane; this preference asserts no quota ownership.  Entries
    expire lazily on read against {!ttl_s}; there is no background sweeper.
    Clock and TTL are observed once before the atomic registry transition,
    then supplied to a pure state function. *)

val prefer_order : lane_id:string -> string list -> string list
(** Reorder [candidates] so the remembered last-good candidate for [lane_id]
    comes first, keeping the declared relative order of the rest.  Returns
    the input unchanged when no entry is remembered, the entry expired, or
    the remembered candidate is not a member of [candidates]. *)

val note_success : lane_id:string -> candidate:string -> unit
(** Remember [candidate] as the last-good candidate for [lane_id], stamped
    with the current time.  Called on every successful attempt, whether the
    head candidate or a failover candidate succeeded. *)

val preferred_of_lane : lane_id:string -> (string * float) option
(** Live sticky preference for [lane_id]: [Some (candidate, noted_at)] with
    [noted_at] a Unix epoch timestamp, [None] when nothing is remembered or
    the entry expired (expired entries are pruned on read, same as
    {!prefer_order}).  Read-only view for observability surfaces; callers
    derive display age from [noted_at]. *)

val ttl_s : unit -> float
(** Sticky preference TTL in seconds ([MASC_LANE_PREFERENCE_TTL_S], default
    [3600.0]; [0] disables stickiness). *)

val reset_for_testing : unit -> unit
(** Drop every remembered entry.  Test-only. *)

type candidate_backpressure = Runtime_lane_preference_state.candidate_backpressure =
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
    deadline and are cleared by success. Independent of sticky preference TTL. *)
