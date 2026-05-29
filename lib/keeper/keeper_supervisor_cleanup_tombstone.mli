(** Dead-tombstone cleanup helper for the keeper supervisor. *)

val cleanup_dead_tombstone
  :  publish_lifecycle:
       (event:Keeper_lifecycle_events.lifecycle_event -> string -> string -> unit -> unit)
  -> 'a Keeper_types_profile.context
  -> Keeper_registry.registry_entry
  -> unit
