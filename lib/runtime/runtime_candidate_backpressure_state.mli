(** Pure state for one runtime candidate's observed backpressure. *)

type candidate_backpressure =
  | Unknown_scope_rate_limit of { noted_at : float; retry_after : float option }
(** The attempted candidate was rate-limited; no model/account/provider
    ownership was reported. This never describes a credential quota. *)

val note_rate_limit :
  noted_at:float -> retry_after:float option ->
  candidate_backpressure option -> candidate_backpressure option
(** Record the observation unless a newer one is already held. A delay that
    is not a finite non-negative number is kept as no hint. *)

val observe_rate_limit :
  now:float -> candidate_backpressure option -> candidate_backpressure option
(** A usable provider hint ends the observation after that delay. Without one,
    only an observed success clears it; no timer supplies a duration. *)
