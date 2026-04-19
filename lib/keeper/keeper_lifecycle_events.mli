(** Keeper lifecycle event SSOT — see [.ml] header for context.

    Issue #8575. *)

type t =
  | Started
  | Reconciled
  | Restarted
  | Dead_cleaned
  | Self_preservation
  | Paused_pruned

val to_string : t -> string
val all_custom_events : t list
val valid_custom_event_strings : string list

(** Wire-format strings produced by phase-derived publishers. Mirrors
    [Keeper_state_machine.phase_to_string] for the four phases that
    emit a lifecycle event. *)
val phase_derived_event_strings : string list

(** Custom + phase-derived. Subscribe to this whole list to avoid
    silently missing half the supervisor stream. *)
val all_event_names : string list
