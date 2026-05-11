(** Declarative cascade config cross-reference validator (RFC-0058 v2).

    [validate] checks 10 base load-time invariants (R1–R10) on a parsed
    [cascade_config]; [validate_strict] additionally enforces R11
    (binding max-concurrent required & positive). Each returns all errors
    found rather than stopping at the first. *)

type validation_error =
  { rule : string
  ; path : string
  ; message : string
  }
[@@deriving show]

val validate : Cascade_declarative_types.cascade_config -> validation_error list

(** Like {!validate}, plus R11 (binding max-concurrent required & positive,
    RFC-0058 §3.4). Use for production cascade.toml loading where missing
    capacity must fail-fast. Legacy fixtures that predate the capacity
    requirement continue to use {!validate}. *)
val validate_strict : Cascade_declarative_types.cascade_config -> validation_error list
