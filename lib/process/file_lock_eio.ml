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
  try Eio.Mutex.use_rw ~protect:true table_mu f
  with Stdlib.Effect.Unhandled _ -> f ()

let run_blocking_lock_op f =
  try Eio_unix.run_in_systhread f
  with Stdlib.Effect.Unhandled _ -> f ()

let acquire_flock_fd lock_path =
  run_blocking_lock_op (fun () ->
      let fd = Unix.openfile lock_path [ Unix.O_CREAT; Unix.O_WRONLY ] 0o644 in
      let rec acquire attempts =
        if attempts <= 0 then
          raise (Failure (Printf.sprintf "File_lock_eio: flock timeout on %s" lock_path))
        else
          try
            Unix.lockf fd Unix.F_TLOCK 0;
            fd
          with
          | Unix.Unix_error (Unix.EAGAIN, _, _)
          | Unix.Unix_error (Unix.EACCES, _, _) ->
              Unix.sleepf 0.01;
              acquire (attempts - 1)
      in
      try
        acquire 200
      with exn ->
        Unix.close fd;
        raise exn)

let release_flock_fd fd =
  run_blocking_lock_op (fun () ->
      (try Unix.lockf fd Unix.F_ULOCK 0 with Unix.Unix_error _ -> ());
      Unix.close fd)

(** Run [f] while holding both the cooperative Eio.Mutex and an
    OS-level flock on [path].lock.  The flock is acquired with F_TLOCK
    (non-blocking) from a system thread so the Eio scheduler stays free.
    Max 200 attempts (~2s with sleeps). *)
let with_lock path f =
  let run_with_flock () =
    let lock_path = path ^ ".lock" in
    let dir = Filename.dirname lock_path in
    if not (Sys.file_exists dir) then
      (try Unix.mkdir dir 0o755 with Unix.Unix_error (Unix.EEXIST, _, _) -> ());
    let fd = acquire_flock_fd lock_path in
    Common.protect ~module_name:"file_lock_eio" ~finally_label:"finalizer"
      ~finally:(fun () -> release_flock_fd fd)
      f
  in
  try
    let mu = get_lock path in
    Eio.Mutex.use_rw ~protect:true mu (fun () -> run_with_flock ())
  with Stdlib.Effect.Unhandled _ ->
    (* No Eio context (unit tests): skip cooperative mutex, use flock only *)
    run_with_flock ()

(** Number of tracked lock paths (for diagnostics). *)
let lock_count () = Hashtbl.length table
