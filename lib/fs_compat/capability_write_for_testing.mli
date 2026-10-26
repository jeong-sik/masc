(** Workspace-only typed fault boundary for capability-write feature tests.
    This module is not installed with [masc.fs_compat]. *)

val replace_capability_file
  :  before_stage:(Fs_compat.capability_write_stage -> unit)
  -> recovery:Fs_compat.Publication_recovery.t
  -> parent:Eio.Fs.dir_ty Eio.Path.t
  -> target:Fs_compat.capability_publication_target
  -> string
  -> (unit, Fs_compat.capability_write_error) result

val create_capability_file_exclusive
  :  before_stage:(Fs_compat.capability_write_stage -> unit)
  -> recovery:Fs_compat.Publication_recovery.t
  -> parent:Eio.Fs.dir_ty Eio.Path.t
  -> target:Fs_compat.capability_publication_target
  -> string
  -> (unit, Fs_compat.capability_write_error) result

val sync_directory_capability
  :  before_stage:(Fs_compat.capability_write_stage -> unit)
  -> _ Eio.Path.t
  -> (unit, Fs_compat.capability_directory_sync_error) result

val create_capability_directory_exclusive
  :  before_stage:(Fs_compat.capability_write_stage -> unit)
  -> recovery:Fs_compat.Publication_recovery.t
  -> parent:Eio.Fs.dir_ty Eio.Path.t
  -> target:Fs_compat.capability_publication_target
  -> Fs_compat.directory_payload
  -> (unit, Fs_compat.capability_write_error) result
