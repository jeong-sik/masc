(** Lock-free read authority for Keeper owner projections.

    The inventory installs each Owner handle here. Registry and routine query
    surfaces read its immutable Atomic projection directly; this module owns no
    metadata state and performs no persistence. *)

type lookup =
  | Owner_absent
  | Owner_projection of Keeper_owner_reducer.projection

val install
  :  base_path:string
  -> keeper_name:string
  -> Keeper_owner.t
  -> unit

val remove
  :  base_path:string
  -> keeper_name:string
  -> Keeper_owner.t
  -> unit

val lookup : base_path:string -> keeper_name:string -> lookup
