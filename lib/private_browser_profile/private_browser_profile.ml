open Result.Syntax

let failure_text = function
  | Unix.Unix_error (error, call, argument) ->
    Some (Printf.sprintf "%s %s: %s" call argument (Unix.error_message error))
  | Sys_error detail -> Some detail
  | _ -> None

let rec remove_entry ~label path =
  let info = Unix.lstat path in
  if info.Unix.st_uid <> Unix.geteuid () then
    Error (Printf.sprintf "%s entry %s must be owned by uid %d; it is owned by uid %d"
      label path (Unix.geteuid ()) info.st_uid)
  else match info.st_kind with
  | Unix.S_DIR ->
    let* () = Array.fold_left (fun result name -> let* () = result in
      remove_entry ~label (Filename.concat path name)) (Ok ()) (Sys.readdir path) in
    Unix.rmdir path; Ok ()
  | Unix.S_LNK -> Unix.unlink path; Ok ()
  | Unix.S_REG when info.st_nlink = 1 -> Unix.unlink path; Ok ()
  | Unix.S_REG | Unix.S_CHR | Unix.S_BLK | Unix.S_FIFO | Unix.S_SOCK as kind ->
    Error (Printf.sprintf
      "%s entry %s must be a directory, a symbolic link or a regular file with exactly one link; it is a %s with %d links"
      label path (Resource_requirement.kind_name kind) info.st_nlink)

let remove_profile ~label ~last path =
  let info = Unix.lstat path in
  if info.Unix.st_uid <> Unix.geteuid () then
    Error (Printf.sprintf "%s %s must be owned by uid %d; it is owned by uid %d"
      label path (Unix.geteuid ()) info.st_uid)
  else match info.st_kind with
  | Unix.S_DIR ->
    let others () = Sys.readdir path |> Array.to_list
      |> List.filter (fun name -> not (String.equal name last)) |> List.sort String.compare in
    let* () = List.fold_left (fun result name -> let* () = result in
      remove_entry ~label (Filename.concat path name)) (Ok ()) (others ()) in
    (match others () with
     | [] ->
       let last_path = Filename.concat path last in
       let* () = match Unix.lstat last_path with
         | _ -> remove_entry ~label last_path
         | exception Unix.Unix_error (Unix.ENOENT, _, _) -> Ok () in
       Unix.rmdir path; Ok ()
     | appeared ->
       Error (Printf.sprintf "%s %s gained %s while it was being removed; %s is kept"
         label path (String.concat ", " appeared) last))
  | Unix.S_REG | Unix.S_CHR | Unix.S_BLK | Unix.S_LNK | Unix.S_FIFO | Unix.S_SOCK as kind ->
    Error (Printf.sprintf "%s %s must be a directory; it is a %s"
      label path (Resource_requirement.kind_name kind))

let remove ~label ?last path =
  match (match last with
      | None -> remove_entry ~label path
      | Some last -> remove_profile ~label ~last path) with
  | result -> result
  | exception exn ->
    (match failure_text exn with
     | Some detail -> Error (Printf.sprintf "%s %s was not removed: %s" label path detail)
     | None -> raise exn)

(* Every lock file and holder operation runs under [gate], so the registry of
   open lock files and every descriptor in it change together. *)
let gate = Mutex.create ()

type lock_file = {
  fd : Unix.file_descr;
  file : int * int;
  mutable extras : Unix.file_descr list;
  mutable closed : bool;
}

(* The open lock files of this process by (device, inode). A descriptor that
   turns out to name a registered inode is never closed on its own: it joins
   that lock file and closes with it. *)
let registry : (int * int, lock_file) Hashtbl.t = Hashtbl.create 8

external open_directory : string -> Unix.file_descr = "masc_private_profile_open_directory"
external stat_child : Unix.file_descr -> string -> (int * int) option = "masc_private_profile_stat_child"
external open_child : Unix.file_descr -> string -> Unix.file_descr = "masc_private_profile_open_child"

let owned_by_user (info : Unix.stats) = info.st_uid = Unix.geteuid ()
let already_open path = Error (Printf.sprintf "profile lock %s is already open in this process" path)

let checked_lock_file ~path (info : Unix.stats) =
  match info.st_kind with
  | Unix.S_REG when not (owned_by_user info) ->
    Error (Printf.sprintf "profile lock %s must be owned by uid %d; it is owned by uid %d"
      path (Unix.geteuid ()) info.st_uid)
  | Unix.S_REG when info.st_nlink <> 1 ->
    Error (Printf.sprintf "profile lock %s must have exactly one link; it has %d" path info.st_nlink)
  | Unix.S_REG -> Ok ()
  | Unix.S_DIR | Unix.S_CHR | Unix.S_BLK | Unix.S_LNK | Unix.S_FIFO | Unix.S_SOCK as kind ->
    Error (Printf.sprintf "profile lock %s must be a regular file; it is a %s"
      path (Resource_requirement.kind_name kind))

