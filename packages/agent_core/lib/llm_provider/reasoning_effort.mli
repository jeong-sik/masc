(** Canonical OpenAI-compatible reasoning effort values.

    This module is the single source of truth for the typed effort set and
    canonical wire serialization. Token budgets are a distinct provider wire;
    this module never guesses an effort category from a numeric budget.
    Provider-specific aliasing belongs in {!Reasoning_dialect}. *)

type t =
  | None_
  | Minimal
  | Low
  | Medium
  | High
  | XHigh
  | Max

val all : t list

(** Ordinal position on the canonical effort ladder (None_ = 0 .. Max = 6).
    Exposed so callers can order efforts for catalog-driven clamping without
    re-deriving the ladder at every consumer. *)
val rank : t -> int

(** Total order following the effort ladder ([None_] < [Minimal] < ... < [Max]).
    Used by catalog-driven clamping to pick the nearest accepted effort below a
    requested one. *)
val compare : t -> t -> int

val to_string : t -> string
val pp : Format.formatter -> t -> unit
val show : t -> string
val all_wire_values : string list
val of_string : string -> t option
val values_for_log : string
