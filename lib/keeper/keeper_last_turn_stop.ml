(* Keeper_last_turn_stop — the process-shared cell that says why a keeper's
   last turn that ran ended before completing.

   Until 2026-09-02 this state lived in a ref inside the keepalive loop and
   only that lane threaded it in and out: a turn that yielded on another
   lane (measured: direct/TUI-attached turns) recorded nothing, so the next
   turn was never told its predecessor was cut by the loop guard (0/3 notice
   delivery on direct turns, 28/32 on keepalive turns, 2026-09-02 wire
   capture). The cell is keyed by base path and keeper name because tests
   for different roots share one process.

   Size and contention: entries are bounded by the distinct (base path,
   keeper) pairs this process has served — one option each, replaced in
   place, so a keeper that goes down and comes back reuses its entry. The
   Mutex-held critical section is a single Hashtbl operation; the
   threads-library lock is the same primitive the rest of this codebase
   uses for module state. *)
let cell : (string, Keeper_turn_checkpoint_reason.t option) Hashtbl.t =
  Hashtbl.create 16
;;

let mutex = Mutex.create ()

let key ~base_path keeper = base_path ^ "\000" ^ keeper

let set ~base_path ~keeper (stop : Keeper_turn_checkpoint_reason.t option) =
  Mutex.lock mutex;
  match Hashtbl.replace cell (key ~base_path keeper) stop with
  | () ->
    Mutex.unlock mutex;
    ()
  | exception e ->
    Mutex.unlock mutex;
    raise e
;;

let get ~base_path ~keeper : Keeper_turn_checkpoint_reason.t option =
  Mutex.lock mutex;
  (* find_opt wraps the stored option in one more layer; both an absent key
     and a stored None read as "nothing to explain". *)
  match Hashtbl.find_opt cell (key ~base_path keeper) with
  | Some stop ->
    Mutex.unlock mutex;
    stop
  | None ->
    Mutex.unlock mutex;
    None
  | exception e ->
    Mutex.unlock mutex;
    raise e
;;
