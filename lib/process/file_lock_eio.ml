(** File_lock_eio — Cooperative per-key locking via Eio.Mutex + flock.

    Two-layer locking for local filesystem paths:
    1. Eio.Mutex (cooperative) — prevents blocking the Eio fiber scheduler
    2. Unix.lockf F_TLOCK (non-blocking) — preserves cross-process safety

    The Eio.Mutex serializes fibers within the process so most contention
    is resolved cooperatively.  The flock is acquired non-blocking after
    the Eio.Mutex; if another process holds it, we yield and retry.

    Distributed backend paths (Some key in room_utils_ops.ml) are not
    affected — this only replaces the local filesystem lock path. *)

type lock_entry = {
  mu : Eio.Mutex.t;
  mutable last_used : float;
}

let max_lock_entries = 512
let stale_lock_seconds = 600.0

let table : (string, lock_entry) Hashtbl.t = Hashtbl.create 64
let table_mu = Eio.Mutex.create ()

(** Remove entries unused for [stale_lock_seconds] when table exceeds
    [max_lock_entries].  Called under [table_mu]. *)
let prune_stale_entries () =
  if Hashtbl.length table > max_lock_entries then begin
    let now = Time_compat.now () in
    Hashtbl.filter_map_inplace (fun _path entry ->
      if now -. entry.last_used > stale_lock_seconds then None
      else Some entry
    ) table
  end

(** Get or create a mutex for the given file path.
    Falls back to direct Hashtbl access when no Eio context is available
    (e.g. in unit tests that don't use Eio_main.run). *)
let get_lock path =
  let f () =
    prune_stale_entries ();
    match Hashtbl.find_opt table path with
    | Some entry ->
      entry.last_used <- Time_compat.now ();
      entry.mu
    | None ->
      let entry = { mu = Eio.Mutex.create (); last_used = Time_compat.now () } in
      Hashtbl.replace table path entry;
      entry.mu
  in
  Eio_guard.with_mutex table_mu f

let run_blocking_lock_op f = Eio_guard.run_in_systhread f

(** Acquire a non-blocking Unix file lock (F_TLOCK) with retry.
    Must be called from a systhread — the caller is responsible for
    wrapping in [run_blocking_lock_op] or [Eio_unix.run_in_systhread].
    On success, returns the open file descriptor with the lock held.
    On timeout, closes the fd and raises [Failure]. *)
let acquire_flock_retry ?clock ~lock_path ~mode ~perm
    ?(max_attempts = 200) ?(sleep_sec = 0.01) ~caller () =
  let fd = run_blocking_lock_op (fun () -> Unix.openfile lock_path mode perm) in
  let rec acquire attempts =
    if attempts <= 0 then
      raise (Failure (Printf.sprintf "%s: flock timeout on %s after %d attempts"
                        caller lock_path max_attempts))
    else
      let success = run_blocking_lock_op (fun () ->
        try
          Unix.lockf fd Unix.F_TLOCK 0;
          true
        with
        | Unix.Unix_error (Unix.EAGAIN, _, _)
        | Unix.Unix_error (Unix.EACCES, _, _) -> false
      ) in
      if success then fd
      else begin
        (match clock with
         | Some c -> Eio.Time.sleep c sleep_sec
         | None -> Unix.sleepf sleep_sec);
        acquire (attempts - 1)
      end
  in
  try acquire max_attempts
  with exn ->
    run_blocking_lock_op (fun () -> try Unix.close fd with Unix.Unix_error _ -> ());
    raise exn

let acquire_flock_fd ?clock lock_path =
  acquire_flock_retry ?clock ~lock_path
    ~mode:[ Unix.O_CREAT; Unix.O_WRONLY ] ~perm:0o644
    ~caller:"File_lock_eio" ()

let release_flock_fd fd =
  run_blocking_lock_op (fun () ->
      (try Unix.lockf fd Unix.F_ULOCK 0 with Unix.Unix_error _ -> ());
      Unix.close fd)

(** Run [f] while holding only the cooperative per-path mutex.
    Use this for in-memory backends that need single-process fiber
    serialization but do not have a real filesystem artifact to flock. *)
let with_mutex path f =
  let mu = get_lock path in
  Eio_guard.with_mutex mu f

(** Run [f] while holding both the cooperative Eio.Mutex and an
    OS-level flock on [path].lock.  The flock is acquired with F_TLOCK
    (non-blocking) from a system thread so the Eio scheduler stays free.
    Max 200 attempts (~2s with sleeps). *)
let with_lock ?clock path f =
  let run_with_flock () =
    let lock_path = path ^ ".lock" in
    let dir = Filename.dirname lock_path in
    if not (Sys.file_exists dir) then
      (try Unix.mkdir dir 0o755 with Unix.Unix_error (Unix.EEXIST, _, _) -> ());
    let fd = acquire_flock_fd ?clock lock_path in
    Common.protect ~module_name:"file_lock_eio" ~finally_label:"finalizer"
      ~finally:(fun () -> release_flock_fd fd)
      f
  in
  with_mutex path (fun () -> run_with_flock ())

(** Number of tracked lock paths (for diagnostics). *)
let lock_count () = Hashtbl.length table
