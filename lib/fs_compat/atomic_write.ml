(* See [atomic_write.mli] for the contract. *)

(* Durable atomic write: tmp → fsync(tmp) → rename → fsync(parent dir).
   Without the fsync pair, a crash between the rename and the kernel's
   dirty-page flush can leave the target truncated or zero-length —
   observed on backlog.json after an abrupt shutdown (2026-04-18). *)
type fsync_target =
  | Regular_file
  | Directory

let same_file_identity left right =
  left.Unix.st_dev = right.Unix.st_dev
  && left.Unix.st_ino = right.Unix.st_ino
;;

let expected_kind = function
  | Regular_file -> Unix.S_REG
  | Directory -> Unix.S_DIR
;;

let fsync_operation = function
  | Regular_file -> "fsync_regular_file"
  | Directory -> "fsync_directory"
;;

let fsync_path ?expected ~target path =
  let operation = fsync_operation target in
  let fd = Unix.openfile path [ Unix.O_RDONLY; Unix.O_CLOEXEC ] 0 in
  let sync_result =
    try
      let actual = Unix.fstat fd in
      if actual.Unix.st_kind <> expected_kind target
      then
        raise
          (Unix.Unix_error
             ((match target with
               | Regular_file -> Unix.EINVAL
               | Directory -> Unix.ENOTDIR),
              operation,
              path));
      (match expected with
       | Some expected when not (same_file_identity expected actual) ->
         raise (Unix.Unix_error (Unix.EAGAIN, operation, path))
       | Some _ | None -> ());
      Unix.fsync fd;
      Ok ()
    with
    | exn -> Error exn
  in
  let close_result =
    try
      Unix.close fd;
      Ok ()
    with
    | exn -> Error exn
  in
  match sync_result, close_result with
  | Ok (), Ok () -> ()
  | Error exn, Ok () | Ok (), Error exn -> raise exn
  | Error primary, Error close_error ->
    Stdlib.Printf.eprintf
      "[fs_compat] %s close also failed path=%s: %s\n%!"
      operation
      path
      (Printexc.to_string close_error);
    raise primary
;;

let fsync_directory path =
  try
    fsync_path ~target:Directory path;
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

let save_file_atomic (path : string) (content : string) : (unit, string) Result.t =
  let dir = Stdlib.Filename.dirname path in
  match
    try
      Ok
        (Stdlib.Filename.open_temp_file
           ~mode:[ Open_binary ]
           ~temp_dir:dir
           atomic_tmp_prefix
           atomic_tmp_suffix)
    with
    | Eio.Cancel.Cancelled _ as exn -> raise exn
    | exn -> Error exn
  with
  | Error exn ->
    Error
      (Printf.sprintf
         "save_file_atomic %s: temp creation failed: %s"
         path
         (Printexc.to_string exn))
  | Ok (tmp, output) ->
    (match
       try Ok (Unix.fstat (Unix.descr_of_out_channel output)) with
       | exn -> Error exn
     with
     | Error inspect_error ->
       (try Stdlib.close_out output with
        | close_error ->
          Stdlib.Printf.eprintf
            "[fs_compat] atomic-write close also failed path=%s: %s\n%!"
            tmp
            (Printexc.to_string close_error));
       Error
         (Printf.sprintf
            "save_file_atomic %s: cannot inspect atomically-opened temp %s: %s; temp retained"
            path
            tmp
            (Printexc.to_string inspect_error))
     | Ok temp_identity ->
       let cleanup_tmp () =
         try
           let actual = Unix.lstat tmp in
           if
             actual.Unix.st_kind = Unix.S_REG
             && same_file_identity temp_identity actual
           then (
             Unix.unlink tmp;
             Ok ())
           else
             Error
               (Printf.sprintf
                  "refusing to unlink replaced atomic-write temp path: %s"
                  tmp)
         with
         | Unix.Unix_error (Unix.ENOENT, _, _) -> Ok ()
         | exn -> Error (Printexc.to_string exn)
       in
       let write_result =
         match
           try
             Stdlib.output_string output content;
             Ok ()
           with
           | exn -> Error exn
         with
         | Ok () ->
           (try
              Stdlib.close_out output;
              Ok ()
            with
            | exn -> Error exn)
         | Error primary ->
           (try Stdlib.close_out output with
            | close_error ->
              Stdlib.Printf.eprintf
                "[fs_compat] atomic-write close also failed path=%s: %s\n%!"
                tmp
                (Printexc.to_string close_error));
           Error primary
       in
       (try
          (match write_result with
           | Ok () -> ()
           | Error exn -> raise exn);
          fsync_path ~expected:temp_identity ~target:Regular_file tmp;
          let temp_after_sync = Unix.lstat tmp in
          if
            temp_after_sync.Unix.st_kind <> Unix.S_REG
            || not (same_file_identity temp_identity temp_after_sync)
          then
            raise
              (Unix.Unix_error
                 (Unix.EAGAIN, "save_file_atomic", tmp));
          Stdlib.Sys.rename tmp path;
          fsync_path ~target:Directory dir;
          Ok ()
        with
        | Eio.Cancel.Cancelled _ as exn ->
          (match cleanup_tmp () with
           | Ok () -> ()
           | Error detail ->
             Stdlib.Printf.eprintf
               "[fs_compat] cancelled atomic-write cleanup failed path=%s: %s\n%!"
               tmp
               detail);
          raise exn
        | exn ->
          let primary = Printexc.to_string exn in
          let detail =
            match cleanup_tmp () with
            | Ok () -> primary
            | Error cleanup ->
              Printf.sprintf "%s; temp cleanup failed: %s" primary cleanup
          in
          Error (Printf.sprintf "save_file_atomic %s: %s" path detail)))
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

