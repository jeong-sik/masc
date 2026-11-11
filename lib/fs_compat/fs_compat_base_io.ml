open Fs_compat_internal

type cleanup_directory = Owned_tree_cleanup.directory =
  { path : string; device : int; inode : int; owner_uid : int; permissions : int }
let remove_owned_tree = Owned_tree_cleanup.remove

module Atomic_orphan_size_class = Atomic_orphan_size_class
module Durable_file_identity = Durable_file_identity

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

type execution_context = Execution_context.t =
  | Eio_fiber
  | Non_eio

let execution_context = Execution_context.current

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

(* [global_fs] is process-wide, so it is also [Some] on a system thread that
   Eio started. The fiber check comes first: on such a thread [f] would write
   its systhread suspend trace and run any work before its first effect, then
   fail on the missing handler, and [fallback] would run that work again. *)
let with_fs_or_fallback ~path ~fallback f =
  match Atomic.get global_fs, Execution_context.current () with
  | Some fs, Execution_context.Eio_fiber -> with_io ~path (fun () -> f fs)
  | Some _, Execution_context.Non_eio | None, (Execution_context.Eio_fiber | Execution_context.Non_eio) ->
    fallback ()
;;

let read_channel_and_close ~before_read (path : string) ic : string =
  Stdlib.Fun.protect
    ~finally:(fun () -> Stdlib.close_in_noerr ic)
    (fun () ->
       let len = Stdlib.in_channel_length ic in
       before_read ();
       (* A file that shrinks between the length and the read is an I/O failure
          like any other: [load_file_opt] documents [Sys_error] for them. *)
       try Stdlib.really_input_string ic len with
       | End_of_file -> raise (Sys_error (path ^ ": file shrank while it was being read")))
;;

let load_file_unix (path : string) : string =
  read_channel_and_close ~before_read:ignore path (Stdlib.open_in path)
;;

