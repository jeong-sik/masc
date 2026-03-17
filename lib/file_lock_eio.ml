(** File_lock_eio — Cooperative per-key locking via Eio.Mutex + flock.

    Two-layer locking for local filesystem paths:
    1. Eio.Mutex (cooperative) — prevents blocking the Eio fiber scheduler
    2. Unix.lockf F_TLOCK (non-blocking) — preserves cross-process safety

    The Eio.Mutex serializes fibers within the process so most contention
    is resolved cooperatively.  The flock is acquired non-blocking after
    the Eio.Mutex; if another process holds it, we yield and retry.

    Distributed backend paths (Some key in room_utils_ops.ml) are not
    affected — this only replaces the local filesystem lock path. *)

let table : (string, Eio.Mutex.t) Hashtbl.t = Hashtbl.create 64
let table_mu = Eio.Mutex.create ()

(** Get or create a mutex for the given file path. *)
let get_lock path =
  Eio.Mutex.use_rw ~protect:true table_mu (fun () ->
    match Hashtbl.find_opt table path with
    | Some mu -> mu
    | None ->
      let mu = Eio.Mutex.create () in
      Hashtbl.replace table path mu;
      mu)

(** Run [f] while holding both the cooperative Eio.Mutex and an
    OS-level flock on [path].lock.  The flock is acquired with F_TLOCK
    (non-blocking) and retried with Eio.Fiber.yield to avoid blocking
    the scheduler.  Max 200 attempts (~2s with yields). *)
let with_lock path f =
  let mu = get_lock path in
  Eio.Mutex.use_rw ~protect:true mu (fun () ->
    let lock_path = path ^ ".lock" in
    (* Ensure parent directory exists *)
    let dir = Filename.dirname lock_path in
    if not (Sys.file_exists dir) then
      (try Unix.mkdir dir 0o755 with Unix.Unix_error (Unix.EEXIST, _, _) -> ());
    let fd = Unix.openfile lock_path [Unix.O_CREAT; Unix.O_WRONLY] 0o644 in
    (* Non-blocking flock acquisition with cooperative retry *)
    let rec acquire attempts =
      if attempts <= 0 then
        failwith (Printf.sprintf "File_lock_eio: flock timeout on %s" lock_path)
      else
        try Unix.lockf fd Unix.F_TLOCK 0
        with Unix.Unix_error (Unix.EAGAIN, _, _) | Unix.Unix_error (Unix.EACCES, _, _) ->
          Eio.Fiber.yield ();
          acquire (attempts - 1)
    in
    Common.protect ~module_name:"file_lock_eio" ~finally_label:"finalizer"
      ~finally:(fun () ->
        (try Unix.lockf fd Unix.F_ULOCK 0
         with Unix.Unix_error _ -> ());
        Unix.close fd)
      (fun () ->
        acquire 200;
        f ()))

(** Number of tracked lock paths (for diagnostics). *)
let lock_count () = Hashtbl.length table
