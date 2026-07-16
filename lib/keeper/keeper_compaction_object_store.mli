type put_status =
  | Stored
  | Already_present
  | Reconciled

type load_error =
  | Not_found
  | Read_failed of Fs_compat.owned_regular_file_read_error
  | Snapshot_invalid of Keeper_checkpoint_store.checkpoint_ref_load_error
  | Content_mismatch of { path : string }
  | Reference_mismatch of
      { expected : Keeper_checkpoint_ref.t
      ; actual : Keeper_checkpoint_ref.t
      }
  | Load_lock_failed of File_lock_eio.durable_lock_error

type put_error =
  | Existing_object_invalid of
      { path : string
      ; error : load_error
      }
  | Write_not_committed of Keeper_fs.durable_write_error
  | Transaction_outcome_unknown of
      { write_error : Keeper_fs.durable_write_error
      ; observed : load_error
      }
  | Object_lock_failed of
      { error : File_lock_eio.durable_lock_error
      ; observed : load_error
      }
  | Access_failed of exn

val object_path :
  base_path:string ->
  keeper_name:Keeper_id.Keeper_name.t ->
  reference:Keeper_checkpoint_ref.t ->
  string

val put :
  base_path:string ->
  keeper_name:Keeper_id.Keeper_name.t ->
  Keeper_checkpoint_store.exact_checkpoint_snapshot ->
  (put_status, put_error) result

val load :
  base_path:string ->
  keeper_name:Keeper_id.Keeper_name.t ->
  reference:Keeper_checkpoint_ref.t ->
  (Keeper_checkpoint_store.exact_checkpoint_snapshot, load_error) result

module For_testing : sig
  val put :
    before_stage:(Keeper_fs.durable_write_stage -> unit) ->
    base_path:string ->
    keeper_name:Keeper_id.Keeper_name.t ->
    Keeper_checkpoint_store.exact_checkpoint_snapshot ->
    (put_status, put_error) result
end
