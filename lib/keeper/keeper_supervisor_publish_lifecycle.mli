(** Lifecycle event publisher for the keeper supervisor. *)

val publish_lifecycle :
  event:Keeper_lifecycle_events.lifecycle_event -> string -> string -> unit -> unit
(** Record and publish a keeper lifecycle event when the event bus is available. *)

val publish_phase_lifecycle :
  phase:Keeper_state_machine.phase -> string -> string -> unit -> unit
(** Publish a lifecycle event whose wire event name is the phase name. *)
