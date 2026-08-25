(** Result-based filesystem operations.

    Normalizes [Eio.Io], [Unix.Unix_error], [Sys_error], and [Failure]
    into [Error.Io (FileOpFailed ...)].
    Pattern extracted from checkpoint_store.ml / a2a_task_store.ml. *)

open Result_syntax

let io_error_of_exn ~op ~path = function
  | Eio.Io _ as exn ->
    Error (Error.Io (FileOpFailed { op; path; detail = Printexc.to_string exn }))
  | Unix.Unix_error _ as exn ->
    Error (Error.Io (FileOpFailed { op; path; detail = Printexc.to_string exn }))
  | Sys_error detail -> Error (Error.Io (FileOpFailed { op; path; detail }))
  | Failure msg -> Error (Error.Io (FileOpFailed { op; path; detail = msg }))
  | Yojson.Json_error msg ->
    Error (Error.Io (FileOpFailed { op; path; detail = "JSON error: " ^ msg }))
  | Eio.Cancel.Cancelled _ as e -> raise e
  | exn -> raise exn
;;

let read_file path =
  try Ok (In_channel.with_open_bin path In_channel.input_all) with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | exn -> io_error_of_exn ~op:"read" ~path exn
;;

let ensure_dir_recursive ?(mode = 0o700) path =
  let op = "mkdir_p" in
  let file_error path detail = Error (Error.Io (FileOpFailed { op; path; detail })) in
  (* Use Unix.* here rather than Sys.* so mkdir failures retain structured errno
     values. The EEXIST -> stat check below is necessarily racy if another
     process replaces the path between the two syscalls; the result is still a
     best-effort diagnostic for local directory preparation. *)
  let ensure_existing_dir p =
    try
      match (Unix.stat p).st_kind with
      | Unix.S_DIR -> Ok ()
      | _ -> file_error p "path exists and is not a directory"
    with
    | Eio.Cancel.Cancelled _ as e -> raise e
    | exn -> io_error_of_exn ~op ~path:p exn
  in
  let mkdir_once p =
    try
      Unix.mkdir p mode;
      Ok `Created
    with
    | Eio.Cancel.Cancelled _ as e -> raise e
    | Unix.Unix_error (Unix.EEXIST, _, _) -> Ok `Already_exists
    | Unix.Unix_error (Unix.ENOENT, _, _) -> Ok `Missing_parent
    | exn -> io_error_of_exn ~op ~path:p exn
  in
  let rec aux p =
    if String.equal p ""
    then file_error p "empty directory path"
    else (
      match mkdir_once p with
      | Error _ as err -> err
      | Ok `Created -> Ok ()
      | Ok `Already_exists -> ensure_existing_dir p
      | Ok `Missing_parent ->
        let parent = Filename.dirname p in
        if String.equal parent p
        then io_error_of_exn ~op ~path:p (Unix.Unix_error (Unix.ENOENT, op, p))
        else
          let* () = aux parent in
          (match mkdir_once p with
           | Error _ as err -> err
           | Ok `Created -> Ok ()
           | Ok `Already_exists -> ensure_existing_dir p
           | Ok `Missing_parent ->
             io_error_of_exn ~op ~path:p (Unix.Unix_error (Unix.ENOENT, op, p))))
  in
  aux path
;;

let ensure_dir path = ensure_dir_recursive path

(* Best-effort fsync. Some filesystems (tmpfs on some kernels, SMB)
   reject fsync with EINVAL/EOPNOTSUPP; treat those as non-fatal. *)
let fsync_fd_best_effort fd =
  try Unix.fsync fd with
  | Unix.Unix_error ((EINVAL | EOPNOTSUPP), _, _) -> ()
;;

let fsync_dir_best_effort dir =
  try
    let fd = Unix.openfile dir [ Unix.O_RDONLY ] 0 in
    Fun.protect
      ~finally:(fun () ->
        try Unix.close fd with
        | Unix.Unix_error _ -> ())
      (fun () -> fsync_fd_best_effort fd)
  with
  | Unix.Unix_error _ -> ()
;;

let write_file path content =
  try
    let* () = ensure_dir_recursive (Filename.dirname path) in
    let dir = Filename.dirname path in
    let base = Filename.basename path in
    (* Unique tmp per writer: [Filename.temp_file] uses PID + counter,
       so concurrent [write_file] calls on the same target never share
       a tmp path. This closes the [rename] race where writer A's
       rename consumes the tmp before writer B's rename runs
       (agent_core checkpoint_store.ml / a2a_task_store.ml / memory_file_backend.ml). *)
    let tmp_path = Filename.temp_file ~temp_dir:dir (base ^ ".") ".tmp" in
    let clean_tmp () =
      try Sys.remove tmp_path with
      | Sys_error _ | Unix.Unix_error _ -> ()
    in
    try
      Out_channel.with_open_bin tmp_path (fun oc ->
        Out_channel.output_string oc content;
        Out_channel.flush oc;
        (* Durability: data must reach disk before rename, else a
            crash between [rename] and the kernel's write-back can
            leave the target with stale or truncated bytes. *)
        fsync_fd_best_effort (Unix.descr_of_out_channel oc));
      Sys.rename tmp_path path;
      fsync_dir_best_effort dir;
      Ok ()
    with
    | exn ->
      clean_tmp ();
      raise exn
  with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | exn -> io_error_of_exn ~op:"write" ~path exn
;;

let write_file_secret path content =
  try
    let* () = ensure_dir_recursive (Filename.dirname path) in
    let tmp_path =
      Filename.temp_file
        ~temp_dir:(Filename.dirname path)
        (Filename.basename path ^ ".")
        ".tmp"
    in
    let clean_tmp () =
      try Sys.remove tmp_path with
      | Sys_error _ | Unix.Unix_error _ -> ()
    in
    try
      let fd =
        Unix.openfile tmp_path [ Unix.O_WRONLY; Unix.O_CREAT; Unix.O_EXCL ] 0o600
      in
      let oc = Unix.out_channel_of_descr fd in
      Fun.protect
        ~finally:(fun () -> close_out_noerr oc)
        (fun () ->
           output_string oc content;
           Out_channel.flush oc;
           fsync_fd_best_effort fd);
      Sys.rename tmp_path path;
      fsync_dir_best_effort (Filename.dirname path);
      Ok ()
    with
    | exn ->
      clean_tmp ();
      raise exn
  with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | exn -> io_error_of_exn ~op:"write_secret" ~path exn
;;

let append_file path content =
  try
    let* () = ensure_dir_recursive (Filename.dirname path) in
    let oc = open_out_gen [ Open_append; Open_creat; Open_binary ] 0o600 path in
    Fun.protect
      ~finally:(fun () -> close_out_noerr oc)
      (fun () -> output_string oc content);
    Ok ()
  with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | exn -> io_error_of_exn ~op:"append" ~path exn
;;

let read_dir path =
  try Ok (Sys.readdir path |> Array.to_list |> List.sort String.compare) with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | exn -> io_error_of_exn ~op:"read_dir" ~path exn
;;

let file_exists path =
  try Sys.file_exists path && not (Sys.is_directory path) with
  | Sys_error _ -> false
;;

let remove_file path =
  try
    if Sys.file_exists path then Sys.remove path;
    Ok ()
  with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | exn -> io_error_of_exn ~op:"remove" ~path exn
;;
