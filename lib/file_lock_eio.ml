(** File_lock_eio — Cooperative per-key locking via Eio.Mutex.

    Replaces OS-level Unix.lockf (which blocks the entire Eio fiber
    scheduler) with in-memory cooperative locks.  Safe because MASC
    runs as a single process.

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

(** Run [f] while holding the cooperative lock for [path].
    Does NOT touch the filesystem — the lock is purely in-memory. *)
let with_lock path f =
  let mu = get_lock path in
  Eio.Mutex.use_rw ~protect:true mu (fun () -> f ())

(** Number of tracked lock paths (for diagnostics). *)
let lock_count () = Hashtbl.length table