let is_single_path_segment value =
  (not (String.equal value ""))
  && not (String.equal value ".")
  && not (String.equal value "..")
  && String.equal (Stdlib.Filename.basename value) value
;;

let recover_atomic_orphan ~path ~recovered_root ~bucket =
  let name = Stdlib.Filename.basename path in
  if not (is_atomic_orphan_name name)
  then Error (Printf.sprintf "not an atomic-write orphan: %s" path)
  else if not (is_single_path_segment bucket)
  then Error (Printf.sprintf "invalid atomic-write recovery bucket: %S" bucket)
  else
    try
      let stat = Unix.lstat path in
      if stat.Unix.st_kind <> Unix.S_REG
      then Error (Printf.sprintf "atomic-write orphan is not a regular file: %s" path)
      else if stat.Unix.st_size = 0
      then (
        fsync_path ~expected:stat ~target:Regular_file path;
        let source_before_unlink = Unix.lstat path in
        if
          source_before_unlink.Unix.st_kind <> Unix.S_REG
          || not (same_file_identity stat source_before_unlink)
        then
          raise
            (Unix.Unix_error
               (Unix.EAGAIN, "recover_atomic_orphan", path));
        Stdlib.Sys.remove path;
        fsync_path ~target:Directory (Stdlib.Filename.dirname path);
        Ok Deleted_zero_length)
      else (
        fsync_path ~expected:stat ~target:Regular_file path;
        let source_after_sync = Unix.lstat path in
        if
          source_after_sync.Unix.st_kind <> Unix.S_REG
          || not (same_file_identity stat source_after_sync)
        then
          raise
            (Unix.Unix_error
               (Unix.EAGAIN, "recover_atomic_orphan", path));
        let recovered_root_stat = Unix.lstat recovered_root in
        if recovered_root_stat.Unix.st_kind <> Unix.S_DIR
        then
          Error
            (Printf.sprintf
               "atomic-write recovery root is not a real directory: %s"
               recovered_root)
        else
        let recovered_dir = Stdlib.Filename.concat recovered_root bucket in
        let recovered_stat = Unix.lstat recovered_dir in
        if recovered_stat.Unix.st_kind <> Unix.S_DIR
        then
          Error
            (Printf.sprintf
               "atomic-write recovery path is not a real directory: %s"
               recovered_dir)
        else
        let destination = Stdlib.Filename.concat recovered_dir name in
        if String.equal destination path
        then
          Error
            (Printf.sprintf
               "atomic-write recovery destination equals source: %s"
               destination)
        else
          let source_dir = Stdlib.Filename.dirname path in
          let finish_existing_link destination_stat =
            if
              destination_stat.Unix.st_kind = Unix.S_REG
              && same_file_identity stat destination_stat
            then (
              let source_before_unlink = Unix.lstat path in
              if
                source_before_unlink.Unix.st_kind <> Unix.S_REG
                || not (same_file_identity stat source_before_unlink)
              then
                Error
                  (Printf.sprintf
                     "atomic-write recovery source changed before unlink: %s"
                     path)
              else (
                fsync_path ~target:Directory recovered_dir;
                Unix.unlink path;
                fsync_path ~target:Directory source_dir;
                Ok (Preserved_nonempty destination)))
            else
              Error
                (Printf.sprintf
                   "atomic-write recovery destination already exists: %s"
                   destination)
          in
          (match Unix.lstat destination with
           | destination_stat -> finish_existing_link destination_stat
           | exception Unix.Unix_error (Unix.ENOENT, _, _) ->
             (match Unix.link ~follow:false path destination with
              | () ->
                let destination_stat = Unix.lstat destination in
                finish_existing_link destination_stat
              | exception Unix.Unix_error (Unix.EEXIST, _, _) ->
                Error
                  (Printf.sprintf
                     "atomic-write recovery destination concurrently appeared: %s"
                     destination))))
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
  if not (is_single_path_segment recovered_subdir)
  then
    invalid_arg
      (Printf.sprintf
         "cleanup_atomic_orphans: recovered_subdir must be one path segment: %S"
         recovered_subdir);
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
      let stat = Unix.lstat path in
      if stat.Unix.st_kind = Unix.S_DIR
      then (
        fsync_path ~target:Directory (Stdlib.Filename.dirname path);
        Ok ())
      else
        Error
          (Printf.sprintf
             "recovered path is not a real directory: %s"
             path)
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
    match ensure_recovered_dir recovered_dir with
    | Error detail -> report_error detail
    | Ok () ->
      (match ensure_recovered_dir file_recovered_dir with
       | Error detail -> report_error detail
       | Ok () ->
         (match
            recover_atomic_orphan
              ~path
              ~recovered_root:recovered_dir
              ~bucket
          with
          | Ok Deleted_zero_length -> incr deleted
          | Ok (Preserved_nonempty _) -> incr preserved
          | Error detail -> report_error detail))
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
