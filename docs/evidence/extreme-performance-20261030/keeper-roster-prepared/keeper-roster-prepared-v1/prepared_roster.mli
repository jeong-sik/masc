(** Research prototype over reduced fixture records, not the product API. *)
type t
val prepare : Fixture_types.Control.roster -> t
(** Construct one immutable source-owned value. Includes the complete original
    roster and a derived lookup; no mutable cache or I/O. *)
val view : t -> Fixture_types.Control.roster
val liveness : t -> string -> Fixture_types.Control.liveness
