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

let make ~runtime_root ~account_id ~generation key =
  let home =
    Fs_compat.Systhread_host.run ~label:thread_label (fun () ->
      match
        Runtime_account_home_folder.make
          ~runtime_root
          ~account_id:(Authz_types.Provider_account_id.to_string account_id)
          ~client
      with
      | result -> result
      | exception Unix.Unix_error (error, call, argument) -> Error (unix_detail error call argument))
  in
  match home with
  | Error detail -> Error (Home_not_made detail)
  | Ok (_ : string) ->
    Runtime_api_key_file.write ~runtime_root ~account_id ~generation key
    |> Result.map_error (fun error -> Key_not_written error)
;;

type remove_error =
  | Key_not_removed of string
  | Home_not_removed of string

(* The folder [path] is in, synced. A folder that is not there held nothing
   of [path]. *)
let sync_parent path =
  match Runtime_account_home_folder.sync_folder (Filename.dirname path) with
  | () -> ()
  | exception Unix.Unix_error (Unix.ENOENT, _, _) -> ()
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

let remove ~runtime_root ~account_id =
  match root_there ~runtime_root with
  | Error detail -> Error (Key_not_removed detail)
  | Ok false -> Ok ()
  | Ok true ->
    (match
       let* keys = Layout.key_dir ~runtime_root ~account_id in
       removed keys
     with
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
