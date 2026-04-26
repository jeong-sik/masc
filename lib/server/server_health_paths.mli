(** Health probe path SSOT.

    Issue #8403 — see [.ml] header for context. *)

(** [/health/live] *)
val liveness : string

(** [/health/ready] *)
val readiness : string

(** Probe paths whitelisted for unauthenticated read access and
    treated as benign by startup-takeover/path filters. Order is
    deterministic; tests assert it stays aligned with [liveness] and
    [readiness]. *)
val public : string list

(** [is_public path] is [true] iff [path] is one of [public]. Use
    instead of hand-coded [String.equal path "/health/live" || ...]
    chains. *)
val is_public : string -> bool
