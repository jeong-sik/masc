(** Health probe path SSOT.

    Issue #8403 — see [.ml] header for context. *)

val liveness : string
(** [/health/live] *)

val readiness : string
(** [/health/ready] *)

val public : string list
(** Probe paths whitelisted for unauthenticated read access and
    treated as benign by startup-takeover/path filters. Order is
    deterministic; tests assert it stays aligned with [liveness] and
    [readiness]. *)

val is_public : string -> bool
(** [is_public path] is [true] iff [path] is one of [public]. Use
    instead of hand-coded [String.equal path "/health/live" || ...]
    chains. *)
