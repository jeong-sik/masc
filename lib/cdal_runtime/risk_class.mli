(** Risk classification for contract-driven agent runs.

    Part of the Contract-Driven Agent Loop (CDAL) PoC-1.
    Three-axis model: blast_radius x irreversibility x recovery_cost.

    @stability Evolving
    @since 0.93.1 *)

type t =
  | Low (** Small radius, easy rollback, low recovery cost *)
  | Medium (** One or more ambiguous/mid-level axes *)
  | High (** Any one axis large; Execute forbidden without human review *)
  | Critical (** Hard to reverse or external system damage; default = reject *)
[@@deriving yojson, show]

val to_string : t -> string
val of_string : string -> (t, string) result
val equal : t -> t -> bool
val compare : t -> t -> int

(** Maximum allowed execution mode for this risk class.
    [None] means the run should be rejected outright. *)
val max_mode : t -> Execution_mode.t option
