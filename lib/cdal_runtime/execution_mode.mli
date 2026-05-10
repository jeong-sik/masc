(** Execution mode for contract-driven agent runs.

    Part of the Contract-Driven Agent Loop (CDAL) PoC-1.
    Ordering: [Diagnose < Draft < Execute].

    @stability Evolving
    @since 0.93.1 *)

type t =
  | Diagnose (** Read-only analysis, no mutations *)
  | Draft (** Workspace-local mutations, no external side effects *)
  | Execute (** Full execution with external side effects *)
[@@deriving yojson, show]

val to_string : t -> string
val of_string : string -> (t, string) result
val equal : t -> t -> bool
val compare : t -> t -> int

(** [can_serve ~requested ~effective] returns [true] iff
    [effective <= requested] in the ordering [Diagnose < Draft < Execute].
    OAS can only downgrade, never upgrade. *)
val can_serve : requested:t -> effective:t -> bool
