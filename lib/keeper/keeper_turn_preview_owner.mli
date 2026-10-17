(** Exact running slot supplied by Keeper Owner, inherited by its turn fibers.
    This binding grants observation identity, not scheduling authority. *)
type turn_observation
val create_turn_observation : unit -> turn_observation
val observed_turn_ref : turn_observation -> Ids.Turn_ref.t option
(** The producer-supplied original turn, if unambiguous. No name/time lookup.
    Repeated equal observations are harmless; conflicting turns remain unknown. *)
val note_turn_ref : Ids.Turn_ref.t -> unit
(** Observe a turn at its actual creation site in the inherited Owner binding.
    No I/O, dispatch decision, completion decision or exception translation. *)
val with_owner : interrupt_token:Keeper_interrupt_token.t ->
  observation:turn_observation -> (unit -> 'a) -> 'a
val current : unit -> Keeper_interrupt_token.t option
