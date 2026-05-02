(** Keeper lifecycle event SSOT — see [.ml] header for context.

    Issue #8575. *)

type t =
  | Started
  | Reconciled
  | Restarted
  | Dead_cleaned
  | Self_preservation
  | Paused_pruned
  | Auto_resumed

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

(** {1 Unified lifecycle event sum type (#8856)}

    Wire vocabulary for [Oas_events.publish_keeper_lifecycle]. The
    [Custom_event] case carries an optional phase context that the
    legacy [?phase] argument used to provide; [Phase_event] is the case
    where the wire event name IS the phase name. *)
type lifecycle_event =
  | Custom_event of { verb : t; phase : Keeper_state_machine.phase option }
  | Phase_event of Keeper_state_machine.phase

val lifecycle_event_to_string : lifecycle_event -> string
val lifecycle_event_phase :
  lifecycle_event -> Keeper_state_machine.phase option
