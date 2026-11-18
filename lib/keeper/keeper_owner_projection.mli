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

val meta_the_file_holds
  :  base_path:string
  -> keeper_name:string
  -> Keeper_meta_contract.keeper_meta option
(** The Owner's meta, when it stands for the Keeper's meta file: an Owner is
    installed, it holds a meta, and none of its meta writes ended without a
    known outcome ({!Keeper_owner.meta_write_unsettled}). [None] in every
    other case; the file is then the only source.

    The value is the Owner's memory, not what a file read returns. The
    snapshot encoding leaves the TOML-owned fields out, so a reader that
    wants the file's answer passes it through
    [Keeper_meta_store.snapshot_read_back]. Lock-free, and it opens no file. *)
