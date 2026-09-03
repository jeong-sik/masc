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

(** The effort a categorical-effort wire carries once an explicit thinking
    toggle is applied. That wire ({!Capabilities.Reasoning_effort}) has no
    boolean field: its only control is the effort, and [None_] is its off
    value. [enable_thinking = Some false] therefore replaces the caller's
    effort with [None_]; [Some true] and absence keep the caller's effort.

    Both the request encoder ({!Reasoning_dialect.request_control_fields})
    and the effort-ladder admission
    ({!Provider_config.validate_reasoning_effort_request_typed}) go through
    this function, so the effort that is admitted is the effort that reaches
    the wire. Callers on any other control format keep their effort as is:
    their toggle is a separate field, or there is none. *)
val under_explicit_toggle : enable_thinking:bool option -> t option -> t option
