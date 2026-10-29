(* RFC-0476 §3.2: the message objects and turn bundles a checkpoint head
   names, one file each at [<session_dir>/objects/<aa>/<sha256>]. A file is
   written once and never changed; only the object sweep removes one. *)

module Objects = Agent_core.Checkpoint_objects

let dirname = "objects"

let path ~session_dir (digest : Objects.digest) =
  let hex = (digest :> string) in
  Filename.concat
    (Filename.concat (Filename.concat session_dir dirname) (String.sub hex 0 2))
    hex
;;

let ownership_root ~session_dir = Filename.dirname session_dir

type write_error =
  { digest : Objects.digest
  ; error : Keeper_fs.durable_write_error
  }

let write_error_to_string { digest; error } =
  Printf.sprintf "checkpoint object %s write failed: %s" (digest :> string)
    (Keeper_fs.durable_write_error_to_string error)
;;

(* Every object is written whole, even when a file of that name is there:
   the atomic write syncs the directory entry too, which a file a failed
   save left behind may not have. *)
let write ~session_dir objects =
  let rec go written = function
    | [] -> Ok written
    | (digest, bytes) :: rest ->
      (match
         Keeper_fs.save_bytes_durable_atomic
           ~ownership_root:(ownership_root ~session_dir)
           (path ~session_dir digest)
           bytes
       with
       | Error error -> Error { digest; error }
       | Ok () -> go (written + String.length bytes) rest)
  in
  go 0 objects
;;

let present ~session_dir digest =
  match Unix.lstat (path ~session_dir digest) with
  | { Unix.st_kind = Unix.S_REG; _ } -> true
  | { Unix.st_kind = Unix.S_DIR | Unix.S_CHR | Unix.S_BLK | Unix.S_LNK | Unix.S_FIFO | Unix.S_SOCK; _ } ->
    false
  | exception Unix.Unix_error ((_ : Unix.error), _, _) -> false
;;

let read ~session_dir digest =
  match
    Fs_compat.load_owned_regular_file
      ~ownership_root:(ownership_root ~session_dir)
      (path ~session_dir digest)
  with
  | Ok bytes -> Ok bytes
  | Error error -> Error (Fs_compat.owned_regular_file_read_error_to_string error)
;;
