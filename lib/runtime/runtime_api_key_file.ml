(* HIGH-RISK-UNREVIEWED: see the interface. *)

module Layout = Runtime_account_home_layout

let ( let* ) = Result.bind

(* ---- a key ---- *)

type key = string

let is_control = function
  | '\000' .. '\031' | '\127' -> true
  | _ -> false
;;

(* A JSON object or array is a credential document. Anything else that reads
   as JSON, a number or a quoted string, is one value and may be a key. *)
let holds_json value =
  match Yojson.Safe.from_string value with
  | `Assoc _ | `List _ -> true
  | (_ : Yojson.Safe.t) -> false
  | exception Yojson.Json_error _ -> false
;;

let key_of_string text =
  let key = String.trim text in
  if String.equal key "" || String.exists is_control key || holds_json key
  then None
  else Some key
;;

let value key = key

(* ---- reading ---- *)

(* The permission bits of the group and of others. *)
let group_and_others = 0o077

type file_error =
  | Relative_path
  | Not_an_owned_regular_file
  | Missing
  | Not_private
  | Empty
  | Json_document

let read_file path =
  if Filename.is_relative path
  then Error Relative_path
  else (
    match
      Fs_compat.load_owned_regular_file_with_snapshot
        ~ownership_root:(Filename.dirname path)
        path
    with
    | Error (_ : Fs_compat.owned_regular_file_read_error) -> Error Not_an_owned_regular_file
    | Ok None -> Error Missing
    | Ok (Some { Fs_compat.content; snapshot }) ->
      if snapshot.Fs_compat.owner_uid <> Unix.geteuid ()
         || snapshot.Fs_compat.permissions land group_and_others <> 0
      then Error Not_private
      else (
        let value = String.trim content in
        if String.equal value ""
        then Error Empty
        else if holds_json value
        then Error Json_document
        else Ok value))
;;

type unreadable =
  | Path_not_absolute
  | Not_a_regular_file
  | Open_to_others
  | Not_a_key

type read_error =
  | Key_missing
  | Key_unreadable of unreadable

let read path =
  match read_file path with
  | Ok content ->
    (match key_of_string content with
     | Some key -> Ok key
     | None -> Error (Key_unreadable Not_a_key))
  | Error Missing -> Error Key_missing
  | Error Relative_path -> Error (Key_unreadable Path_not_absolute)
  | Error Not_an_owned_regular_file -> Error (Key_unreadable Not_a_regular_file)
  | Error Not_private -> Error (Key_unreadable Open_to_others)
  | Error (Empty | Json_document) -> Error (Key_unreadable Not_a_key)
;;

let read_error_code = function
  | Key_missing -> "key_missing"
  | Key_unreadable (_ : unreadable) -> "key_unreadable"
;;

let read_error_to_string = function
  | Key_missing -> "the API key file is missing"
  | Key_unreadable Path_not_absolute -> "the API key file must use an absolute path"
  | Key_unreadable Not_a_regular_file ->
    "the API key file could not be read as an owned regular file"
  | Key_unreadable Open_to_others ->
    "the API key file must be owned by the current user and private"
  | Key_unreadable Not_a_key -> "the API key file does not hold one raw API key"
;;

(* ---- writing ---- *)

type write_error =
  | Root_unavailable of string
  | Folder_not_private of string
  | Generation_taken
  | Not_written of string

let folder_permissions = 0o700
let file_permissions = 0o600

(* The file a write fills before it puts it in place, beside the place of the
   key. Its name is of the generation, so a second write of a generation
   meets it. *)
let unplaced_suffix = ".tmp"
let thread_label = "api-key-file-write"

(* Runs [work] on [descriptor] and closes it. A failure of the close after a
   failure of [work] is dropped: the first failure is the one reported. *)
