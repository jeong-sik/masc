(** Self-preservation restart filter for keeper supervisor. *)

val reset_for_test : unit -> unit

module For_testing : sig
  val should_warn_partial_suppression_streak : streak:int -> bool
end

val apply
  :  keepers_dir:string
  -> publish_lifecycle:
       (event:Keeper_lifecycle_events.lifecycle_event -> string -> string -> unit -> unit)
  -> total_keepers:int
  -> (Keeper_registry.registry_entry * string) list
  -> (Keeper_registry.registry_entry * string) list
