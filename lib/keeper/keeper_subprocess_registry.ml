(** Implementation of Keeper_subprocess_registry. See .mli for contract. *)

type drain_result = {
  inspected : int;
  sigterm_sent : int;
  sigkill_sent : int;
  still_alive : int;
}

(* keeper_id -> pid set (represented as a sorted list of ints; sets are
   small per-keeper, list ops are fine). All access goes through
   [registry_mutex]. *)
module IntSet = Set.Make (Int)

let registry : (string, IntSet.t) Hashtbl.t = Hashtbl.create 16
let registry_mutex = Mutex.create ()

let with_lock f =
  Mutex.lock registry_mutex;
  Fun.protect
    ~finally:(fun () -> Mutex.unlock registry_mutex)
    f

let register ~keeper_id ~pid =
  with_lock (fun () ->
    let cur =
      match Hashtbl.find_opt registry keeper_id with
      | Some s -> s
      | None -> IntSet.empty
    in
    Hashtbl.replace registry keeper_id (IntSet.add pid cur))

let unregister ~keeper_id ~pid =
  with_lock (fun () ->
    match Hashtbl.find_opt registry keeper_id with
    | None -> ()
    | Some s ->
      let next = IntSet.remove pid s in
      if IntSet.is_empty next then Hashtbl.remove registry keeper_id
      else Hashtbl.replace registry keeper_id next)

let pids_for ~keeper_id =
  with_lock (fun () ->
    match Hashtbl.find_opt registry keeper_id with
    | None -> []
    | Some s -> IntSet.elements s)

let total_pids () =
  with_lock (fun () ->
    Hashtbl.fold (fun _ s acc -> acc + IntSet.cardinal s) registry 0)

(* Snapshot pids for a keeper and remove them from the registry,
   atomically under the lock. Returns the snapshot. *)
let take_pids ~keeper_id : int list =
  with_lock (fun () ->
    match Hashtbl.find_opt registry keeper_id with
    | None -> []
    | Some s ->
      Hashtbl.remove registry keeper_id;
      IntSet.elements s)

(* Best-effort signal send. Returns true on success. *)
let try_kill ~pid ~signum : bool =
  try Unix.kill pid signum; true
  with Unix.Unix_error _ -> false

(* Best-effort waitpid. Returns Some status if the pid has exited,
   None if it is still alive (or unrelated). *)
let try_reap ~pid : Unix.process_status option =
  try
    match Unix.waitpid [ Unix.WNOHANG ] pid with
    | 0, _ -> None
    | _, status -> Some status
  with
  | Unix.Unix_error (Unix.ECHILD, _, _) ->
    (* Not our child or already reaped. Treat as gone. *)
    Some (Unix.WEXITED 0)
  | Unix.Unix_error _ -> None

let drain ~keeper_id ~grace_ms : drain_result =
  let grace_ms =
    if grace_ms < 10 then 10
    else if grace_ms > 60_000 then 60_000
    else grace_ms
  in
  let pids = take_pids ~keeper_id in
  let inspected = List.length pids in
  if inspected = 0 then
    { inspected = 0; sigterm_sent = 0; sigkill_sent = 0; still_alive = 0 }
  else begin
    let sigterm_sent = ref 0 in
    let sigkill_sent = ref 0 in
    let still_alive = ref 0 in
    (* Phase 1: SIGTERM all *)
    let alive = ref pids in
    List.iter (fun pid ->
      if try_kill ~pid ~signum:Sys.sigterm then incr sigterm_sent
    ) pids;
    (* Wait up to grace_ms for graceful exits. Poll every 50ms. *)
    let deadline = Unix.gettimeofday () +. (float_of_int grace_ms /. 1000.0) in
    let poll_interval = 0.05 in
    let exit_count = ref 0 in
    while !alive <> [] && Unix.gettimeofday () < deadline do
      let still = ref [] in
      List.iter (fun pid ->
        match try_reap ~pid with
        | Some _ -> incr exit_count
        | None -> still := pid :: !still
      ) !alive;
      alive := !still;
      if !alive <> [] then
        match Unix.select [] [] [] poll_interval with
        | _, _, _ -> ()
        | exception Unix.Unix_error (Unix.EINTR, _, _) -> ()
        | exception Unix.Unix_error (err, fn, arg) ->
            Log.Keeper.warn
              "[SubprocessDrain] poll failed fn=%s arg=%s error=%s"
              fn arg (Unix.error_message err)
    done;
    (* Phase 2: SIGKILL stragglers *)
    List.iter (fun pid ->
      if try_kill ~pid ~signum:Sys.sigkill then incr sigkill_sent
      else incr still_alive
    ) !alive;
    (* Reap KILLed processes (best-effort, don't block) *)
    List.iter (fun pid -> ignore (try_reap ~pid)) !alive;
    {
      inspected;
      sigterm_sent = !sigterm_sent;
      sigkill_sent = !sigkill_sent;
      still_alive = !still_alive;
    }
  end

(* Default cleanup hook: on Tombstone_reaped, drain pids for that
   keeper. Logs the result; never raises. *)
let default_hook : Keeper_lifecycle_hooks.hook =
 fun ~keeper_id ev ->
  match ev with
  | Keeper_lifecycle_hooks.Tombstone_reaped ->
    let r = drain ~keeper_id ~grace_ms:5000 in
    if r.inspected > 0 then
      Log.Keeper.info
        "[SubprocessDrain] keeper=%s inspected=%d sigterm=%d sigkill=%d still_alive=%d"
        keeper_id r.inspected r.sigterm_sent r.sigkill_sent r.still_alive
  | Keeper_lifecycle_hooks.Phase_transition _ -> ()

(* Idempotent registration: track whether we've already registered. *)
let registered = Atomic.make false

let register_default_cleanup_hook () =
  if Atomic.compare_and_set registered false true then
    Keeper_lifecycle_hooks.register default_hook

let reset_for_testing () =
  with_lock (fun () -> Hashtbl.clear registry);
  Atomic.set registered false
