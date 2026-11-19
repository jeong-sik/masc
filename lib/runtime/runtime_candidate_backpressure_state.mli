(** Pure state for one runtime candidate's observed backpressure.

    Two observations are held side by side because they answer different
    questions: a rate limit can carry the provider's own time, which decides
    when a resting path is waited for, and a failed attempt carries none and
    only moves the candidate back in the walk. One does not
    replace the other. *)

type rate_limit =
  | Unknown_scope_rate_limit of { noted_at : float; retry_after : float option }
(** The attempted candidate was rate-limited; no model/account/provider
    ownership was reported. This never describes a credential quota. *)

type attempt_failure =
  | Server_error
  | Provider_capacity
  | Network_transient
  | Provider_timeout
(** The failure routes that say the candidate did not answer, and that are
    neither the candidate's rate limit nor MASC's own capacity. *)

type failure_scope =
  | Keeper_scoped
      (** Failure bound to the recording Keeper's own turn or connection
          ([Provider_timeout], [Network_transient]). Keyed by [recorded_by] so
          one Keeper stalling never blocks peer Keepers from using the
          candidate. *)
  | Provider_wide
      (** Failure indicating a provider-level fault ([Server_error],
          [Provider_capacity]). *)

val failure_scope : attempt_failure -> failure_scope
(** Classify an {!attempt_failure} into its closed {!failure_scope}. *)

val attempt_failure_to_wire_name : attempt_failure -> string
(** The name [/api/v1/runtime/resolved] carries. *)

val attempt_failure_of_wire_name : string -> attempt_failure option
(** The inverse of {!attempt_failure_to_wire_name}; [None] for a name this
    build does not know. *)

type recorder
(** The Keeper whose walk recorded a failed attempt. Compared only for
    identity: the recorder's next cycle walks the head again, every other
    walk keeps it behind (RFC-0458 §3.4, 2026-09-23). *)

val keeper_recorder : keeper_name:string -> recorder

val recorder_keeper_name : recorder -> string

val same_recorder : recorder -> recorder -> bool

type failed_attempt =
  | Failed_attempt of { noted_at : float; failure : attempt_failure; recorded_by : recorder }
(** The attempted candidate failed without answering. There is no time at
    which this stops being true; only an answer from the candidate ends it.
    [recorded_by] names the Keeper whose walk saw it; that Keeper's next
    attempt on the candidate renews or clears it. *)

type candidate_backpressure =
  { rate_limit : rate_limit option
  ; failed_attempt : failed_attempt option
  }

val empty : candidate_backpressure

val is_empty : candidate_backpressure -> bool

val note_rate_limit :
  noted_at:float -> retry_after:float option ->
  candidate_backpressure -> candidate_backpressure
(** Record the rate limit unless a newer one is already held. The delay is
    read by {!Keeper_runtime_failure_route.usable_retry_after}: one that names
    no wait, zero included, is kept as no hint, so only an observed success
    ends that rate limit. The failed attempt, if any, is kept. *)

val note_failed_attempt :
  noted_at:float -> failure:attempt_failure -> recorded_by:recorder ->
  candidate_backpressure -> candidate_backpressure
(** Record the failed attempt unless a newer one is already held. A newer
    failure replaces the recorder too: the Keeper that saw the candidate fail
    last is the one whose next cycle tries it again. The rate limit, if any,
    is kept. *)

val observe : now:float -> candidate_backpressure -> candidate_backpressure
(** A usable provider hint ends the rate limit after that delay. Without one,
    only an observed success clears it; no timer supplies a duration. A failed
    attempt is never ended by time. *)

val clear_keeper_failure :
  recorded_by:recorder -> candidate_backpressure -> candidate_backpressure
(** Clear a {!Keeper_scoped} [failed_attempt] recorded by [recorded_by] (e.g.
    on Keeper retire or observed turn success). [Provider_wide] failures,
    marks belonging to other Keepers, and any [rate_limit] are preserved. *)

val failed_attempt_for_keeper :
  ?keeper_name:string -> candidate_backpressure -> failed_attempt option
(** [failed_attempt_for_keeper ?keeper_name bp] resolves the [failed_attempt]
    visible to [keeper_name]:
    - [Provider_wide] failures are visible regardless of [keeper_name].
    - [Keeper_scoped] failures are visible only when [keeper_name] is [Some k]
      matching [recorded_by]; omitted [?keeper_name] or peer Keepers observe
      [None]. *)

val for_keeper :
  ?keeper_name:string -> candidate_backpressure -> candidate_backpressure
(** Project [bp] for [keeper_name] using {!failed_attempt_for_keeper}, keeping
    [rate_limit] unchanged. *)

module Recorder_map : Map.S with type key = recorder

type scoped_state =
  { shared : candidate_backpressure
    (** Candidate-wide rate limit and [Provider_wide] failed attempt. *)
  ; keeper_failures : failed_attempt Recorder_map.t
    (** [Keeper_scoped] failures keyed strictly by [recorded_by], keeping
        peer Keepers isolated from one another's stalls. *)
  }

val empty_scoped : scoped_state

val is_scoped_empty : scoped_state -> bool

val note_scoped_rate_limit :
  noted_at:float -> retry_after:float option ->
  scoped_state -> scoped_state

val note_scoped_failed_attempt :
  noted_at:float -> failure:attempt_failure -> recorded_by:recorder ->
  scoped_state -> scoped_state
(** Route [Provider_wide] failures to [shared.failed_attempt] and
    [Keeper_scoped] failures to [keeper_failures] keyed by [recorded_by],
    retaining the newer [noted_at] per key. *)

val clear_scoped_keeper_failure :
  recorded_by:recorder -> scoped_state -> scoped_state
(** Remove [recorded_by]'s entry from [keeper_failures] (and any matching
    [Keeper_scoped] mark in [shared]) while preserving peer Keepers' marks and
    [Provider_wide] state. *)

val clear_scoped_provider_failure : scoped_state -> scoped_state
(** Clear [shared] on observed provider answer without erasing unrelated peer
    Keepers' [Keeper_scoped] marks. *)

val observe_scoped : now:float -> scoped_state -> scoped_state

val scoped_failed_attempt_for_keeper :
  ?keeper_name:string -> scoped_state -> failed_attempt option
(** Return [keeper_name]'s [Keeper_scoped] failure if recorded (when
    [keeper_name] is [Some _]), or otherwise the [failed_attempt] visible from
    [shared] via {!failed_attempt_for_keeper}. *)

val scoped_for_keeper :
  ?keeper_name:string -> scoped_state -> candidate_backpressure
(** Project [scoped_state] into a {!candidate_backpressure} view for
    [keeper_name]. *)
