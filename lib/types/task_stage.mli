(** Task_stage — Typed coding_task stage gates.

    Enforces the canonical stage order:
    decompose → inspect → implement → verify → review

    Each transition requires the previous stage to be completed.
    Stages are optional — tasks without a stage bypass gating. *)

type t =
  | Decompose
  | Inspect
  | Implement
  | Verify
  | Review
[@@deriving show]

val to_string : t -> string
val of_string : string -> (t, string) result
val to_yojson : t -> Yojson.Safe.t
val of_yojson : Yojson.Safe.t -> (t, string) result

(** All stages in canonical order. *)
val all : t list

(** Index of a stage (0-based). *)
val index : t -> int

(** Can transition from [current] to [target]?
    Forward transitions (index target > index current) are allowed.
    Same-stage re-entry is allowed (idempotent).
    Backward transitions are forbidden. *)
val can_transition : current:t -> target:t -> bool

(** Validate a transition, returning Error with reason if forbidden. *)
val validate_transition : current:t -> target:t -> (unit, string) result

(** Initial stage for a new coding_task. *)
val initial : t