let with_descriptor descriptor work =
  match work descriptor with
  | value ->
    Unix.close descriptor;
    value
  | exception exn ->
    let backtrace = Printexc.get_raw_backtrace () in
    (try Unix.close descriptor with
     | Unix.Unix_error _ -> ());
    Printexc.raise_with_backtrace exn backtrace
;;

let sync_folder path =
  with_descriptor (Unix.openfile path [ Unix.O_RDONLY; Unix.O_CLOEXEC ] 0) Unix.fsync
;;

(* Makes the folder when it is not there, and syncs the folder it is in when
   it made it. A folder that was there is taken only as a directory of this
   user closed to the others. *)
let private_folder path =
  let made =
    match Unix.mkdir path folder_permissions with
    | () -> true
    | exception Unix.Unix_error (Unix.EEXIST, _, _) -> false
  in
  let stats = Unix.lstat path in
  let is_directory =
    match stats.Unix.st_kind with
    | Unix.S_DIR -> true
    | Unix.S_REG | Unix.S_CHR | Unix.S_BLK | Unix.S_LNK | Unix.S_FIFO | Unix.S_SOCK -> false
  in
  if is_directory
     && stats.Unix.st_uid = Unix.geteuid ()
     && stats.Unix.st_perm land group_and_others = 0
  then (
    if made then sync_folder (Filename.dirname path);
    Ok ())
  else Error (Folder_not_private path)
;;

let write_all descriptor text =
  let length = String.length text in
  let rec from offset =
    if offset < length
    then (
      match Unix.single_write_substring descriptor text offset (length - offset) with
      | 0 -> raise (Unix.Unix_error (Unix.EIO, "single_write_substring", ""))
      | written -> from (offset + written)
      | exception Unix.Unix_error (Unix.EINTR, _, _) -> from offset)
  in
  from 0
;;

(* The file that was not put in place holds the key, so it does not stay. A
   failure to remove it is dropped: the failure that led here is the one
   reported, and whoever asked for the write removes the folder of the
   account. *)
let remove_unplaced path =
  try Unix.unlink path with
  | Unix.Unix_error _ -> ()
;;

let failed_after ~unplaced exn =
  let backtrace = Printexc.get_raw_backtrace () in
  remove_unplaced unplaced;
  Printexc.raise_with_backtrace exn backtrace
;;

let place ~file key =
  let dir = Filename.dirname file in
  let* () = private_folder (Filename.dirname dir) in
  let* () = private_folder dir in
  let unplaced = file ^ unplaced_suffix in
  match
    Unix.openfile
      unplaced
      [ Unix.O_WRONLY; Unix.O_CREAT; Unix.O_EXCL; Unix.O_CLOEXEC ]
      file_permissions
  with
  | exception Unix.Unix_error (Unix.EEXIST, _, _) -> Error Generation_taken
  | descriptor ->
    (match
       with_descriptor descriptor (fun descriptor ->
         (* The mode of the open is narrowed by the umask of the process. *)
         Unix.fchmod descriptor file_permissions;
         write_all descriptor key;
         Unix.fsync descriptor)
     with
     | exception (Unix.Unix_error _ as exn) -> failed_after ~unplaced exn
     | () ->
       (match Fs_compat.rename_noreplace unplaced file with
        | exception Unix.Unix_error (Unix.EEXIST, _, _) ->
          remove_unplaced unplaced;
          Error Generation_taken
        | exception (Unix.Unix_error _ as exn) -> failed_after ~unplaced exn
        | () ->
          sync_folder dir;
          Ok ()))
;;

let write ~runtime_root ~account_id ~generation key =
  match Layout.key_file ~runtime_root ~account_id ~generation with
  | Error detail -> Error (Root_unavailable detail)
  | Ok file ->
    Fs_compat.Systhread_host.run ~label:thread_label (fun () ->
      match place ~file key with
      | result -> result
      | exception Unix.Unix_error (error, call, argument) ->
        Error (Not_written (Printf.sprintf "%s %s: %s" call argument (Unix.error_message error))))
;;
