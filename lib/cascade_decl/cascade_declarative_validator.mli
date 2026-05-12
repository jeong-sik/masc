(** Declarative cascade config cross-reference validator (RFC-0058 v2).

    [validate] checks all 13 load-time invariants (R1–R13) on a parsed
    [cascade_config] and returns every error found rather than stopping
    at the first. R11 (binding max-concurrent required & positive,
    RFC-0058 §3.4) is enforced unconditionally. R12 (protocol ↔ transport
    consistency, RFC-0058 §2.1) checks that protocol suffixes like "-cli"
    and "-http" match the declared transport type. R13 (every provider
    declares [liveness.class], RFC-0058 §4 Phase 5.2b) is the structural
    counterpart to deleting the hardcoded vendor match in
    [Cascade_attempt_liveness_config]. *)

type validation_error =
  { rule : string
  ; path : string
  ; message : string
  }
[@@deriving show]

val validate : Cascade_declarative_types.cascade_config -> validation_error list
