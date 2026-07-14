(** Filesystem Compatibility Layer - Eio-native I/O with fallback

    Provides a unified filesystem API for gradual migration from
    blocking Unix I/O to Eio.Path operations.

    Usage:
    1. At server startup: [Fs_compat.set_fs (Eio.Stdenv.fs env)]
    2. In code: [Fs_compat.load_file path] instead of [open_in ...]

    When fs is not set (non-Eio contexts), falls back to blocking Unix I/O.
    This allows incremental migration without changing all call sites at once.

    @since 2026-02 - Keeper Emergent Identity v2.0
*)

module Atomic_orphan_size_class = Atomic_orphan_size_class

(** Global fs — WORM Atomic (write-once at startup, read from any domain).
    Using Atomic.t is required for OCaml 5 multi-domain safety:
    Executor_pool workers run on a separate domain and read this value. *)
let global_fs : Eio.Fs.dir_ty Eio.Path.t option Atomic.t = Atomic.make None

(** Set the global Eio filesystem. Call once at server startup.
    @param fs The Eio fs from [Eio.Stdenv.fs env] *)
let set_fs fs = Atomic.set global_fs (Some fs)

(** Clear the global fs (testing/shutdown only — not called in production).
    Safe because test runners and shutdown are single-fiber sequential. *)
let clear_fs () = Atomic.set global_fs None

let get_fs_opt () = Atomic.get global_fs

(** Check if Eio fs is available *)
let has_fs () = Option.is_some (Atomic.get global_fs)

(** Normalize [Eio.Io] to [Sys_error] so callers only need one catch.
    Eio operations raise [Eio.Io _] on permission errors, missing files, etc.
    Stdlib I/O already raises [Sys_error], so wrapping only the Eio branch
    keeps the exception contract uniform. *)
let with_io ~path f =
  try f () with
  | Eio.Io _ as e ->
    raise (Sys_error (Printf.sprintf "%s: %s" path (Printexc.to_string e)))
;;

(* #9921: defense-in-depth write-boundary guard.

   [Env_config_core.base_path_prod_guard] stops test-time writes when path
   resolution points under HOME.  Any code that caches a stale [base_path ()]
   result or builds a HOME-relative path directly hits this gate before the
   write lands on the production ledger.

   The prod ledger observed 106 test-pattern rows
   ([hot-voter-*], [flipper], [same-voter], [judge]) written pre-#9920.
   This guard prevents regression if any new code path slips past the
   resolution guard.

   Active only for test executables (basename starts with [test_]).
   Escape hatch [MASC_TEST_ALLOW_HOME_BASE_PATH=1] matches
   [base_path_prod_guard] for the rare test that legitimately writes
   under HOME.  Reads remain unguarded — this is about preventing
   silent corruption, not restricting observability. *)
exception Test_isolation_breach of string

let test_exec_home_guard ~op path =
  let basename =
    Stdlib.Sys.executable_name |> Stdlib.Filename.basename |> String.lowercase_ascii
  in
  let is_test_exec =
    String.length basename >= 5 && String.starts_with basename ~prefix:"test_"
  in
  if not is_test_exec
  then ()
  else (
    let allow =
      match Sys.getenv_opt "MASC_TEST_ALLOW_HOME_BASE_PATH" with
      | Some v ->
        let v = String.lowercase_ascii (String.trim v) in
        String.equal v "1" || String.equal v "true" || String.equal v "yes"
      | None -> false
    in
    if allow
    then ()
    else (
      match Sys.getenv_opt "HOME" with
      | None | Some "" -> ()
      | Some home ->
        let home_norm =
          let trimmed = String.trim home in
          let len = String.length trimmed in
          if len > 1 && Char.equal trimmed.[len - 1] '/'
          then String.sub trimmed 0 (len - 1)
          else trimmed
        in
        let home_len = String.length home_norm in
        if
          home_len > 0
          && String.length path >= home_len
          && String.starts_with path ~prefix:home_norm
        then
          raise
            (Test_isolation_breach
               (Printf.sprintf
                  "#9921 %s blocked under HOME=%S (path=%S) in test executable %S. \
                   MASC_BASE_PATH override did not apply — fix the test setup or set \
                   MASC_TEST_ALLOW_HOME_BASE_PATH=1."
                  op
                  home_norm
                  path
                  (Stdlib.Filename.basename Stdlib.Sys.executable_name)))))
;;

let with_fs_or_fallback ~path ~fallback f =
  match Atomic.get global_fs with
  | Some fs ->
    (try with_io ~path (fun () -> f fs) with
     | Stdlib.Effect.Unhandled _ -> fallback ())
  | None -> fallback ()
;;

let load_file_unix (path : string) : string =
  let ic = Stdlib.open_in path in
  Stdlib.Fun.protect
    ~finally:(fun () -> Stdlib.close_in_noerr ic)
    (fun () ->
       let len = Stdlib.in_channel_length ic in
       Stdlib.really_input_string ic len)
;;

let save_file_unix (path : string) (content : string) : unit =
  let oc = Stdlib.open_out path in
  Stdlib.Fun.protect
    ~finally:(fun () -> Stdlib.close_out_noerr oc)
    (fun () -> Stdlib.output_string oc content)
;;

