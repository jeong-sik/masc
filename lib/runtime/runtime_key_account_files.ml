(* HIGH-RISK-UNREVIEWED: see the interface. *)

module Layout = Runtime_account_home_layout

let ( let* ) = Result.bind

(* The keys of stage 1 are keys of Claude Code. *)
let client = Layout.Claude_home
let thread_label = "key-account-files"

let unix_detail error call argument =
  Printf.sprintf "%s %s: %s" call argument (Unix.error_message error)
;;

type make_error =
  | Home_not_made of string
  | Key_not_written of Runtime_api_key_file.write_error

let make_home ~runtime_root ~account_id =
  Fs_compat.Systhread_host.run ~label:thread_label (fun () ->
    match
      Runtime_account_home_folder.make
        ~runtime_root
        ~account_id:(Authz_types.Provider_account_id.to_string account_id)
        ~client
    with
    | Ok (_ : string) -> Ok ()
    | Error detail -> Error detail
    | exception Unix.Unix_error (error, call, argument) -> Error (unix_detail error call argument))
;;

let make ~runtime_root ~account_id ~generation key =
  match make_home ~runtime_root ~account_id with
  | Error detail -> Error (Home_not_made detail)
  | Ok () ->
    Runtime_api_key_file.write ~runtime_root ~account_id ~generation key
    |> Result.map_error (fun error -> Key_not_written error)
;;

let make_error_detail = function
  | Home_not_made detail -> "the home was not made: " ^ detail
  | Key_not_written (Runtime_api_key_file.Root_unavailable detail) ->
    "no key file is spelled under the runtime root: " ^ detail
  | Key_not_written (Runtime_api_key_file.Folder_not_private path) ->
    "a folder of the keys is no private folder of this user: " ^ path
  | Key_not_written Runtime_api_key_file.Generation_taken -> "a file of the generation was there"
  | Key_not_written (Runtime_api_key_file.Not_written detail) -> "the key file was not written: " ^ detail
;;

type remove_error =
  | Key_not_removed of string
  | Home_not_removed of string

(* The folder [path] is in, synced. A folder that is not there, or a path
   that leads through something that is no folder, held nothing of [path]. *)
let sync_parent path =
  match Runtime_account_home_folder.sync_folder (Filename.dirname path) with
  | () -> ()
  | exception Unix.Unix_error ((Unix.ENOENT | Unix.ENOTDIR), _, _) -> ()
;;

(* [Fs_compat.remove_tree] removes a link without following it, and a path
   that is gone is no error. It chooses the thread it runs on, so it is
   called from the fiber. Whether the tree went is read from it after. *)
let removed path =
  match
    Fs_compat.remove_tree path;
    Fs_compat.Systhread_host.run ~label:thread_label (fun () ->
      match Unix.lstat path with
      | exception Unix.Unix_error (Unix.ENOENT, _, _) ->
        sync_parent path;
        Ok ()
      (* As [named] reads it: a path through something that is no folder
         names nothing. Nothing of it was removed, so there is no folder to
         sync, and what stands in the place of the folder is not opened:
         the open of a FIFO waits for a writer that never comes. *)
      | exception Unix.Unix_error (Unix.ENOTDIR, _, _) -> Ok ()
      | (_ : Unix.stats) -> Error (path ^ ": it is still there"))
  with
  | result -> result
  | exception Sys_error detail -> Error detail
  | exception Unix.Unix_error (error, call, argument) -> Error (unix_detail error call argument)
;;

(* Whether [path] names anything, a link included. *)
let named path =
  match Unix.lstat path with
  | (_ : Unix.stats) -> Ok true
  | exception Unix.Unix_error ((Unix.ENOENT | Unix.ENOTDIR), _, _) -> Ok false
  | exception Unix.Unix_error (error, call, argument) -> Error (unix_detail error call argument)
;;

(* A runtime root that is not there holds no file of any account: no login
   and no registration made it, or it was taken away whole. *)
let root_there ~runtime_root =
  Fs_compat.Systhread_host.run ~label:thread_label (fun () -> named runtime_root)
;;

let home_of ~runtime_root ~account_id =
  Layout.home ~runtime_root client ~account_id:(Authz_types.Provider_account_id.to_string account_id)
;;

(* The folder of the keys of the account with everything in it, under a
   runtime root that is there. *)
let keys_removed ~runtime_root ~account_id =
  let* keys = Layout.key_dir ~runtime_root ~account_id in
  removed keys
