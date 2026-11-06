module Objects = Agent_core.Checkpoint_objects
open Keeper_checkpoint_store_history_files
open Keeper_checkpoint_store_decode
open Keeper_checkpoint_store_summary
open Keeper_checkpoint_store_session
open Keeper_checkpoint_store_canonical
open Keeper_checkpoint_store_exact_snapshot
open Keeper_checkpoint_store_cas_save

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

let persist_error_to_string = function
  | Persist_session_unavailable detail -> "checkpoint session unavailable: " ^ detail
  | Persist_unencodable error -> "checkpoint cannot be encoded: " ^ Agent_core.Error.to_string error
  | Persist_content_mismatch { reference; content } ->
    Printf.sprintf "checkpoint content %s does not match its reference %s" content reference.sha256
  | Persist_objects_failed error -> Keeper_checkpoint_object_store.write_error_to_string error

let persist_exact_snapshot ~session_dir snapshot =
  match
    with_session_lock ~session_dir (fun session_dir ->
      match plan_for_session ~session_dir ~boundary:Objects.Turn_continues snapshot.checkpoint with
      | Error error -> Error (Persist_unencodable error)
      | Ok plan when not (String.equal (plan.content :> string) snapshot.reference.sha256) ->
        Error
          (Persist_content_mismatch
             { reference = snapshot.reference; content = (plan.content :> string) })
      | Ok plan ->
        (match Keeper_checkpoint_object_store.write ~session_dir plan.objects with
         | Error error -> Error (Persist_objects_failed error)
         | Ok (_ : int) -> Ok plan.head_bytes))
  with
  | Ok result -> result
  | Error detail -> Error (Persist_session_unavailable detail)

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

let backup_error_to_string = function
  | Backup_canonical_unreadable error -> checkpoint_load_error_to_string error
  | Backup_canonical_absent -> "no canonical checkpoint to back up"
  | Backup_content_changed { expected; actual } ->
    Printf.sprintf "the canonical checkpoint is %s, not the source %s" actual expected
  | Backup_object_unreadable { digest; detail } ->
    Printf.sprintf "checkpoint object %s cannot be backed up: %s" digest detail
  | Backup_file_conflict path -> path ^ " already holds other bytes"
  | Backup_write_failed { path; error } ->
    Printf.sprintf "%s: %s" path (Keeper_fs.durable_write_error_to_string error)
  | Backup_read_back_mismatch path -> path ^ " does not read back as written"

let back_up_canonical ~session_dir ~session_id ~ownership_root ~backup_dir ~content =
  (* A file already in the backup is kept when it holds these bytes, so a
     retried backup of one checkpoint succeeds. *)
  let copy ~path bytes =
    match Fs_compat.load_file_opt path with
    | Some existing when String.equal existing bytes -> Ok ()
    | Some _ -> Error (Backup_file_conflict path)
    | None ->
      (match Keeper_fs.save_bytes_durable_atomic ~ownership_root path bytes with
       | Error error -> Error (Backup_write_failed { path; error })
       | Ok () ->
         (match Fs_compat.load_file_opt path with
          | Some written when String.equal written bytes -> Ok ()
          | Some _ | None -> Error (Backup_read_back_mismatch path)))
  in
  let rec copy_objects total = function
    | [] -> Ok total
    | (digest : Objects.digest) :: rest ->
      let unreadable detail =
        Error (Backup_object_unreadable { digest = (digest :> string); detail })
      in
      (match Keeper_checkpoint_object_store.read ~session_dir digest with
       | Error detail -> unreadable detail
       | Ok None -> unreadable "missing"
       | Ok (Some bytes)
         when not (String.equal (Objects.digest_of_bytes bytes :> string) (digest :> string)) ->
         unreadable "its bytes have another digest"
       | Ok (Some bytes) ->
         (match
            copy ~path:(Keeper_checkpoint_object_store.path ~session_dir:backup_dir digest) bytes
          with
          | Error _ as error -> error
          | Ok () -> copy_objects (total + String.length bytes) rest))
  in
  if not (leaf_is_real_segment session_id)
  then Error (Backup_canonical_unreadable (Store_error "session_id is not a real path segment"))
  else (
    match load_canonical_bytes_strict (agent_core_checkpoint_path ~session_dir ~session_id) with
    | Error error -> Error (Backup_canonical_unreadable error)
    | Ok None -> Error Backup_canonical_absent
    | Ok (Some ((_ : canonical_identity), head_bytes)) ->
      (match head_of_bytes_off_scheduler head_bytes with
       | Error error -> Error (Backup_canonical_unreadable (classify_objects_error error))
       | Ok head ->
         let actual = (Objects.head_content_digest head :> string) in
         if not (String.equal actual content)
         then Error (Backup_content_changed { expected = content; actual })
         else (
           (* The objects first, then the head that names them. *)
           match Keeper_checkpoint_object_store.walk_segments ~session_dir head with
           | Keeper_checkpoint_object_store.Segment_unreachable { digest; detail } ->
             Error (Backup_object_unreadable { digest = (digest :> string); detail })
           | Keeper_checkpoint_object_store.Segments_reached reached ->
           match copy_objects 0 (Objects.head_objects head @ reached) with
           | Error _ as error -> error
           | Ok object_bytes ->
             let backup_head = agent_core_checkpoint_path ~session_dir:backup_dir ~session_id in
             (match copy ~path:backup_head head_bytes with
              | Error _ as error -> error
              | Ok () -> Ok { backup_head; backup_bytes = object_bytes + String.length head_bytes }))))