(* RFC-0108: per-path Stdlib.Mutex registry + fresh-fd open/close
   on every append.

   Background: prior [Append_fd_cache] LRU cached an [out_channel]
   per path and reused it across calls. Cache lookup was mutex-
   protected, but the OCaml-runtime [out_channel] buffer state is
   not domain-safe — two domains writing through the same cached
   channel corrupted records mid-line (observed 2026-05-17:
   utf-8 multibyte tears across trajectories/, keepers/*/reaction-
   ledger/, plus "}{"-concat in oas-events/ — total 243 live
   malformed lines).

   PR #15936 (RFC-0108 root-fix scope #1) addressed [append_jsonl]
   with its own per-path registry but left [append_file_unix] still
   pointing at the cache. This PR extends the fix to
   [append_file_unix] (and removes the now-dead [Append_fd_cache]
   module and [at_exit] hook) so the ~15 [append_file] callers
   (metrics_store_eio, workspace_utils_ops, board_core,
   keeper_chat_store, etc.) get the
   same guarantee.

   The mutex registry is shared between [append_file_unix] and
   [append_jsonl] (single [append_path_mutex_registry]) so a
   caller mixing the two helpers on a single path remains
   race-free. Per-path granularity lets appends to *different*
   files run concurrently.

   Throughput trade-off (RFC-0108 §6 performance follow-up): the
   removed cache folded three syscalls (open/output_string/close)
   into one cached output_string under 64-keeper telemetry. Fresh
   fd per call restores those three syscalls. A future domain-safe
   cache (per-domain fd, or a single-writer workspace fiber) can
   reinstate the optimization without giving up correctness. *)
let append_path_mutex_registry : (string, Stdlib.Mutex.t) Hashtbl.t =
  Hashtbl.create 32
let append_path_mutex_registry_mu = Stdlib.Mutex.create ()

let get_append_path_mutex path =
  Stdlib.Mutex.lock append_path_mutex_registry_mu;
  Fun.protect
    ~finally:(fun () -> Stdlib.Mutex.unlock append_path_mutex_registry_mu)
    (fun () ->
      match Hashtbl.find_opt append_path_mutex_registry path with
      | Some m -> m
      | None ->
        let m = Stdlib.Mutex.create () in
        Hashtbl.add append_path_mutex_registry path m;
        m)

let append_file_unix (path : string) (content : string) : unit =
  let mu = get_append_path_mutex path in
  Stdlib.Mutex.lock mu;
  Fun.protect
    ~finally:(fun () -> Stdlib.Mutex.unlock mu)
    (fun () ->
      let oc =
        Stdlib.open_out_gen
          [ Stdlib.Open_append; Stdlib.Open_creat; Stdlib.Open_wronly ]
          0o644
          path
      in
      Fun.protect
        ~finally:(fun () -> Stdlib.close_out_noerr oc)
        (fun () -> Stdlib.output_string oc content))
;;

let mkdir_p_unix (path : string) : unit =
  let rec ensure_dir (p : string) : unit =
    if String.equal p "" || String.equal p "." || String.equal p "/"
    then ()
    else if Stdlib.Sys.file_exists p
    then ()
    else (
      ensure_dir (Stdlib.Filename.dirname p);
      try Unix.mkdir p 0o755 with
      | Unix.Unix_error (Unix.EEXIST, _, _) -> ())
  in
  ensure_dir path
;;

(** Load entire file contents as string.
    Eio-native when available, fallback to Unix.
    @raises Sys_error on all I/O failures. Eio.Io is normalized internally. *)
let load_file (path : string) : string =
  with_fs_or_fallback
    ~path
    ~fallback:(fun () -> load_file_unix path)
    (fun fs ->
       let eio_path = Eio.Path.(fs / path) in
       Eio.Path.load eio_path)
;;

(** Save string to file (overwrite).
    Eio-native when available, fallback to Unix.
    @raises Sys_error on all I/O failures. Eio.Io is normalized internally. *)
let save_file (path : string) (content : string) : unit =
  test_exec_home_guard ~op:"save_file" path;
  with_fs_or_fallback
    ~path
    ~fallback:(fun () -> save_file_unix path content)
    (fun fs ->
       let eio_path = Eio.Path.(fs / path) in
       Eio.Path.save ~create:(`Or_truncate 0o644) eio_path content)
;;

let save_file_atomic path content =
  Atomic_write.save_file_atomic ~save_file path content
;;

let open_atomic_temp_file ~temp_dir () =
  Atomic_write.open_atomic_temp_file ~temp_dir ()
;;

let is_atomic_orphan_name = Atomic_write.is_atomic_orphan_name
type atomic_orphan_cleanup_scope = Atomic_write.atomic_orphan_cleanup_scope =
  | Directory_only
  | Directory_and_immediate_subdirectories

type atomic_orphan_cleanup_operation = Atomic_write.atomic_orphan_cleanup_operation =
  | Inspect_cleanup_root
  | Read_cleanup_directory
  | Inspect_orphan
  | Create_recovery_directory
  | Sync_recovery_parent
  | Link_preserved_orphan
  | Verify_preserved_orphan
  | Sync_preserved_orphan
  | Sync_recovery_directory
  | Delete_empty_orphan
  | Delete_preserved_source
  | Sync_source_directory
  | Close_cleanup_descriptor

type atomic_orphan_cleanup_cause = Atomic_write.atomic_orphan_cleanup_cause =
  | Unix_failure of Unix.error * string * string
  | Sys_failure of string
  | Unexpected_file_kind of Unix.file_kind
  | Outside_ownership_root of { ownership_root : string }
  | Identity_changed
  | Other_failure of exn

type atomic_orphan_cleanup_failure = Atomic_write.atomic_orphan_cleanup_failure =
  { operation : atomic_orphan_cleanup_operation
  ; path : string
  ; cause : atomic_orphan_cleanup_cause
  }

type atomic_orphan_cleanup_report = Atomic_write.atomic_orphan_cleanup_report =
  { inspected : int
  ; deleted : int
  ; preserved : int
  ; failures : atomic_orphan_cleanup_failure list
  }

let atomic_orphan_cleanup_failure_to_string =
  Atomic_write.atomic_orphan_cleanup_failure_to_string
;;

let cleanup_atomic_orphans ~ownership_root ~base_path ~scope () =
  Atomic_write.cleanup_atomic_orphans ~ownership_root ~base_path ~scope ()
;;

(** Append string to file.
    Eio-native when available, fallback to Unix.
    @raises Sys_error on all I/O failures. Eio.Io is normalized internally. *)
let append_file (path : string) (content : string) : unit =
  test_exec_home_guard ~op:"append_file" path;
  with_fs_or_fallback
    ~path
    ~fallback:(fun () -> append_file_unix path content)
    (fun fs ->
       let eio_path = Eio.Path.(fs / path) in
       Eio.Path.save ~append:true ~create:(`If_missing 0o644) eio_path content)
;;

(** Check if file exists.
    Uses Stdlib.Sys.file_exists (works in both Eio and non-Eio contexts). *)
let file_exists (path : string) : bool =
  with_fs_or_fallback
    ~path
    ~fallback:(fun () -> Stdlib.Sys.file_exists path)
    (fun fs ->
       try
         let _ = Eio.Path.stat ~follow:true Eio.Path.(fs / path) in
         true
       with
       | Eio.Io _ -> false)
;;

type path_kind =
  | Missing
  | Directory
  | Other

type exact_path_kind =
  | Exact_missing
  | Exact_kind of Unix.file_kind
  | Exact_unknown

let exact_path_kind ?(follow = true) (path : string) : exact_path_kind =
  with_fs_or_fallback
    ~path
    ~fallback:(fun () ->
      try
        let stats = if follow then Unix.stat path else Unix.lstat path in
        Exact_kind stats.Unix.st_kind
      with
      | Unix.Unix_error (Unix.ENOENT, _, _) -> Exact_missing)
    (fun fs ->
       match Eio.Path.kind ~follow Eio.Path.(fs / path) with
       | `Not_found -> Exact_missing
       | `Directory -> Exact_kind Unix.S_DIR
       | `Fifo -> Exact_kind Unix.S_FIFO
       | `Character_special -> Exact_kind Unix.S_CHR
       | `Block_device -> Exact_kind Unix.S_BLK
       | `Regular_file -> Exact_kind Unix.S_REG
       | `Symbolic_link -> Exact_kind Unix.S_LNK
       | `Socket -> Exact_kind Unix.S_SOCK
       | `Unknown -> Exact_unknown)
;;

let path_kind ?(follow = true) (path : string) : path_kind =
  match exact_path_kind ~follow path with
  | Exact_missing -> Missing
  | Exact_kind Unix.S_DIR -> Directory
  | Exact_kind
      (Unix.S_REG | Unix.S_CHR | Unix.S_BLK | Unix.S_LNK | Unix.S_FIFO
      | Unix.S_SOCK)
  | Exact_unknown -> Other
;;

type owned_directory_chain_rejection = Owned_directory_chain.rejection =
  | Owned_path_outside_root of
      { ownership_root : string
      ; path : string
      }
  | Owned_path_non_directory of
      { path : string
      ; kind : Unix.file_kind
      }

type owned_directory_chain_observation = Owned_directory_chain.observation =
  | Owned_directory_missing
  | Owned_directory of Unix.stats

let inspect_owned_directory_chain = Owned_directory_chain.inspect
let owned_directory_paths = Owned_directory_chain.paths

let owned_directory_chain_rejection_to_string =
  Owned_directory_chain.rejection_to_string
;;

type owned_regular_file_read_operation =
  | Inspect_parent
  | Inspect_path
  | Open_path
  | Inspect_descriptor
  | Read_contents
  | Close_descriptor

type owned_regular_file_read_failure =
  | Ownership_boundary_rejected of
      { path : string
      ; rejection : owned_directory_chain_rejection
      }
  | Path_is_not_regular_file of
      { path : string
      ; kind : Unix.file_kind
      }
  | Filesystem_identity_changed of { path : string }
  | Owned_file_operation_failed of
      { path : string
      ; operation : owned_regular_file_read_operation
      ; cause : exn
      }

type owned_regular_file_read_error =
  { failure : owned_regular_file_read_failure
  ; close_failure : exn option
  }

let owned_regular_file_read_operation_to_string = function
  | Inspect_parent -> "inspect_parent"
  | Inspect_path -> "inspect_path"
  | Open_path -> "open_path"
  | Inspect_descriptor -> "inspect_descriptor"
  | Read_contents -> "read_contents"
  | Close_descriptor -> "close_descriptor"
;;

let file_kind_to_string = function
  | Unix.S_REG -> "regular_file"
  | Unix.S_DIR -> "directory"
  | Unix.S_CHR -> "character_device"
  | Unix.S_BLK -> "block_device"
  | Unix.S_LNK -> "symbolic_link"
  | Unix.S_FIFO -> "fifo"
  | Unix.S_SOCK -> "socket"
;;

let owned_regular_file_read_failure_to_string = function
  | Ownership_boundary_rejected { path; rejection } ->
    Printf.sprintf
      "owned file boundary rejected path=%s reason=%s"
      path
      (owned_directory_chain_rejection_to_string rejection)
  | Path_is_not_regular_file { path; kind } ->
    Printf.sprintf
      "owned file path is not a regular file path=%s kind=%s"
      path
      (file_kind_to_string kind)
  | Filesystem_identity_changed { path } ->
    Printf.sprintf "owned file identity changed during read path=%s" path
  | Owned_file_operation_failed { path; operation; cause } ->
    Printf.sprintf
      "owned file operation failed path=%s operation=%s reason=%s"
      path
      (owned_regular_file_read_operation_to_string operation)
      (Printexc.to_string cause)
;;

let owned_regular_file_read_error_to_string { failure; close_failure } =
  let primary = owned_regular_file_read_failure_to_string failure in
  match close_failure with
  | None -> primary
  | Some cause ->
    Printf.sprintf
      "%s; descriptor close also failed: %s"
      primary
      (Printexc.to_string cause)
;;

let same_file_identity (left : Unix.stats) (right : Unix.stats) =
  left.st_dev = right.st_dev && left.st_ino = right.st_ino
;;

let same_file_snapshot (left : Unix.stats) (right : Unix.stats) =
  same_file_identity left right
  && left.st_kind = right.st_kind
  && left.st_size = right.st_size
  && left.st_mtime = right.st_mtime
  && left.st_ctime = right.st_ctime
;;

let owned_file_error failure = Error { failure; close_failure = None }

let owned_file_operation_error ~path operation cause =
  owned_file_error (Owned_file_operation_failed { path; operation; cause })
;;

let reraise_current exn =
  Printexc.raise_with_backtrace exn (Printexc.get_raw_backtrace ())
;;

let read_exact_file_descriptor ~path fd length =
  try
    let bytes = Bytes.create length in
    let rec read offset =
      if offset = length
      then Ok (Bytes.unsafe_to_string bytes)
      else
        match Unix.read fd bytes offset (length - offset) with
        | 0 -> owned_file_error (Filesystem_identity_changed { path })
        | count -> read (offset + count)
        | exception Unix.Unix_error (Unix.EINTR, _, _) -> read offset
    in
    read 0
  with
  | Eio.Cancel.Cancelled _ as cancellation -> reraise_current cancellation
  | cause -> owned_file_operation_error ~path Read_contents cause
;;

let load_owned_regular_file_blocking ~ownership_root path =
  let parent = Filename.dirname path in
  let inspect_parent () =
    try
      match inspect_owned_directory_chain ~ownership_root parent with
      | Ok observation -> Ok observation
      | Error rejection ->
        owned_file_error (Ownership_boundary_rejected { path; rejection })
    with
    | Eio.Cancel.Cancelled _ as cancellation -> reraise_current cancellation
    | cause -> owned_file_operation_error ~path Inspect_parent cause
  in
  let inspect_current parent_before descriptor =
    match inspect_parent () with
    | Error _ as error -> error
    | Ok Owned_directory_missing -> Ok false
    | Ok (Owned_directory parent_now) ->
      if not (same_file_identity parent_before parent_now)
      then Ok false
      else
        (try
           let current = Unix.lstat path in
           Ok
             (current.st_kind = Unix.S_REG
              && same_file_identity descriptor current)
         with
         | Unix.Unix_error (Unix.ENOENT, _, _) -> Ok false
         | Eio.Cancel.Cancelled _ as cancellation -> reraise_current cancellation
         | cause -> owned_file_operation_error ~path Inspect_path cause)
  in
  match inspect_parent () with
  | Error _ as error -> error
  | Ok Owned_directory_missing -> Ok None
  | Ok (Owned_directory parent_before) ->
    let before_open =
      try Ok (Some (Unix.lstat path)) with
      | Unix.Unix_error (Unix.ENOENT, _, _) -> Ok None
      | Eio.Cancel.Cancelled _ as cancellation -> reraise_current cancellation
      | cause -> owned_file_operation_error ~path Inspect_path cause
    in
    (match before_open with
     | Error _ as error -> error
     | Ok None -> Ok None
     | Ok (Some stat) when stat.st_kind <> Unix.S_REG ->
       owned_file_error (Path_is_not_regular_file { path; kind = stat.st_kind })
     | Ok (Some before_open) ->
       let opened =
         try
           Ok
             (Unix.openfile
                path
                [ Unix.O_RDONLY; Unix.O_NONBLOCK; Unix.O_CLOEXEC ]
                0)
         with
         | Eio.Cancel.Cancelled _ as cancellation -> reraise_current cancellation
         | cause -> owned_file_operation_error ~path Open_path cause
       in
       (match opened with
        | Error _ as error -> error
        | Ok fd ->
          let result =
            match Unix.fstat fd with
            | exception cause ->
              owned_file_operation_error ~path Inspect_descriptor cause
            | descriptor
              when descriptor.st_kind <> Unix.S_REG
                   || not (same_file_identity before_open descriptor) ->
              owned_file_error (Filesystem_identity_changed { path })
            | descriptor ->
              (match inspect_current parent_before descriptor with
               | Error _ as error -> error
               | Ok false ->
                 owned_file_error (Filesystem_identity_changed { path })
               | Ok true ->
                 (match read_exact_file_descriptor ~path fd descriptor.st_size with
                  | Error _ as error -> error
                  | Ok content ->
                    (match Unix.fstat fd with
                     | after_read when same_file_snapshot descriptor after_read ->
                       (match inspect_current parent_before descriptor with
                        | Error _ as error -> error
                        | Ok true -> Ok (Some content)
                        | Ok false ->
                          owned_file_error
                            (Filesystem_identity_changed { path }))
                     | _ ->
                       owned_file_error (Filesystem_identity_changed { path })
                     | exception cause ->
                       owned_file_operation_error
                         ~path
                         Inspect_descriptor
                         cause)))
          in
          let close_result =
            try Unix.close fd; Ok () with
            | Eio.Cancel.Cancelled _ as cancellation ->
              reraise_current cancellation
            | cause -> Error cause
          in
          (match close_result, result with
           | Ok (), result -> result
           | Error cause, Ok _ ->
             owned_file_operation_error ~path Close_descriptor cause
           | Error cause, Error error ->
             Error { error with close_failure = Some cause })))
;;

let load_owned_regular_file ~ownership_root path =
  with_fs_or_fallback
    ~path
    ~fallback:(fun () -> load_owned_regular_file_blocking ~ownership_root path)
    (fun _fs ->
       let result =
         Eio_unix.run_in_systhread (fun () ->
           load_owned_regular_file_blocking ~ownership_root path)
       in
       Eio.Fiber.check ();
       result)
;;

let read_dir (path : string) : string list =
  with_fs_or_fallback
    ~path
    ~fallback:(fun () ->
      Stdlib.Sys.readdir path
      |> Array.to_list
      |> List.sort String.compare)
    (fun fs ->
       Eio.Path.read_dir Eio.Path.(fs / path) |> List.sort String.compare)
;;

(** Load entire file contents as string, or [None] when the file is
    missing. Option-returning sibling of {!load_file} (which raises on a
    missing path). [Sys_error] from a vanished file (TOCTOU race after the
    [file_exists] check) is also mapped to [None]; other I/O failures of an
    existing file propagate as [Sys_error], matching {!load_file}. *)
let load_file_opt (path : string) : string option =
  if not (file_exists path)
  then None
  else (
    try Some (load_file path) with
    | Sys_error _ when not (file_exists path) -> None)
;;

let file_size (path : string) : int option =
  with_fs_or_fallback
    ~path
    ~fallback:(fun () ->
      try Some (Unix.stat path).st_size with
      | Unix.Unix_error _ -> None)
    (fun _fs ->
       try Some (Eio_unix.run_in_systhread (fun () -> (Unix.stat path).st_size)) with
       | Unix.Unix_error _ -> None)
;;

let file_mtime (path : string) : float option =
  with_fs_or_fallback
    ~path
    ~fallback:(fun () ->
      try Some (Unix.stat path).st_mtime with
      | Unix.Unix_error _ -> None)
    (fun _fs ->
       try Some (Eio_unix.run_in_systhread (fun () -> (Unix.stat path).st_mtime)) with
       | Unix.Unix_error _ -> None)
;;

let rename (src : string) (dst : string) : unit =
  with_fs_or_fallback
    ~path:src
    ~fallback:(fun () -> Stdlib.Sys.rename src dst)
    (fun fs -> Eio.Path.rename Eio.Path.(fs / src) Eio.Path.(fs / dst))
;;

(* Both runtime paths catch the missing-source case explicitly rather
   than substring-matching on the libc error text. Stdlib's [Sys.rename]
   raises [Sys_error] with a libc-translated, locale-sensitive message;
   matching "No such file" against it skips the Eio path where
   [Eio.Io (Eio.Fs.E (Eio.Fs.Not_found _))] is propagated instead (the
   [with_io] normalizer wraps it into a [Sys_error] whose body does not
   necessarily contain "No such file"). The result was a silent
   path-dependent classifier failure: callers using the substring guard
   only recognized the missing-source case under the Stdlib fallback. *)
let rename_if_exists ~src ~dst =
  with_fs_or_fallback
    ~path:src
    ~fallback:(fun () ->
      try
        Stdlib.Sys.rename src dst;
        true
      with
      | Sys_error _ when not (Stdlib.Sys.file_exists src) -> false)
    (fun fs ->
      try
        Eio.Path.rename Eio.Path.(fs / src) Eio.Path.(fs / dst);
        true
      with
      | Eio.Io (Eio.Fs.E (Eio.Fs.Not_found _), _) -> false)
;;

let rmdir (path : string) : unit =
  with_fs_or_fallback
    ~path
    ~fallback:(fun () -> Unix.rmdir path)
    (fun fs -> Eio.Path.rmdir Eio.Path.(fs / path))
;;

let remove_tree_unix (path : string) : unit =
  let rec remove path =
    match Unix.lstat path with
    | exception Unix.Unix_error (Unix.ENOENT, _, _) -> ()
    | exception Unix.Unix_error (Unix.ENOTDIR, _, _) -> ()
    | stat when stat.Unix.st_kind = Unix.S_DIR ->
      Sys.readdir path
      |> Array.iter (fun name -> remove (Filename.concat path name));
      Unix.rmdir path
    | _stat -> Sys.remove path
  in
  remove path
;;

let remove_tree (path : string) : unit =
  let normalized = String.trim path in
  if String.equal normalized "" || String.equal normalized "/" || String.equal normalized "."
  then invalid_arg (Printf.sprintf "Fs_compat.remove_tree refuses unsafe path %S" path);
  test_exec_home_guard ~op:"remove_tree" path;
  with_fs_or_fallback
    ~path
    ~fallback:(fun () -> remove_tree_unix path)
    (fun _fs -> Eio_unix.run_in_systhread (fun () -> remove_tree_unix path))
;;

let realpath (path : string) : string =
  with_fs_or_fallback
    ~path
    ~fallback:(fun () -> Unix.realpath path)
    (fun _fs -> Eio_unix.run_in_systhread (fun () -> Unix.realpath path))
;;

(** Create directory recursively if not exists.
    @raises Sys_error on all I/O failures. Eio.Io is normalized internally. *)
let mkdir_p (path : string) : unit =
  test_exec_home_guard ~op:"mkdir_p" path;
  with_fs_or_fallback
    ~path
    ~fallback:(fun () -> mkdir_p_unix path)
    (fun fs ->
       let eio_path = Eio.Path.(fs / path) in
       Eio.Path.mkdirs ~exists_ok:true ~perm:0o755 eio_path)
;;

(* RFC-0162 §3.1: once-per-path mkdir memoize. Hot append paths
   ([append_jsonl] in particular) call [mkdir_p] on every record so
   that the day-rollover dir gets created on first append. After the
   dir exists, every subsequent call only burns a [Sys.file_exists]
   or [Eio.Path.mkdirs ~exists_ok:true] stat syscall — yet on the
   tool_call_io path this adds up to ~22k stats over a few hours and
   contributes to the EMFILE/ENFILE pressure documented in the RFC.

   The cache stores only the *fact* that the dir exists; it does not
   keep an fd open. RFC-0108 §2.5's cached [out_channel] corruption
   does not apply. RFC-0108 §3.3 (cross-domain fd cache) is unrelated.

   Race: two domains may both miss-and-mkdir; the second [mkdir] is a
   harmless EEXIST. The mutex covers the [Hashtbl] op only. *)
let mkdir_p_memoized path = Mkdir_memo.mkdir_p_memoized ~mkdir_p path
let reset_mkdir_memo_for_testing () = Mkdir_memo.reset_for_testing ()

(** Parse pre-read string lines as JSONL.
    Use when lines come from typed tail readers such as
    [Keeper_memory.read_file_tail_lines_result] or other non-file
    sources.  Logs malformed lines with [source] tag.

    Matches [fold_jsonl]'s line-tracking semantics: [line_no] is
    1-based, increments only on non-blank lines so it tracks the
    {b printed} JSONL row number an operator would see in [cat -n].
    Aligns with the file-level diagnostic at line 559 ("line %d") so
    a malformed log from either path uses the same orchestrate system. *)
let parse_jsonl_lines ~(source : string) (lines : string list) : Yojson.Safe.t list * int =
  let malformed = ref 0 in
  let line_no = ref 0 in
  let parsed =
    List.filter_map
      (fun line ->
         let trimmed = String.trim line in
         if String.equal trimmed ""
         then None
         else (
           incr line_no;
           match Yojson.Safe.from_string trimmed with
           | json -> Some json
           | exception Yojson.Json_error msg ->
             incr malformed;
             Stdlib.Printf.eprintf
               "[fs_compat] malformed JSONL (%s) line %d: %s\n%!"
               source
               !line_no
               msg;
             None))
      lines
  in
  parsed, !malformed
;;

(** Load JSONL file, returning parsed values and count of malformed lines.
    Delegates to [parse_jsonl_lines] for the actual parsing. *)
let load_jsonl_diagnostics (path : string) : Yojson.Safe.t list * int =
  if not (file_exists path)
  then [], 0
  else (
    let content = load_file path in
    let lines = String.split_on_char '\n' content in
    parse_jsonl_lines ~source:path lines)
;;

(** Load JSONL file as list of JSON values.
    Malformed lines are logged and dropped. *)
let load_jsonl (path : string) : Yojson.Safe.t list = fst (load_jsonl_diagnostics path)

(* Bounded byte slice of a file. Clamps to the current size; a missing
   file or an empty clamped range returns "". Stdlib-blocking like the
   other tail-readers — callers bound [len], so the read cost is fixed
   regardless of file size (RFC-0228 P1). *)
let read_slice ~path ~from ~len =
  if not (file_exists path) || len <= 0 then ""
  else begin
    let ic = Stdlib.open_in_bin path in
    Stdlib.Fun.protect
      ~finally:(fun () -> Stdlib.close_in_noerr ic)
      (fun () ->
         let size = Stdlib.in_channel_length ic in
         let from = if from < 0 then 0 else if from > size then size else from in
         let len = Stdlib.min len (size - from) in
         if len <= 0 then ""
         else begin
           Stdlib.seek_in ic from;
           Stdlib.really_input_string ic len
         end)
  end
;;

(* Fold over newline-terminated lines appended after byte offset [from].
   Append-only JSONL stores never rewrite earlier bytes, so a (offset,
   accumulator) pair is a pure function of the file prefix — callers cache
   it and re-scan only the delta instead of the whole file. Bytes after the
   last '\n' (a partially flushed line) are excluded from both the fold and
   the returned boundary, so the next call re-reads them once the writer
   completes the line. A [from] beyond EOF (file truncated/rotated) falls
   back to a full scan from byte 0; callers detect shrinkage the same way
   via the returned boundary. Blank lines advance the boundary but are not
   folded. *)
let fold_appended_lines ~path ~from ~init ~f =
  if not (file_exists path)
  then init, 0
  else begin
    let ic = open_in_bin path in
    Fun.protect
      ~finally:(fun () -> close_in_noerr ic)
      (fun () ->
         let len = in_channel_length ic in
         let from = if from < 0 || from > len then 0 else from in
         seek_in ic from;
         let chunk = Bytes.create 65536 in
         let line_buf = Buffer.create 256 in
         let acc = ref init in
         let boundary = ref from in
         let pos = ref from in
         let rec loop () =
           let n = input ic chunk 0 (Bytes.length chunk) in
           if n > 0
           then begin
             for i = 0 to n - 1 do
               match Bytes.get chunk i with
               | '\n' ->
                 let line = Buffer.contents line_buf in
                 Buffer.clear line_buf;
                 boundary := !pos + i + 1;
                 if not (String.equal (String.trim line) "")
                 then acc := f !acc line
               | c -> Buffer.add_char line_buf c
             done;
             pos := !pos + n;
             loop ()
           end
         in
         loop ();
         !acc, !boundary)
  end
;;

(** Stream JSONL line-by-line, folding [f] over parsed values.

    Uses [Eio.Buf_read.lines] over [Eio.Path.with_open_in] when the
    global fs is registered ([set_fs] called at boot), giving O(1)
    memory regardless of file size and non-blocking IO inside
    the Eio scheduler.  Falls back to {!load_jsonl} + [List.fold_left]
    when no fs is available (tests, pre-boot helpers).

    [line_no] is 1-based and skips blank lines so it tracks the
    {b printed} JSONL row number rather than the raw byte stream
    position — matches {!load_jsonl_diagnostics} semantics.

    Malformed JSON lines are skipped after a stderr warning, like
    {!load_jsonl_diagnostics}.  Returns [init] when [path] does not
    exist (no read attempt).  Raises [Sys_error] on read failures of
    an existing file (e.g. permission denied, mid-stream IO error). *)
let fold_jsonl_lines ~init ~f path =
  if not (file_exists path)
  then init
  else
    (* 16 MiB per-line cap — protects [Eio.Buf_read.of_flow] from a
       corrupted/attacker-controlled JSONL with no newlines (which
       would otherwise force the buf_read to grow unbounded).  Real
       audit/metric rows are <1 KiB; 16 MiB is two orders of
       magnitude over expected and still bounds the OOM blast. *)
    let max_line_bytes = 16 * 1024 * 1024 in
    with_fs_or_fallback
      ~path
      ~fallback:(fun () ->
        (* Iterate raw lines so [line_no] reflects the same "non-blank
           index, malformed counted but skipped" semantics as the Eio
           branch; folding over [fst (load_jsonl_diagnostics ...)] alone
           would skip malformed rows and desync the index. *)
        let line_idx = ref 0 in
        let acc = ref init in
        let chan = Stdlib.open_in path in
        Fun.protect
          ~finally:(fun () -> Stdlib.close_in_noerr chan)
          (fun () ->
            try
              while true do
                let raw = Stdlib.input_line chan in
                let trimmed = String.trim raw in
                if not (String.equal trimmed "")
                then begin
                  incr line_idx;
                  match Yojson.Safe.from_string trimmed with
                  | json -> acc := f !acc ~line_no:!line_idx json
                  | exception Yojson.Json_error msg ->
                    Stdlib.Printf.eprintf
                      "[fs_compat] malformed JSONL (%s) line %d: %s\n%!"
                      path
                      !line_idx
                      msg
                end
              done
            with End_of_file -> ());
        !acc)
      (fun fs ->
         let eio_path = Eio.Path.(fs / path) in
         Eio.Path.with_open_in eio_path (fun flow ->
           let buf = Eio.Buf_read.of_flow ~max_size:max_line_bytes flow in
           let line_idx = ref 0 in
           let acc = ref init in
           Eio.Buf_read.lines buf
           |> Seq.iter (fun raw ->
             let trimmed = String.trim raw in
             if not (String.equal trimmed "")
             then begin
               incr line_idx;
               match Yojson.Safe.from_string trimmed with
               | json -> acc := f !acc ~line_no:!line_idx json
               | exception Yojson.Json_error msg ->
                 Stdlib.Printf.eprintf
                   "[fs_compat] malformed JSONL (%s) line %d: %s\n%!"
                   path
                   !line_idx
                   msg
             end);
           !acc))
;;

(** Append JSON value as line to JSONL file.

    Atomic per record (in-process): the same [append_path_mutex_registry]
    used by {!append_file_unix} serializes callers against each
    other, and a fresh fd is opened and closed around a single
    [output_string] of [record + "\n"]. Cross-domain safe. Records
    of any size are written without interleaving (the mutex spans
    the whole syscall sequence). Crash durability is not guaranteed
    (no fsync).

    PR #15936 introduced this helper with its own per-path
    registry. This commit unifies the registry with
    [append_file_unix] so a caller mixing the two helpers on a
    single path remains race-free. *)
(* RFC-0162 §3.4: per-path fd cache (single fd per path, cross-domain
   serialized by [append_path_mutex_registry]).

   RFC-0108 §3.3 declared cross-domain fd cache an explicit non-goal
   under the assumption that fd count ≈ keeper N (≤64). Production
   evidence (RFC-0162 §1.3) invalidated that on the open/close
   *churn* axis: 22,440 tool calls × fresh open+close per record was
   shifting host kernel filp_cachep slab pressure and contributing
   to the EMFILE/ENFILE trace.

   Design choice — Per-path (not per-domain) cache:
   - A single [out_channel] per path eliminates the cross-domain
     write interleave window that an early RFC draft's per-domain
     design opened up (POSIX O_APPEND+write atomicity is only
     guaranteed up to PIPE_BUF, ~4 KB, and tool-call records
     routinely exceed that).
   - The existing [get_append_path_mutex] is already a cross-domain
     [Stdlib.Mutex] per path. Wrapping [output_string + flush]
     inside it preserves RFC-0108 §3.2's Record-interleave-0
     guarantee verbatim.
   - The cache lookup uses a separate, microsecond-scoped mutex
     ([fd_cache_mu]) so two appends to *different* paths never
     contend on a global fd-cache lock. *)
let close_all_cached_writers () = Fd_cache.close_all ()

let invalidate_cached_writer path =
  let path_mu = get_append_path_mutex path in
  Stdlib.Mutex.protect path_mu (fun () -> Fd_cache.invalidate path)
;;

let reset_fd_cache_for_testing () = Fd_cache.reset_for_testing ()

let with_cached_writer_for_testing path f = Fd_cache.with_writer path f

let rec read_fd_chunks fd buffer =
  let chunk = Bytes.create 65536 in
  match Unix.read fd chunk 0 (Bytes.length chunk) with
  | 0 -> Buffer.contents buffer
  | count ->
    Buffer.add_subbytes buffer chunk 0 count;
    read_fd_chunks fd buffer
  | exception Unix.Unix_error (Unix.EINTR, _, _) -> read_fd_chunks fd buffer

type durable_append_operation =
  | Write
  | Append_fsync
  | Rollback_truncate
  | Rollback_fsync

type durable_append_failure =
  | Unix_error of
      { operation : durable_append_operation
      ; error : Unix.error
      ; function_name : string
      ; argument : string
      }
  | No_write_progress

type durable_append_error =
  { append_failure : durable_append_failure
  ; rollback_failures : durable_append_failure list
  }

let durable_append_operation_to_string = function
  | Write -> "write"
  | Append_fsync -> "append fsync"
  | Rollback_truncate -> "rollback truncate"
  | Rollback_fsync -> "rollback fsync"
;;

let durable_append_failure_to_string = function
  | No_write_progress -> "write made no progress"
  | Unix_error { operation; error; function_name; argument } ->
    Printf.sprintf
      "%s failed: %s (function=%S argument=%S)"
      (durable_append_operation_to_string operation)
      (Unix.error_message error)
      function_name
      argument
;;

let durable_append_error_to_string { append_failure; rollback_failures } =
  let append = durable_append_failure_to_string append_failure in
  match rollback_failures with
  | [] -> Printf.sprintf "durable append failed and rollback succeeded: %s" append
  | failures ->
    Printf.sprintf
      "durable append failed: %s; rollback failed: %s"
      append
      (failures
       |> List.map durable_append_failure_to_string
       |> String.concat "; ")
;;

type durable_append_io_for_testing =
  { write : Unix.file_descr -> bytes -> int -> int -> int
  ; ftruncate : Unix.file_descr -> int -> unit
  ; fsync : Unix.file_descr -> unit
  }

let unix_failure ~operation error function_name argument =
  Unix_error { operation; error; function_name; argument }
;;

let rec write_fd_all ~write fd bytes offset remaining =
  if remaining = 0
  then Ok ()
  else
    match write fd bytes offset remaining with
    | 0 -> Error No_write_progress
    | written -> write_fd_all ~write fd bytes (offset + written) (remaining - written)
    | exception Unix.Unix_error (Unix.EINTR, _, _) ->
      write_fd_all ~write fd bytes offset remaining
    | exception Unix.Unix_error (error, function_name, argument) ->
      Error (unix_failure ~operation:Write error function_name argument)
;;

let rec run_unix_io ~operation f =
  match f () with
  | () -> Ok ()
  | exception Unix.Unix_error (Unix.EINTR, _, _) -> run_unix_io ~operation f
  | exception Unix.Unix_error (error, function_name, argument) ->
    Error (unix_failure ~operation error function_name argument)
;;

let rollback_durable_append ~io ~fd ~original_length =
  let truncate_result =
    run_unix_io ~operation:Rollback_truncate (fun () ->
      io.ftruncate fd original_length)
  in
  let fsync_result =
    run_unix_io ~operation:Rollback_fsync (fun () -> io.fsync fd)
  in
  [ truncate_result; fsync_result ]
  |> List.filter_map (function
    | Ok () -> None
    | Error failure -> Some failure)
;;

let append_fd_durable ~io ~fd ~original_length suffix =
  let bytes = Bytes.of_string suffix in
  let append_result =
    match write_fd_all ~write:io.write fd bytes 0 (Bytes.length bytes) with
    | Error _ as error -> error
    | Ok () -> run_unix_io ~operation:Append_fsync (fun () -> io.fsync fd)
  in
  match append_result with
  | Ok () -> Ok ()
  | Error append_failure ->
    let rollback_failures = rollback_durable_append ~io ~fd ~original_length in
    Error { append_failure; rollback_failures }
;;

let append_fd_durable_for_testing = append_fd_durable

let durable_append_unix_io =
  { write = Unix.write; ftruncate = Unix.ftruncate; fsync = Unix.fsync }
;;

let fsync_parent_directory dir =
  let fd = Unix.openfile dir [ Unix.O_RDONLY; Unix.O_CLOEXEC ] 0 in
  Fun.protect
    ~finally:(fun () -> Unix.close fd)
    (fun () -> Unix.fsync fd)
;;

let rec lock_whole_file fd =
  match Unix.lockf fd Unix.F_LOCK 0 with
  | () -> ()
  | exception Unix.Unix_error (Unix.EINTR, _, _) -> lock_whole_file fd
;;

let run_blocking_durable_append ~path f =
  with_fs_or_fallback
    ~path
    ~fallback:f
    (fun _fs ->
       Eio_unix.run_in_systhread ~label:"fs-compat-durable-append" f)
;;

let update_private_file_durable_locked_result path decide =
  test_exec_home_guard ~op:"update_private_file_durable_locked" path;
  let dir = Filename.dirname path in
  mkdir_p_memoized dir;
  let path_mu = get_append_path_mutex path in
  run_blocking_durable_append ~path (fun () ->
    Stdlib.Mutex.protect path_mu (fun () ->
      let fd =
        Unix.openfile path
          [ Unix.O_RDWR; Unix.O_CREAT; Unix.O_APPEND; Unix.O_CLOEXEC ]
          0o600
      in
      Fun.protect
        ~finally:(fun () -> Unix.close fd)
        (fun () ->
           Unix.fchmod fd 0o600;
           fsync_parent_directory dir;
           (* See Unix.lseek: only the file-position side effect is required. *)
           ignore (Unix.lseek fd 0 Unix.SEEK_SET : int);
           lock_whole_file fd;
           (* See Unix.lseek: only the file-position side effect is required. *)
           ignore (Unix.lseek fd 0 Unix.SEEK_SET : int);
           let existing = read_fd_chunks fd (Buffer.create 4096) in
           let suffix, result = decide existing in
           match suffix with
            | None -> Ok result
            | Some suffix ->
              (* See Unix.lseek: only the file-position side effect is required. *)
              let original_length = Unix.lseek fd 0 Unix.SEEK_END in
              append_fd_durable
                ~io:durable_append_unix_io
                ~fd
                ~original_length
                suffix
              |> Result.map (fun () -> result))))
;;

type private_jsonl_append_error =
  | Incomplete_jsonl_tail
  | Invalid_jsonl_suffix
  | Durable_jsonl_append_failed of durable_append_error

let private_jsonl_append_error_to_string = function
  | Incomplete_jsonl_tail ->
    "existing JSONL file ends with an incomplete row"
  | Invalid_jsonl_suffix ->
    "JSONL append suffix must be non-empty and newline-terminated"
  | Durable_jsonl_append_failed error -> durable_append_error_to_string error
;;

let append_private_jsonl_durable_locked_result path suffix =
  if String.equal suffix ""
     || not (Char.equal suffix.[String.length suffix - 1] '\n')
  then Error Invalid_jsonl_suffix
  else (
    test_exec_home_guard ~op:"append_private_jsonl_durable_locked" path;
    let dir = Filename.dirname path in
    mkdir_p_memoized dir;
    let path_mu = get_append_path_mutex path in
    run_blocking_durable_append ~path (fun () ->
      Stdlib.Mutex.protect path_mu (fun () ->
        let fd =
          Unix.openfile path
            [ Unix.O_RDWR; Unix.O_CREAT; Unix.O_APPEND; Unix.O_CLOEXEC ]
            0o600
        in
        Fun.protect
          ~finally:(fun () -> Unix.close fd)
          (fun () ->
             Unix.fchmod fd 0o600;
             fsync_parent_directory dir;
             (* See Unix.lseek: only the file-position side effect is required. *)
             ignore (Unix.lseek fd 0 Unix.SEEK_SET : int);
             lock_whole_file fd;
             let original_length = Unix.lseek fd 0 Unix.SEEK_END in
             let tail_is_complete =
               if original_length = 0
               then true
               else (
                 (* See Unix.lseek: only the file-position side effect is required. *)
                 ignore (Unix.lseek fd (original_length - 1) Unix.SEEK_SET : int);
                 let byte = Bytes.create 1 in
                 let rec read_tail () =
                   match Unix.read fd byte 0 1 with
                   | 1 -> Char.equal (Bytes.get byte 0) '\n'
                   | 0 -> false
                   | _ -> false
                   | exception Unix.Unix_error (Unix.EINTR, _, _) -> read_tail ()
                 in
                 read_tail ())
             in
             if not tail_is_complete
             then Error Incomplete_jsonl_tail
             else (
               (* See Unix.lseek: only the file-position side effect is required. *)
               ignore (Unix.lseek fd 0 Unix.SEEK_END : int);
               append_fd_durable
                 ~io:durable_append_unix_io
                 ~fd
                 ~original_length
                 suffix
               |> Result.map_error (fun error -> Durable_jsonl_append_failed error))))))
;;

let append_jsonl (path : string) (json : Yojson.Safe.t) : unit =
  test_exec_home_guard ~op:"append_jsonl" path;
  let dir = Stdlib.Filename.dirname path in
  mkdir_p_memoized dir;
  let line = Yojson.Safe.to_string json ^ "\n" in
  let path_mu = get_append_path_mutex path in
  Stdlib.Mutex.protect path_mu (fun () ->
    Fd_cache.with_writer path (fun oc ->
      Stdlib.output_string oc line;
      Stdlib.flush oc))

let append_jsonl_batch (path : string) (jsons : Yojson.Safe.t list) : unit =
  if jsons = [] then ()
  else begin
    test_exec_home_guard ~op:"append_jsonl_batch" path;
    let dir = Stdlib.Filename.dirname path in
    mkdir_p_memoized dir;
    let buf = Buffer.create 4096 in
    List.iter (fun json ->
      Buffer.add_string buf (Yojson.Safe.to_string json);
      Buffer.add_char buf '\n'
    ) jsons;
    let chunk = Buffer.contents buf in
    let path_mu = get_append_path_mutex path in
    Stdlib.Mutex.protect path_mu (fun () ->
      Fd_cache.with_writer path (fun oc ->
        Stdlib.output_string oc chunk;
        Stdlib.flush oc))
  end
;;
