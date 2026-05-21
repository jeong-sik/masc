(** Lifecycle event publisher extracted from [Keeper_supervisor]. *)

val publish_lifecycle :
  event:Keeper_lifecycle_events.lifecycle_event ->
  string ->
  string ->
  unit ->
  unit
(** Record and publish a keeper lifecycle event. *)

val publish_phase_lifecycle :
  phase:Keeper_state_machine.phase ->
  string ->
  string ->
  unit ->
  unit
(** Publish a lifecycle event whose wire event name is the phase name. *)
