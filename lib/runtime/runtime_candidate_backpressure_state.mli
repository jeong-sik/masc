(** Pure state for one runtime candidate's observed backpressure.

    Two observations are held side by side because they answer different
    questions: a rate limit can carry the provider's own time, which decides
    when a resting path is waited for, and a failed attempt carries none and
    only moves the candidate back in the walk (RFC-0458 §3.4). One does not
    replace the other. *)

type rate_limit =
  | Unknown_scope_rate_limit of { noted_at : float; retry_after : float option }
(** The attempted candidate was rate-limited; no model/account/provider
    ownership was reported. This never describes a credential quota. *)

type attempt_failure =
  | Server_error
  | Network_transient
  | Provider_timeout
(** The failure routes that say the candidate did not answer, and that are
    neither the candidate's rate limit nor MASC's own capacity. *)

type failed_attempt =
  | Failed_attempt of { noted_at : float; failure : attempt_failure }
(** The attempted candidate failed without answering. There is no time at
    which this stops being true; only an answer from the candidate ends it. *)

type candidate_backpressure =
  { rate_limit : rate_limit option
  ; failed_attempt : failed_attempt option
  }

val empty : candidate_backpressure

val is_empty : candidate_backpressure -> bool

val note_rate_limit :
  noted_at:float -> retry_after:float option ->
  candidate_backpressure -> candidate_backpressure
(** Record the rate limit unless a newer one is already held. A delay that is
    not a finite non-negative number is kept as no hint. The failed attempt, if
    any, is kept. *)

val note_failed_attempt :
  noted_at:float -> failure:attempt_failure ->
  candidate_backpressure -> candidate_backpressure
(** Record the failed attempt unless a newer one is already held. The rate
    limit, if any, is kept. *)

val observe : now:float -> candidate_backpressure -> candidate_backpressure
(** A usable provider hint ends the rate limit after that delay. Without one,
    only an observed success clears it; no timer supplies a duration. A failed
    attempt is never ended by time. *)