;;

let remove_keys ~runtime_root ~account_id =
  let* there = root_there ~runtime_root in
  if there then keys_removed ~runtime_root ~account_id else Ok ()
;;

let remove ~runtime_root ~account_id =
  match root_there ~runtime_root with
  | Error detail -> Error (Key_not_removed detail)
  | Ok false -> Ok ()
  | Ok true ->
    (match keys_removed ~runtime_root ~account_id with
     | Error detail -> Error (Key_not_removed detail)
     | Ok () ->
       (match
          let* home = home_of ~runtime_root ~account_id in
          removed home
        with
        | Error detail -> Error (Home_not_removed detail)
        | Ok () -> Ok ()))
;;

let present ~runtime_root ~account_id =
  let* there = root_there ~runtime_root in
  if not there
  then Ok false
  else
    let* keys = Layout.key_dir ~runtime_root ~account_id in
    let* home = home_of ~runtime_root ~account_id in
    Fs_compat.Systhread_host.run ~label:thread_label (fun () ->
      let* keys_there = named keys in
      if keys_there then Ok true else named home)
;;

type key_state =
  | Key_readable
  | Key_not_read of Runtime_api_key_file.read_error
  | Key_not_looked_at of string

let key_state ~runtime_root ~account_id ~generation =
  match root_there ~runtime_root with
  | Error detail -> Key_not_looked_at detail
  | Ok false -> Key_not_read Runtime_api_key_file.Key_missing
  | Ok true ->
    (match Layout.key_file ~runtime_root ~account_id ~generation with
     | Error detail -> Key_not_looked_at detail
     | Ok file ->
       (match Runtime_api_key_file.read file with
        | Ok (_ : Runtime_api_key_file.key) -> Key_readable
        | Error error -> Key_not_read error))
;;

(* ---- the replacement of a key ---- *)

(* The names in the folder [keys], in their order: a folder gives them in
   no order of its own, and what is reported of them is the same at each
   asking. A folder that is not there holds none. What stands in its place
   and is no folder is not read: a link would lead to the files of another
   place. *)
let names_in keys =
  match Unix.lstat keys with
  | exception Unix.Unix_error ((Unix.ENOENT | Unix.ENOTDIR), _, _) -> Ok []
  | exception Unix.Unix_error (error, call, argument) -> Error (unix_detail error call argument)
  | { Unix.st_kind = Unix.S_DIR; _ } ->
    (match Sys.readdir keys with
     | names -> Ok (List.sort String.compare (Array.to_list names))
     | exception Sys_error detail -> Error detail)
  | { Unix.st_kind = Unix.S_REG | Unix.S_CHR | Unix.S_BLK | Unix.S_LNK | Unix.S_FIFO | Unix.S_SOCK; _ }
    -> Error (keys ^ ": it is not a folder")
;;

type other_keys_swept =
  { gone : int
  ; stayed : string option
  }

let remove_other_keys ~runtime_root ~account_id ~generation =
  let* there = root_there ~runtime_root in
  if not there
  then Ok { gone = 0; stayed = None }
  else
    let* kept = Layout.key_file ~runtime_root ~account_id ~generation in
    let keys = Filename.dirname kept in
    let* names = Fs_compat.Systhread_host.run ~label:thread_label (fun () -> names_in keys) in
    (* Each of them can hold a key, so each is tried whatever became of the
       one before it. The first that stayed is the one reported. *)
    Ok
      (List.fold_left
         (fun { gone; stayed } name ->
           if String.equal name (Filename.basename kept)
           then { gone; stayed }
           else (
             match removed (Filename.concat keys name), stayed with
             | Ok (), (None | Some (_ : string)) -> { gone = gone + 1; stayed }
             | Error detail, None -> { gone; stayed = Some detail }
             | Error (_ : string), Some (_ : string) -> { gone; stayed }))
         { gone = 0; stayed = None }
         names)
;;

type other_keys =
  | Other_keys_removed
  | Other_keys_left of string

let replace ~runtime_root ~account_id ~generation key =
  match make ~runtime_root ~account_id ~generation key with
  | Error error -> Error error
  | Ok () ->
    (match remove_other_keys ~runtime_root ~account_id ~generation with
     | Ok { gone = (_ : int); stayed = None } -> Ok Other_keys_removed
     | Ok { gone = (_ : int); stayed = Some detail } | Error detail -> Ok (Other_keys_left detail))
;;
