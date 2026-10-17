(** Exact running slot supplied by Keeper Owner, inherited by its turn fibers.
    This binding grants observation identity, not scheduling authority. *)
val with_owner : interrupt_token:Keeper_interrupt_token.t -> (unit -> 'a) -> 'a
val current : unit -> Keeper_interrupt_token.t option