(* The Eio path below creates with 0o644. [Stdlib.open_out] creates with
   0o666 masked by the process umask, so the same [save_file] call produced a
   different mode depending on which branch ran — and which branch runs is
   whether an Eio fs happens to be installed, not anything about the file
   (#29358). The mode is named here so both branches agree. *)
let save_file_mode = 0o644

(* Writes [content] through [fd] and closes it. The channel buffers up to 64
   KiB, so the tail of every smaller write reaches the kernel only at the
   flush; a flush or close error (ENOSPC, EDQUOT, EIO) must reach the caller.
   [close_out_noerr] alone swallowed it, and the atomic writers then fsynced
   and renamed a truncated temp file over a good one. The descriptor is
   closed on every path. *)
let write_all_and_close (fd : Unix.file_descr) (content : string) : unit =
  let oc = Unix.out_channel_of_descr fd in
  match
    Stdlib.output_string oc content;
    Stdlib.flush oc
  with
  | () -> Stdlib.close_out oc
  | exception exn ->
    let backtrace = Printexc.get_raw_backtrace () in
    Stdlib.close_out_noerr oc;
    Printexc.raise_with_backtrace exn backtrace
;;

let save_file_unix (path : string) (content : string) : unit =
  let fd =
    Unix.openfile path [ Unix.O_WRONLY; Unix.O_CREAT; Unix.O_TRUNC ] save_file_mode
  in
  write_all_and_close fd content
;;

(* RFC-0108: per-path Stdlib.Mutex registry + fresh-fd open/close
   on every append.

   Background: prior [Append_fd_cache] LRU cached an [out_channel]
   per path and reused it across calls. Cache lookup was mutex-
   protected, but the OCaml-runtime [out_channel] buffer state is
   not domain-safe — two domains writing through the same cached
   channel corrupted records mid-line (observed 2026-05-17:
   utf-8 multibyte tears across trajectories/, keepers/*/reaction-
   ledger/, plus "}{"-concat in agent-core-events/ — total 243 live
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
  Stdlib.Mutex.protect mu (fun () ->
    Fd_cache.with_writer path (fun oc ->
      Stdlib.output_string oc content;
      Stdlib.flush oc))
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

(* Whole-file reads, writes and appends of regular files block in the
   kernel for as long as the disk takes, and eio_posix runs them on the
   calling fiber: a regular file never reports "not ready", so [readv] and
   [writev] are issued inline. On the live server a 2 MB [save_file] held
   the main domain 120-130 ms and a large [load_file] 40-50 ms per call
   (2026-09-06 fiber trace, labels [with_open_out] and [with_open_in]; RFC
   main-domain-scheduler-latency §8.8). Inside an Eio fiber the three
   primitives therefore run their Unix implementation on a system thread;
   outside Eio they run it inline, as before. *)
(* The label reaches the runtime-events ring as the fiber's suspend reason
   ([Systhread_host.run] suspends the caller under it, whichever domain runs
   the thread), and a trace reads a long run as "resumed from X, suspended on Y". With the file
   named, X and Y identify the code: a run between
   [fs-compat-append-file chat.jsonl] and [fs-compat-load-file memory.json]
   needs no further instrumentation to place. The basename alone keeps the
   label short and is unique enough among the stores a keeper touches. *)
let labelled operation path = operation ^ " " ^ Filename.basename path

let on_systhread ~label f =
  let result = Fs_compat_internal.Systhread_host.run ~label f in
  Eio.Fiber.check ();
  result
;;

(** Load entire file contents as string.
    Read on a system thread inside Eio, inline otherwise.
    @raises Sys_error on all I/O failures. *)
let load_file (path : string) : string =
  with_fs_or_fallback
    ~path
    ~fallback:(fun () -> load_file_unix path)
    (fun _fs ->
       on_systhread
         ~label:(labelled "fs-compat-load-file" path)
         (fun () -> load_file_unix path))
;;

(* The write behind [save_file] and the atomic writers: the path guard on
   the fiber, the open, write and close wherever the caller runs it. The
   atomic writers run it inside their own blocking job. *)
let save_file_blocking (path : string) (content : string) : unit =
  test_exec_home_guard ~op:"save_file" path;
  save_file_unix path content
;;

(** Save string to file (overwrite).
    Written on a system thread inside Eio, inline otherwise.
    @raises Sys_error on all I/O failures. *)
let save_file (path : string) (content : string) : unit =
  test_exec_home_guard ~op:"save_file" path;
  with_fs_or_fallback
    ~path
    ~fallback:(fun () -> save_file_unix path content)
    (fun _fs ->
       on_systhread
         ~label:(labelled "fs-compat-save-file" path)
         (fun () -> save_file_unix path content))
;;

let save_file_atomic path content =
  Atomic_replace.save_file_atomic ~save_file:save_file_blocking path content
;;

let sync_file_and_parent_strict = Atomic_replace.sync_file_and_parent_strict

let save_file_atomic_rename_only path content =
  Atomic_replace.save_file_atomic_rename_only ~save_file:save_file_blocking path content
;;

type atomic_replace_failure_stage =
  Atomic_replace.atomic_replace_failure_stage =
  | Before_rename
  | After_rename

type atomic_replace_failure =
  Atomic_replace.atomic_replace_failure =
  { path : string
  ; stage : atomic_replace_failure_stage
  ; exception_ : exn
  ; backtrace : Printexc.raw_backtrace
  }

let atomic_replace_failure_to_string =
  Atomic_replace.atomic_replace_failure_to_string
;;

let save_file_atomic_rename_only_staged path content =
  Atomic_replace.save_file_atomic_rename_only_staged ~save_file:save_file_blocking path content
;;

let save_file_atomic_strict_staged path content =
  Atomic_replace.save_file_atomic_strict_staged ~save_file:save_file_blocking path content
;;

let write_file_atomic_strict_staged_blocking path ~write =
  Atomic_replace.write_file_atomic_strict_staged_blocking path ~write
;;

let write_file_atomic_strict_staged path ~write =
  Atomic_replace.write_file_atomic_strict_staged path ~write
;;

let save_file_atomic_strict path content =
  Atomic_replace.save_file_atomic_strict ~save_file:save_file_blocking path content
;;

module Atomic_replace_for_testing = struct
  let save_file_atomic_strict_staged ?sync_file ~sync_parent path content =
    Atomic_replace.For_testing.save_file_atomic_strict_staged
      ?sync_file
      ~sync_parent
      ~save_file:save_file_blocking
      path
      content
  ;;

  let write_file_atomic_strict_staged ?sync_file ~sync_parent path ~write =
    Atomic_replace.For_testing.write_file_atomic_strict_staged
      ?sync_file
      ~sync_parent
      path
      ~write
  ;;
end
