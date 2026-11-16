(** Health probe path SSOT.

    Issue #8403 — see [.ml] header for context. *)

val health : string
(** [/health], the probe that reports which workspace this server serves, to
    a requester it gives a read of its state. Any other requester gets the
    public probe of {!Server_health_public}. *)

val liveness : string
(** [/health/live] *)

val readiness : string
(** [/health/ready] *)

val full : string
(** [/health?full=1], the request that answers with the full health rollup
    instead of the probe shape. *)

val is_public : string -> bool
(** [is_public path] is [true] iff [path] is one of [public]. Use
    instead of hand-coded [String.equal path "/health/live" || ...]
    chains. *)
