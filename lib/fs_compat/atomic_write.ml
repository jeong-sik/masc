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

type not_committed_stage =
  | Open_parent_directory
  | Create_temporary
  | Configure_temporary
  | Write_temporary
  | Sync_temporary
  | Close_temporary

type uncertain_commit_stage =
  | Rename_target
  | Sync_parent_directory
  | Close_parent_directory

type temporary_cleanup =
  | No_temporary
  | Temporary_removed of { temporary_path : string }
  | Temporary_absent of { temporary_path : string }
  | Temporary_cleanup_failed of
      { temporary_path : string
      ; message : string
      }

type strict_write_error =
  | Not_committed of
      { path : string
      ; stage : not_committed_stage
      ; message : string
      ; cleanup : temporary_cleanup
      }
  | Commit_durability_unknown of
      { path : string
      ; stage : uncertain_commit_stage
      ; message : string
      ; cleanup : temporary_cleanup
      }

(* Keep the producer and orphan-sweep matcher on one filename SSOT. *)
let atomic_tmp_prefix = ".atomic_"
let atomic_tmp_suffix = ".tmp"

let not_committed_stage_label = function
  | Open_parent_directory -> "open_parent_directory"
  | Create_temporary -> "create_temporary"
  | Configure_temporary -> "configure_temporary"
  | Write_temporary -> "write_temporary"
  | Sync_temporary -> "sync_temporary"
  | Close_temporary -> "close_temporary"
;;

let uncertain_commit_stage_label = function
  | Rename_target -> "rename_target"
  | Sync_parent_directory -> "sync_parent_directory"
  | Close_parent_directory -> "close_parent_directory"
;;

let temporary_cleanup_label = function
  | No_temporary -> "none"
  | Temporary_removed { temporary_path } -> "removed:" ^ temporary_path
  | Temporary_absent { temporary_path } -> "absent:" ^ temporary_path
  | Temporary_cleanup_failed { temporary_path; message } ->
    Printf.sprintf "failed:%s:%s" temporary_path message
;;

let strict_write_error_to_string = function
  | Not_committed { path; stage; message; cleanup } ->
    Printf.sprintf
      "atomic write not committed: path=%s stage=%s cleanup=%s error=%s"
      path
      (not_committed_stage_label stage)
      (temporary_cleanup_label cleanup)
      message
  | Commit_durability_unknown { path; stage; message; cleanup } ->
    Printf.sprintf
      "atomic write commit durability unknown: path=%s stage=%s cleanup=%s error=%s"
      path
      (uncertain_commit_stage_label stage)
      (temporary_cleanup_label cleanup)
      message
;;

let exception_message = function
  | Unix.Unix_error (error, operation, argument) ->
    Printf.sprintf
      "%s (%s %s)"
      (Unix.error_message error)
      operation
      argument
  | exn -> Printexc.to_string exn
;;

let cleanup_temporary temporary_path =
  try
    Unix.unlink temporary_path;
    Temporary_removed { temporary_path }
  with
  | Unix.Unix_error (Unix.ENOENT, _, _) ->
    Temporary_absent { temporary_path }
  | exn ->
    Temporary_cleanup_failed
      { temporary_path; message = exception_message exn }
;;

let append_parent_close_error error close_error =
  let suffix = "; parent directory close failed: " ^ close_error in
  match error with
  | Not_committed details ->
    Not_committed { details with message = details.message ^ suffix }
  | Commit_durability_unknown details ->
    Commit_durability_unknown
      { details with message = details.message ^ suffix }
;;

