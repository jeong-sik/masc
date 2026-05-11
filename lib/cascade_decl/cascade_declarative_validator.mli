(** Declarative cascade config cross-reference validator (RFC-0058 v2).

    [validate] checks all 11 load-time invariants (R1–R11) on a parsed
    [cascade_config] and returns every error found rather than stopping
    at the first. R11 (binding max-concurrent required & positive,
    RFC-0058 §3.4) is enforced unconditionally — RFC-0058 Phase 5.5
    collapsed the previous laxer variant into this single entry point. *)

type validation_error =
  { rule : string
  ; path : string
  ; message : string
  }
[@@deriving show]

val validate : Cascade_declarative_types.cascade_config -> validation_error list
