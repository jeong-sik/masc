(** Declarative cascade config cross-reference validator (RFC-0058 v2).

    Validates 9 load-time invariants on a parsed [cascade_config].
    Returns all errors found (does not stop at first). *)

type validation_error = {
  rule : string;
  path : string;
  message : string;
}
[@@deriving show]

val validate : Cascade_declarative_types.cascade_config -> validation_error list
