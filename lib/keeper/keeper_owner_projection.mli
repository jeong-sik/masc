(** Lock-free read authority for Keeper owner projections.

    The inventory installs each Owner handle in an immutable index. Registry
    and routine query surfaces select the handle from one Atomic index snapshot
    and read its current immutable projection; this module owns no metadata
    state and performs no persistence. *)

type lookup =
  | Owner_absent
  | Owner_projection of Keeper_owner_reducer.projection

val install
  :  base_path:string
  -> keeper_name:string
  -> Keeper_owner.t
  -> unit
(** Replace the handle for the canonical base-path and Keeper-name key. *)

val remove
  :  base_path:string
  -> keeper_name:string
  -> Keeper_owner.t
  -> unit
(** Remove the key only when it still names this exact Owner handle. Cleanup
    from a replaced Owner leaves its successor installed. *)

val lookup : base_path:string -> keeper_name:string -> lookup
