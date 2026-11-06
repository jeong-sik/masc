(** Copies of a checkpoint made for someone else: the head of an exact
    snapshot for another store to keep, and a backup of the canonical head
    with the objects it names.

    [persist_exact_snapshot] makes the objects an exact snapshot names
    durable in the session and returns the head bytes for another store to
    keep; [persist_error] says why it could not and [persist_error_to_string]
    renders it. [back_up_canonical] copies the canonical head and every
    object it names into a backup directory, laid out as the session holds
    them, when the canonical still has the expected content, and returns the
    backup head's path and the bytes copied as a [canonical_backup];
    [backup_error] says why it could not and [backup_error_to_string]
    renders it. [Keeper_checkpoint_store] includes this module. *)

open Keeper_checkpoint_store_exact_snapshot
open Keeper_checkpoint_store_decode

(* A snapshot written as a head another store keeps (a Gate preparation),
   with the objects it names durable in the session first. *)
type persist_error =
  | Persist_session_unavailable of string
  | Persist_unencodable of Agent_core.Error.t
  | Persist_content_mismatch of
      { reference : Keeper_checkpoint_ref.t
      ; content : string
      }
  | Persist_objects_failed of Keeper_checkpoint_object_store.write_error

val persist_error_to_string : persist_error -> string

val persist_exact_snapshot :
  session_dir:string ->
  exact_checkpoint_snapshot ->
  (string, persist_error) result

(* A copy of the canonical head and every object it names, laid out as the
   session holds them, so copying the backup over the session directory puts
   the checkpoint back (docs/CHECKPOINT-PURGE-RUNBOOK.md). *)
type canonical_backup =
  { backup_head : string
  ; backup_bytes : int
  }

type backup_error =
  | Backup_canonical_unreadable of checkpoint_load_error
  | Backup_canonical_absent
  | Backup_content_changed of
      { expected : string
      ; actual : string
      }
  | Backup_object_unreadable of
      { digest : string
      ; detail : string
      }
  | Backup_file_conflict of string
  | Backup_write_failed of
      { path : string
      ; error : Keeper_fs.durable_write_error
      }
  | Backup_read_back_mismatch of string

val backup_error_to_string : backup_error -> string

val back_up_canonical :
  session_dir:string ->
  session_id:string ->
  ownership_root:string ->
  backup_dir:string ->
  content:string -> (canonical_backup, backup_error) result
