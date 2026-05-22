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

val trust_decided : undecided t -> decided decided_ir
(** Escape hatch for tests and transitional call sites.
    Production code must use [classify]. *)
