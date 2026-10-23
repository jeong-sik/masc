let ( let* ) = Result.bind

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
    let names = Array.to_list (Sys.readdir path) in
    let first = List.filter (fun name -> not (String.equal name last)) names in
    let* () = List.fold_left (fun result name -> let* () = result in
      remove_entry ~label (Filename.concat path name)) (Ok ()) first in
    let* () = if List.mem last names then remove_entry ~label (Filename.concat path last) else Ok () in
    Unix.rmdir path; Ok ()
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

type lock_file = {
  fd : Unix.file_descr;
  file : int * int;
  gate : Mutex.t;
  mutable closed : bool;
}

type open_result =
  | Lock_file of lock_file
  | No_lock_file

external open_directory : string -> Unix.file_descr = "masc_private_profile_open_directory"
external open_child : Unix.file_descr -> string -> Unix.file_descr = "masc_private_profile_open_child"

let owned_by_user (info : Unix.stats) = info.st_uid = Unix.geteuid ()

let checked_lock_file ~path fd =
  let info = Unix.fstat fd in
  match info.st_kind with
  | Unix.S_REG when not (owned_by_user info) ->
    Error (Printf.sprintf "profile lock %s must be owned by uid %d; it is owned by uid %d"
      path (Unix.geteuid ()) info.st_uid)
  | Unix.S_REG when info.st_nlink <> 1 ->
    Error (Printf.sprintf "profile lock %s must have exactly one link; it has %d" path info.st_nlink)
  | Unix.S_REG ->
    Ok (Lock_file {fd; file=(info.st_dev, info.st_ino); gate=Mutex.create (); closed=false})
  | Unix.S_DIR | Unix.S_CHR | Unix.S_BLK | Unix.S_LNK | Unix.S_FIFO | Unix.S_SOCK as kind ->
    Error (Printf.sprintf "profile lock %s must be a regular file; it is a %s"
      path (Resource_requirement.kind_name kind))

let open_lock ~profile ~name =
  let path = Filename.concat profile name in
  match open_directory profile with
  | exception Unix.Unix_error (error, _, _) ->
    Error (Printf.sprintf "profile %s cannot be opened: %s" profile (Unix.error_message error))
  | directory ->
    Fun.protect ~finally:(fun () -> Unix.close directory) (fun () ->
      let info = Unix.fstat directory in
      if not (owned_by_user info) then
        Error (Printf.sprintf "profile %s must be owned by uid %d; it is owned by uid %d"
          profile (Unix.geteuid ()) info.st_uid)
      else match open_child directory name with
      | exception Unix.Unix_error (Unix.ENOENT, _, _) -> Ok No_lock_file
      | exception Unix.Unix_error (Unix.ELOOP, _, _) ->
        Error (Printf.sprintf "profile lock %s must be a regular file; it is a symbolic link" path)
      | exception Unix.Unix_error (error, _, _) ->
        Error (Printf.sprintf "profile lock %s cannot be opened: %s" path (Unix.error_message error))
      | fd ->
        (match checked_lock_file ~path fd with
         | Ok _ as opened -> opened
         | Error _ as refused -> Unix.close fd; refused
         | exception exn -> Unix.close fd; raise exn))

let with_open lock_file ~closed work =
  Mutex.protect lock_file.gate (fun () -> if lock_file.closed then closed else work lock_file.fd)

let close_lock lock_file =
  Mutex.protect lock_file.gate (fun () ->
    if not lock_file.closed then (lock_file.closed <- true; Unix.close lock_file.fd))

type raw
type holder = {
  raw : raw;
  of_file : int * int;
  gate : Mutex.t;
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

let inspect lock_file =
  with_open lock_file ~closed:(Unreadable "the profile lock file is closed") (fun fd ->
    match capture_raw fd with
    | 0, raw -> Held_by {raw; of_file=lock_file.file; gate=Mutex.create (); released=false}
    | 1, _ -> Unlocked
    | 2, _ -> Changing
    | 3, _ -> Unreadable "this platform cannot capture a process identity"
    | _, _ -> Unreadable "the kernel did not report the profile lock holder")

type lock_result =
  | Locked
  | Held_elsewhere

let lock lock_file =
  with_open lock_file ~closed:(Error "the profile lock file is closed") (fun fd ->
    match Unix.lockf fd Unix.F_TLOCK 0 with
    | () -> Ok Locked
    | exception Unix.Unix_error ((Unix.EACCES | Unix.EAGAIN), _, _) -> Ok Held_elsewhere
    | exception Unix.Unix_error (error, _, _) ->
      Error (Printf.sprintf "profile lock cannot be taken: %s" (Unix.error_message error)))

let pid holder = pid_raw holder.raw
let executable holder = executable_raw holder.raw
let same_process left right = same_raw left.raw right.raw

type signal_error =
  | Holder_changed
  | Other_lock_file
  | Lock_file_closed
  | Released
  | Unsupported
  | Failed

let signal holder lock_file ~kill =
  if holder.of_file <> lock_file.file then Error Other_lock_file
  else Mutex.protect holder.gate (fun () ->
    if holder.released then Error Released
    else with_open lock_file ~closed:(Error Lock_file_closed) (fun fd ->
      match signal_raw holder.raw fd kill with
      | 0 -> Ok ()
      | 2 -> Error Holder_changed
      | 3 -> Error Unsupported
      | _ -> Error Failed))

let request_termination holder lock_file = signal holder lock_file ~kill:false
let request_kill holder lock_file = signal holder lock_file ~kill:true

let release holder =
  Mutex.protect holder.gate (fun () ->
    if not holder.released then (holder.released <- true; release_raw holder.raw))
