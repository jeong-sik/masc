type rejection = Lock_file_not_regular of string

let owner_only_file_mode = 0o600

(* The lock descriptor carries no data. Its close must not replace the outcome
   of the action it guarded. *)
let close_quietly fd = try Unix.close fd with Unix.Unix_error _ -> ()

(* The table grows only by the receipt directories this process installs into. *)
let mutexes : (int * int, Mutex.t) Hashtbl.t = Hashtbl.create 1
let mutexes_guard = Mutex.create ()

let mutex_for directory =
  let info = Unix.lstat directory in
  let key = info.Unix.st_dev, info.Unix.st_ino in
  Mutex.protect mutexes_guard (fun () ->
    match Hashtbl.find_opt mutexes key with
    | Some mutex -> mutex
    | None ->
      let mutex = Mutex.create () in
      Hashtbl.replace mutexes key mutex;
      mutex)

let open_lock lock =
  let occupied =
    try Some (Unix.lstat lock) with Unix.Unix_error (Unix.ENOENT, _, _) -> None in
  match occupied with
  | Some info when info.Unix.st_kind <> Unix.S_REG -> Error (Lock_file_not_regular lock)
  | None | Some _ ->
    let fd = Unix.openfile lock [ Unix.O_RDWR; Unix.O_CREAT; Unix.O_CLOEXEC ] owner_only_file_mode in
    match Unix.fstat fd, Unix.lstat lock with
    | descriptor, named ->
      if named.Unix.st_kind = Unix.S_REG && named.Unix.st_dev = descriptor.Unix.st_dev
         && named.Unix.st_ino = descriptor.Unix.st_ino
      then Ok fd
      else (close_quietly fd; Error (Lock_file_not_regular lock))
    | exception (Unix.Unix_error _ as exn) -> close_quietly fd; raise exn

let lock_is_free fd =
  match Unix.lockf fd Unix.F_TLOCK 0 with
  | () -> true
  | exception Unix.Unix_error ((Unix.EAGAIN | Unix.EACCES), _, _) -> false

let with_waiting ~on_wait ~directory ~lock action =
  let mutex = mutex_for directory in
  let waited = not (Mutex.try_lock mutex) in
  if waited then (on_wait lock; Mutex.lock mutex);
  Fun.protect ~finally:(fun () -> Mutex.unlock mutex) (fun () ->
    match open_lock lock with
    | Error rejection -> Error rejection
    | Ok fd ->
      Fun.protect ~finally:(fun () -> close_quietly fd) (fun () ->
        if not (lock_is_free fd) then begin
          if not waited then on_wait lock;
          Unix.lockf fd Unix.F_LOCK 0
        end;
        Ok (action ())))

let with_if_free ~directory ~lock action =
  let mutex = mutex_for directory in
  match Mutex.try_lock mutex with
  | false -> Ok None
  | true ->
    Fun.protect ~finally:(fun () -> Mutex.unlock mutex) (fun () ->
      match open_lock lock with
      | Error rejection -> Error rejection
      | Ok fd ->
        Fun.protect ~finally:(fun () -> close_quietly fd) (fun () ->
          match lock_is_free fd with
          | false -> Ok None
          | true -> Ok (Some (action ()))))
