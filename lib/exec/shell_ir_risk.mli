(** Shell_ir_risk — phantom-typed risk envelope for Shell IR.

    RFC-0160 S3: type-level invariant that every IR reaching dispatch
    has been classified. [undecided t] values must pass through
    [classify] to obtain a [decided decided_ir] before dispatch. *)

type undecided
type decided

type risk_class =
  | R0_Read
  | R1_Reversible_mutation
  | R2_Irreversible
  | Destructive_protected

val string_of_risk_class : risk_class -> string
val pp_risk_class : Format.formatter -> risk_class -> unit

(** Phantom wrapper. Zero runtime overhead. *)
type _ t

val undecided : Shell_ir.t -> undecided t
val unwrap : 'phase t -> Shell_ir.t

type 'phase decided_ir = { ir : Shell_ir.t; risk : risk_class }

val risk_class : decided decided_ir -> risk_class
val is_r0 : decided decided_ir -> bool
val is_r1 : decided decided_ir -> bool
val is_r2 : decided decided_ir -> bool
val is_destructive : decided decided_ir -> bool

val classify : undecided t -> decided decided_ir
(** Run the unified risk classifier over the wrapped IR.
    Uses [Exec_policy_mutation_classifier] for bash operations,
    then gh subcommand tables for gh operations, defaulting to R0. *)

val is_write_operation : string list -> bool
(** [true] when the flattened word list indicates a write-level operation:
    git push/commit/merge/rebase/reset/checkout -c/-C/-m/-M/branch,
    or non-git commands that touch state.

    Used by [Exec_policy_mutation_classifier.is_write_operation] for
    the IR-typed entry point. *)

val classify_gh : string list -> risk_class
(** Direct gh word-list classification without IR construction.
    Used by [Keeper_tool_registry] to avoid a circular dependency
    through [Keeper_gh_command_parse]. *)
