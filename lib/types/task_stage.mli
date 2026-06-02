(** Task_stage — Typed task progress labels.

    Advisory order for coding-oriented work:
    decompose → inspect → implement → verify → review

    These labels are not gate authority. They help dashboards and reports
    describe rough progress, but they must not prevent implementation,
    verification, or review. *)

type t =
  | Decompose
  | Inspect
  | Implement
  | Verify
  | Review
[@@deriving show, eq, ord]

val to_string : t -> string
val of_string : string -> (t, string) result

val to_yojson : t -> Yojson.Safe.t
val of_yojson : Yojson.Safe.t -> (t, string) result

(** All stages in canonical order. *)
val all : t list

(** Can transition from [current] to [target]?
    Progress labels are advisory and never reject a transition. *)
val can_transition : current:t -> target:t -> bool

(** Validate a transition.
    Compatibility helper for older call sites; always returns [Ok ()]. *)
val validate_transition : current:t -> target:t -> (unit, string) result

(** Default label for a new coding-oriented task. *)
val initial : t
