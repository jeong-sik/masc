(* The in-memory pending queue of each Keeper (#43494).

   A registry entry used to carry its own queue: the registration's read
   filled it, and each commit published to whatever entry a registry lookup
   found. A commit between that read and the install found no entry, or the
   one being replaced, and the installed entry missed it until the next
   commit.

   The queue now belongs to the Keeper key, and every entry the Keeper gets
   holds this cell. Both writes run under the Keeper's queue owner lock: a
   registration's read sets the cell, and each commit's [after_commit]
   publishes to it. A commit is therefore either in the read or published to
   the cell the installed entry holds, whenever the install happens.

   A later registration refills the same cell instead of making a new one:
   two registrations of one Keeper can install in either order, and both
   entries must hold the cell commits publish to. A cell lives as long as the
   process: one per Keeper key that registered here. *)

let cells : (string, Keeper_event_queue.t Atomic.t) Hashtbl.t = Hashtbl.create 16

(* Stdlib mutex: both writers hold the queue owner lock and do not yield here. *)
let cells_mutex = Stdlib.Mutex.create ()

let set ~base_path name pending =
  let key = Keeper_registry_types.registry_key ~base_path name in
  Stdlib.Mutex.protect cells_mutex (fun () ->
    match Hashtbl.find_opt cells key with
    | Some cell ->
      Atomic.set cell pending;
      cell
    | None ->
      let cell = Atomic.make pending in
      Hashtbl.replace cells key cell;
      cell)
;;

let publish ~base_path name pending =
  let key = Keeper_registry_types.registry_key ~base_path name in
  Stdlib.Mutex.protect cells_mutex (fun () ->
    match Hashtbl.find_opt cells key with
    | Some cell -> Atomic.set cell pending
    | None -> ())
;;