let open_registered ~path directory name =
  match open_child directory name with
  | exception Unix.Unix_error (Unix.ELOOP, _, _) ->
    Error (Printf.sprintf "profile lock %s must be a regular file; it is a symbolic link" path)
  | exception Unix.Unix_error (error, _, _) ->
    Error (Printf.sprintf "profile lock %s cannot be opened: %s" path (Unix.error_message error))
  | fd ->
    let info = Unix.fstat fd in
    let file = (info.st_dev, info.st_ino) in
    match Hashtbl.find_opt registry file with
    | Some opened -> opened.extras <- fd :: opened.extras; already_open path
    | None ->
      match checked_lock_file ~path info with
      | Error _ as refused -> Unix.close fd; refused
      | Ok () ->
        let lock_file = {fd; file; extras=[]; closed=false} in
        Hashtbl.add registry file lock_file;
        Ok lock_file

let open_lock ~profile ~name =
  let path = Filename.concat profile name in
  Mutex.protect gate (fun () ->
    match open_directory profile with
    | exception Unix.Unix_error (error, _, _) ->
      Error (Printf.sprintf "profile %s cannot be opened: %s" profile (Unix.error_message error))
    | directory ->
      Fun.protect ~finally:(fun () -> Unix.close directory) (fun () ->
        let info = Unix.fstat directory in
        if not (owned_by_user info) then
          Error (Printf.sprintf "profile %s must be owned by uid %d; it is owned by uid %d"
            profile (Unix.geteuid ()) info.st_uid)
        else match stat_child directory name with
        | exception Unix.Unix_error (error, _, _) ->
          Error (Printf.sprintf "profile lock %s cannot be read: %s" path (Unix.error_message error))
        | Some file when Hashtbl.mem registry file -> already_open path
        | Some _ | None -> open_registered ~path directory name))

let close_lock lock_file =
  Mutex.protect gate (fun () ->
    if not lock_file.closed then (
      lock_file.closed <- true;
      Hashtbl.remove registry lock_file.file;
      List.iter Unix.close lock_file.extras;
      Unix.close lock_file.fd))

type raw
type holder = {
  raw : raw;
  of_file : int * int;
  mutable released : bool;
}

type inspection =
  | Unlocked
  | Held_by of holder
  | Changing
  | Unreadable of string

external capture_raw : Unix.file_descr -> int * raw = "masc_private_profile_capture"
external signal_raw : raw -> Unix.file_descr -> bool -> int = "masc_private_profile_signal"
external same_raw : raw -> raw -> bool = "masc_private_profile_same"
external pid_raw : raw -> int = "masc_private_profile_pid"
external executable_raw : raw -> string option = "masc_private_profile_executable"
external release_raw : raw -> unit = "masc_private_profile_release"

let closed_text = "the profile lock file is closed"

let inspect lock_file =
  Mutex.protect gate (fun () ->
    if lock_file.closed then Unreadable closed_text
    else match capture_raw lock_file.fd with
      | 0, raw -> Held_by {raw; of_file=lock_file.file; released=false}
      | 1, _ -> Unlocked
      | 2, _ -> Changing
      | 3, _ -> Unreadable "this platform cannot capture a process identity"
      | 5, _ -> Unreadable "the profile lock is held by a process this one cannot see"
      | _, _ -> Unreadable "the kernel did not report the profile lock holder")

type lock_result =
  | Locked
  | Held_elsewhere

let lock lock_file =
  Mutex.protect gate (fun () ->
    if lock_file.closed then Error closed_text
    else match Unix.lockf lock_file.fd Unix.F_TLOCK 0 with
      | () -> Ok Locked
      | exception Unix.Unix_error ((Unix.EACCES | Unix.EAGAIN), _, _) -> Ok Held_elsewhere
      | exception Unix.Unix_error (error, _, _) ->
        Error (Printf.sprintf "profile lock cannot be taken: %s" (Unix.error_message error)))

let pid holder = pid_raw holder.raw
let executable holder = executable_raw holder.raw
let same_process left right =
  Mutex.protect gate (fun () ->
    not left.released && not right.released && same_raw left.raw right.raw)

type signal_error =
  | Holder_changed
  | Other_lock_file
  | Lock_file_closed
  | Released
  | Unsupported
  | Failed

let signal holder lock_file ~kill =
  Mutex.protect gate (fun () ->
    if holder.of_file <> lock_file.file then Error Other_lock_file
    else if holder.released then Error Released
    else if lock_file.closed then Error Lock_file_closed
    else match signal_raw holder.raw lock_file.fd kill with
      | 0 -> Ok ()
      | 2 -> Error Holder_changed
      | 3 -> Error Unsupported
      | _ -> Error Failed)

let request_termination holder lock_file = signal holder lock_file ~kill:false
let request_kill holder lock_file = signal holder lock_file ~kill:true

let release holder =
  Mutex.protect gate (fun () ->
    if not holder.released then (holder.released <- true; release_raw holder.raw))
