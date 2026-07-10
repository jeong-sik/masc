(** RFC-0331 — Typed tool effect class.

    Closed sum declared at tool registration, consumed by the verifier to
    decide whether an action needs verification. [Read_only] means the tool
    is registered as read-only; [Mutating] is everything else. Unknown /
    undeclared tools are [Mutating] by construction (fail-closed): the
    permissive branch is unrepresentable, so the verifier can never skip an
    unrecognized tool. Replaces the former [Verifier_core] free-text
    read-only substring classifier (which was fail-open). *)

type t =
  | Read_only
  | Mutating

(** ["read_only"] / ["mutating"]. *)
val to_string : t -> string

val equal : t -> t -> bool
