(* See [atomic_write.mli] for the contract. *)

(* Durable atomic write: tmp → fsync(tmp) → rename → fsync(parent dir).
   Without the fsync pair, a crash between the rename and the kernel's
   dirty-page flush can leave the target truncated or zero-length —
   observed on backlog.json after an abrupt shutdown (2026-04-18). *)
let fsync_path path =
  let fd = Unix.openfile path [ Unix.O_RDONLY ] 0 in
  Stdlib.Fun.protect
    ~finally:(fun () ->
      try Unix.close fd with
      | Eio.Cancel.Cancelled _ as e -> raise e
      | exn ->
        Stdlib.Printf.eprintf
          "[fs_compat] fsync_path close failed: %s\n%!"
          (Printexc.to_string exn))
    (fun () ->
      try Unix.fsync fd with
      | Unix.Unix_error ((Unix.EINVAL | Unix.EOPNOTSUPP), _, _) ->
        (* Some filesystems (tmpfs on some kernels) reject fsync. The data
           is still durable to the extent the underlying FS offers. *)
        ())
;;

let fsync_directory path =
  try
    fsync_path path;
    Ok ()
  with
  | Eio.Cancel.Cancelled _ as exn -> raise exn
  | exn -> Error (Printf.sprintf "fsync directory %s: %s" path (Printexc.to_string exn))
;;

(* #10205 finding 2: keep the atomic-tmp filename shape in one place
   so the writer ([save_file_atomic]) and the orphan-sweep matcher
   ([is_atomic_orphan_name]) cannot drift independently. A
   prefix/suffix change on one side without the other would cause
   the sweep to either miss live orphans or scoop unrelated tmp
   files. *)
let atomic_tmp_prefix = ".atomic_"
let atomic_tmp_suffix = ".tmp"

let save_file_atomic
  ~(save_file : string -> string -> unit)
  (path : string)
  (content : string)
  : (unit, string) Result.t
  =
  let dir = Stdlib.Filename.dirname path in
  let tmp =
    Stdlib.Filename.temp_file ~temp_dir:dir atomic_tmp_prefix atomic_tmp_suffix
  in
  try
    save_file tmp content;
    fsync_path tmp;
    Stdlib.Sys.rename tmp path;
    fsync_path dir;
    Ok ()
  with
  | Eio.Cancel.Cancelled _ as e ->
    (try Stdlib.Sys.remove tmp with
     | Sys_error _ -> ());
    raise e
  | exn ->
    (try Stdlib.Sys.remove tmp with
     | Sys_error _ -> ());
    Error (Printf.sprintf "save_file_atomic %s: %s" path (Printexc.to_string exn))
;;

let is_atomic_orphan_name name =
  let n = String.length name in
  let p = String.length atomic_tmp_prefix in
  let s = String.length atomic_tmp_suffix in
  n >= p + s
  && String.starts_with name ~prefix:atomic_tmp_prefix
  && String.ends_with ~suffix:atomic_tmp_suffix name
;;

type atomic_orphan_recovery =
  | Deleted_zero_length
  | Preserved_nonempty of string

let recover_atomic_orphan ~mkdir_p_unix ~path ~recovered_dir =
  let name = Stdlib.Filename.basename path in
  if not (is_atomic_orphan_name name)
  then Error (Printf.sprintf "not an atomic-write orphan: %s" path)
  else
    try
      let stat = Unix.lstat path in
      if stat.Unix.st_kind <> Unix.S_REG
      then Error (Printf.sprintf "atomic-write orphan is not a regular file: %s" path)
      else if stat.Unix.st_size = 0
      then (
        Stdlib.Sys.remove path;
        fsync_path (Stdlib.Filename.dirname path);
        Ok Deleted_zero_length)
      else (
        mkdir_p_unix recovered_dir;
        let destination = Stdlib.Filename.concat recovered_dir name in
        if Stdlib.Sys.file_exists destination
        then
          Error
            (Printf.sprintf
               "atomic-write recovery destination already exists: %s"
               destination)
        else (
          Stdlib.Sys.rename path destination;
          fsync_path (Stdlib.Filename.dirname path);
          if not (String.equal recovered_dir (Stdlib.Filename.dirname path))
          then fsync_path recovered_dir;
          Ok (Preserved_nonempty destination)))
    with
    | Eio.Cancel.Cancelled _ as exn -> raise exn
    | exn -> Error (Printf.sprintf "%s: %s" path (Printexc.to_string exn))
;;

let cleanup_atomic_orphans
  ~(mkdir_p_unix : string -> unit)
  ~(base_path : string)
  ?(recovered_subdir = ".recovered")
  ()
  : int * int
  =
  let recovered_dir = Stdlib.Filename.concat base_path recovered_subdir in
  let deleted = ref 0 in
  let preserved = ref 0 in
  (* #10205 finding 3: previous body reinvented [mkdir_p] inline with
     [Stdlib.Sys.file_exists]+[Unix.mkdir]+[Unix.Unix_error _] swallowing.
     [mkdir_p_unix] is recursive, idempotent (handles [EEXIST] precisely
     instead of swallowing every [Unix_error]), and correct when
     [base_path] itself does not exist yet (boot-time race). *)
  let report_error detail =
    Stdlib.Printf.eprintf "[fs_compat] atomic orphan sweep: %s\n%!" detail
  in
  let ensure_recovered_dir path =
    try
      mkdir_p_unix path;
      Ok ()
    with
    | Eio.Cancel.Cancelled _ as exn -> raise exn
    | exn ->
      Error
        (Printf.sprintf
           "cannot create recovered directory %s: %s"
           path
           (Printexc.to_string exn))
  in
  let handle_file dir name =
    let path = Stdlib.Filename.concat dir name in
    let bucket =
      if String.equal dir base_path then "root" else Stdlib.Filename.basename dir
    in
    let file_recovered_dir = Stdlib.Filename.concat recovered_dir bucket in
    match ensure_recovered_dir file_recovered_dir with
    | Error detail -> report_error detail
    | Ok () ->
      (match
         recover_atomic_orphan
           ~mkdir_p_unix
           ~path
           ~recovered_dir:file_recovered_dir
       with
       | Ok Deleted_zero_length -> incr deleted
       | Ok (Preserved_nonempty _) -> incr preserved
       | Error detail -> report_error detail)
  in
  let scan_dir dir entries =
    Array.iter
      (fun name -> if is_atomic_orphan_name name then handle_file dir name)
      entries
  in
  let read_dir_entries dir =
    match Stdlib.Sys.readdir dir with
    | exception Sys_error detail ->
      report_error (Printf.sprintf "cannot list %s: %s" dir detail);
      [||]
    | entries -> entries
  in
  (* #10205 finding 4: previous body called [Stdlib.Sys.readdir base_path]
     twice — once via [scan_dir] for orphan-find, once for the
     subdirectory recursion pass. Read once, run both passes against
     the cached entry array. *)
  let entries = read_dir_entries base_path in
  scan_dir base_path entries;
  Array.iter
    (fun name ->
      if String.equal name recovered_subdir
      then ()
      else (
        let sub = Stdlib.Filename.concat base_path name in
        match Unix.lstat sub with
        | exception Unix.Unix_error (error, operation, argument) ->
          report_error
            (Printf.sprintf
               "cannot inspect %s: %s (%s %s)"
               sub
               (Unix.error_message error)
               operation
               argument)
        | stat when stat.Unix.st_kind = Unix.S_DIR ->
          scan_dir sub (read_dir_entries sub)
        | _ -> ()))
    entries;
  !deleted, !preserved
;;
