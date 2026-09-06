(** Keeper lifecycle event SSOT — see [.ml] header for context.

    Issue #8575. *)

type t =
  | Started
  | Reconciled
  | Restarted
  | Supervisor_cleaned
  | Purged
  | Admission_denied

val to_string : t -> string

val all_custom_events : t list
(** Custom + phase-derived. Subscribe to this whole list to avoid
    silently missing half the supervisor stream. *)
val all_event_names : string list

(** {1 Unified lifecycle event sum type (#8856)}

    Wire vocabulary for [Keeper_event_publisher.publish_keeper_lifecycle]. The
    [Custom_event] case carries an optional phase context that the
    legacy [?phase] argument used to provide; [Phase_event] is the case
    where the wire event name IS the phase name. *)
type lifecycle_event =
  | Custom_event of { verb : t; phase : Keeper_state_machine.phase option }
  | Phase_event of Keeper_state_machine.phase

val lifecycle_event_to_string : lifecycle_event -> string
val lifecycle_event_phase :
  lifecycle_event -> Keeper_state_machine.phase option

val lifecycle_event_of_wire :
  event:string ->
  phase:string option ->
  lifecycle_event option
(** Decode the exact current event-bus contract. Custom events may omit phase;
    phase events require matching [event] and [phase] labels. Unknown or
    inconsistent payloads fail closed. *)