let save_file_atomic_strict (path : string) (content : string) =
  let dir = Filename.dirname path in
  match
    try
      let fd = Unix.openfile dir [ Unix.O_RDONLY; Unix.O_CLOEXEC ] 0 in
      Ok fd
    with
    | Eio.Cancel.Cancelled _ as exn -> raise exn
    | exn ->
      Error
        (Not_committed
           { path
           ; stage = Open_parent_directory
           ; message = exception_message exn
           ; cleanup = No_temporary
           })
  with
  | Error error -> Error error
  | Ok parent_fd ->
    let cancelled = ref None in
    let outcome =
      try
        Some
          (match
             try
               let temporary_path, channel =
                 Filename.open_temp_file
                   ~temp_dir:dir
                   atomic_tmp_prefix
                   atomic_tmp_suffix
               in
               Ok (temporary_path, channel)
             with
             | Eio.Cancel.Cancelled _ as exn -> raise exn
             | exn ->
               Error
                 (Not_committed
                    { path
                    ; stage = Create_temporary
                    ; message = exception_message exn
                    ; cleanup = No_temporary
                    })
           with
      | Error error -> Error error
      | Ok (temporary_path, channel) ->
        let fd = Unix.descr_of_out_channel channel in
        let fail_precommit stage exn =
          close_out_noerr channel;
          let cleanup = cleanup_temporary temporary_path in
          match exn with
          | Eio.Cancel.Cancelled _ ->
            (match cleanup with
             | Temporary_cleanup_failed { message; _ } ->
               Printf.eprintf
                 "[fs_compat] cancelled strict atomic-write cleanup failed: %s\n%!"
                 message
             | No_temporary | Temporary_removed _ | Temporary_absent _ -> ());
            raise exn
          | _ ->
            Error
              (Not_committed
                 { path
                 ; stage
                 ; message = exception_message exn
                 ; cleanup
                 })
        in
        (match
           try
             Unix.set_close_on_exec fd;
             Ok ()
           with exn -> fail_precommit Configure_temporary exn
         with
        | Error _ as error -> error
        | Ok () -> (
          match
            try
              output_string channel content;
              flush channel;
              Ok ()
            with exn -> fail_precommit Write_temporary exn
          with
          | Error _ as error -> error
          | Ok () -> (
            match
              try
                Unix.fsync fd;
                Ok ()
              with exn -> fail_precommit Sync_temporary exn
            with
            | Error _ as error -> error
            | Ok () -> (
              match
                try
                  close_out channel;
                  Ok ()
                with exn ->
                  close_out_noerr channel;
                  fail_precommit Close_temporary exn
              with
              | Error _ as error -> error
              | Ok () ->
                let rename_outcome =
                  try
                    Unix.rename temporary_path path;
                    Ok ()
                  with
                  | exn ->
                    Error
                      (Commit_durability_unknown
                         { path
                         ; stage = Rename_target
                         ; message = exception_message exn
                         ; cleanup = cleanup_temporary temporary_path
                         })
                in
                (match rename_outcome with
                | Error _ as error -> error
                | Ok () ->
                  (try
                     Unix.fsync parent_fd;
                     Ok ()
                   with exn ->
                     Error
                       (Commit_durability_unknown
                          { path
                          ; stage = Sync_parent_directory
                          ; message = exception_message exn
                          ; cleanup = No_temporary
                          }))))))))
      with Eio.Cancel.Cancelled _ as exn ->
        cancelled := Some exn;
        None
    in
    let parent_close_error =
      try
        Unix.close parent_fd;
        None
      with exn -> Some (exception_message exn)
    in
    (match !cancelled with
     | Some exn ->
       Option.iter
         (fun close_error ->
           Printf.eprintf
             "[fs_compat] cancelled strict atomic-write parent close failed: %s\n%!"
             close_error)
         parent_close_error;
       raise exn
     | None ->
       (match outcome, parent_close_error with
        | Some (Ok ()), None -> Ok ()
        | Some (Ok ()), Some message ->
          Error
            (Commit_durability_unknown
               { path
               ; stage = Close_parent_directory
               ; message
               ; cleanup = No_temporary
               })
        | Some (Error error), None -> Error error
        | Some (Error error), Some close_error ->
          Error (append_parent_close_error error close_error)
        | None, _ -> assert false))
;;

(* #10205 finding 2: keep the atomic-tmp filename shape in one place
   so the writer ([save_file_atomic]) and the orphan-sweep matcher
   ([is_atomic_orphan_name]) cannot drift independently. A
   prefix/suffix change on one side without the other would cause
   the sweep to either miss live orphans or scoop unrelated tmp
   files. *)
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
    (try fsync_path dir with
     | Unix.Unix_error _ -> ());
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
  let ensure_recovered_dir () =
    try mkdir_p_unix recovered_dir with
    | Unix.Unix_error _ -> ()
  in
  let handle_file dir name =
    let path = Stdlib.Filename.concat dir name in
    match Unix.stat path with
    | exception Unix.Unix_error _ -> ()
    | stat when stat.Unix.st_size = 0 ->
      (try
         Stdlib.Sys.remove path;
         incr deleted
       with
       | Sys_error _ -> ())
    | _stat ->
      ensure_recovered_dir ();
      let target =
        Stdlib.Filename.concat
          recovered_dir
          (Printf.sprintf "%s.%.0f" name (Unix.gettimeofday () *. 1000.0))
      in
      (try
         Stdlib.Sys.rename path target;
         incr preserved
       with
       | Sys_error _ | Unix.Unix_error _ -> ())
  in
  let scan_dir dir entries =
    Array.iter
      (fun name -> if is_atomic_orphan_name name then handle_file dir name)
      entries
  in
  let read_dir_entries dir =
    match Stdlib.Sys.readdir dir with
    | exception Sys_error _ -> [||]
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
        match Unix.stat sub with
        | exception Unix.Unix_error _ -> ()
        | stat when stat.Unix.st_kind = Unix.S_DIR ->
          scan_dir sub (read_dir_entries sub)
        | _ -> ()))
    entries;
  !deleted, !preserved
;;
