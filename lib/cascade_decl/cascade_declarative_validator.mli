(** Declarative cascade config cross-reference validator (RFC-0058 v2).

    [validate] checks all 12 load-time invariants (R1–R12) on a parsed
    [cascade_config] and returns every error found rather than stopping
    at the first. R11 (binding max-concurrent required & positive,
    RFC-0058 §3.4) is enforced unconditionally. R12 (protocol ↔ transport
    consistency, RFC-0058 §2.1) checks that protocol suffixes like "-cli"
    and "-http" match the declared transport type. *)

type validation_error =
  { rule : string
  ; path : string
  ; message : string
  }
[@@deriving show]

val validate : Cascade_declarative_types.cascade_config -> validation_error list
