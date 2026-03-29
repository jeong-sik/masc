(** Keeper_registry — Single source of truth for keeper state.

    Consolidates keeper_keepalive Hashtbl, keeper_supervisor
    Hashtbl, and file-based meta into one registry.

    Thread-safety: all operations are non-yielding (in-memory map/ref
    ops only).  In single-domain Eio, the cooperative scheduler only
    switches fibers at yield points (I/O, sleep, stream ops), so
    non-yielding code runs atomically w.r.t. other fibers.  No mutex
    is needed.  See Eio README: "If the operation does not switch
    fibers and the resource is only accessed from one domain, then no
    mutex is needed at all."

    Caveat: board_wakeups and tool_usage are mutable Hashtbl fields
    mutated in-place.  The fiber-atomicity argument still holds because
    each keeper has exactly one owning fiber (the keepalive loop), so
    concurrent mutation of the same entry does not occur.

    Implementation: [Atomic.t] for inter-fiber signaling (lock-free
    visibility); persistent [StringMap] behind a single [ref]. *)

open Keeper_types

module StringMap = Map.Make (String)

(** Structured failure reason for cohort detection in self-preservation.
    ADT matching replaces string prefix matching for crash_msg grouping. *)
type failure_reason =
  | Heartbeat_consecutive_failures of int
  | Fiber_unresolved
  | Exception of string

let failure_reason_to_string = function
  | Heartbeat_consecutive_failures n ->
      Printf.sprintf "heartbeat_consecutive_failures(%d)" n
  | Fiber_unresolved -> "fiber_unresolved"
  | Exception s -> Printf.sprintf "exception(%s)" s

(** Structured exception raised by keeper_keepalive when consecutive
    heartbeat failures exceed the threshold. *)
exception Keeper_heartbeat_failure of {
  reason : failure_reason;
  keeper_name : string;
}

type keeper_state =
  | Running
  | Paused
  | Stopped
  | Crashed  (** Error exit, restart candidate (backoff applies) *)
  | Dead     (** Restart budget exhausted, tombstone — no re-launch *)

type registry_entry = {
  base_path : string;
  name : string;
  meta : keeper_meta;
  state : keeper_state;
  fiber_stop : bool Atomic.t;
  fiber_wakeup : bool Atomic.t;
  started_at : float;
  grpc_close : (unit -> unit) option Atomic.t;
  done_p : [ `Stopped | `Crashed of string ] Eio.Promise.t;
  done_r : [ `Stopped | `Crashed of string ] Eio.Promise.u;
  restart_count : int;
  last_restart_ts : float;
  dead_since_ts : float option;
  crash_log : (float * string) list;
  last_error : string option;
  last_failure_reason : failure_reason option;
  last_agent_count : int;
  board_wakeups : (string, float) Hashtbl.t;
  board_cursor_ts : float;
  tool_usage : (string, tool_call_entry) Hashtbl.t;
}

let state_to_string = function
  | Running -> "running"
  | Paused -> "paused"
  | Stopped -> "stopped"
  | Crashed -> "crashed"
  | Dead -> "dead"

let registry : registry_entry StringMap.t ref = ref StringMap.empty
let running_count_atomic = Atomic.make 0

let registry_key ~base_path name =
  base_path ^ "\x1f" ^ name

let put_entry key entry =
  registry := StringMap.add key entry !registry

(** Apply [f entry] and write back.  No-op if key absent. *)
let update_entry ~base_path name f =
  let key = registry_key ~base_path name in
  match StringMap.find_opt key !registry with
  | Some entry -> put_entry key (f entry)
  | None -> ()

let max_crash_log_entries = 5

let register ~base_path name meta =
  let done_p, done_r = Eio.Promise.create () in
  let key = registry_key ~base_path name in
  (match StringMap.find_opt key !registry with
   | Some entry when entry.state = Running ->
       Atomic.set running_count_atomic (max 0 (Atomic.get running_count_atomic - 1))
   | _ -> ());
  let entry = {
    base_path;
    name;
    meta;
    state = Running;
    fiber_stop = Atomic.make false;
    fiber_wakeup = Atomic.make false;
    started_at = Time_compat.now ();
    grpc_close = Atomic.make None;
    done_p;
    done_r;
    restart_count = 0;
    last_restart_ts = 0.0;
    dead_since_ts = None;
    crash_log = [];
    last_error = None;
    last_failure_reason = None;
    last_agent_count = 0;
    board_wakeups = Hashtbl.create 8;
    board_cursor_ts = 0.0;
    tool_usage = Hashtbl.create 16;
  } in
  put_entry key entry;
  Atomic.set running_count_atomic (Atomic.get running_count_atomic + 1);
  entry

let unregister ~base_path name =
  let key = registry_key ~base_path name in
  (match StringMap.find_opt key !registry with
   | Some entry when entry.state = Running ->
       Atomic.set running_count_atomic (max 0 (Atomic.get running_count_atomic - 1))
   | _ -> ());
  registry := StringMap.remove key !registry

let get ~base_path name =
  StringMap.find_opt (registry_key ~base_path name) !registry

let get_exn ~base_path name =
  match get ~base_path name with
  | Some e -> e
  | None -> raise Not_found

let all ?base_path () =
  StringMap.fold
    (fun _k v acc ->
      match base_path with
      | Some expected when not (String.equal expected v.base_path) -> acc
      | _ -> v :: acc)
    !registry []

let update_meta ~base_path name meta =
  update_entry ~base_path name (fun e -> { e with meta })

let () =
  register_runtime_meta_write_sync (fun config meta ->
      update_meta ~base_path:config.base_path meta.name meta)

let set_state ~base_path name state =
  let key = registry_key ~base_path name in
  match StringMap.find_opt key !registry with
  | Some entry ->
      (* Dead is terminal — only unregister can remove a Dead entry *)
      if entry.state = Dead && state <> Dead then ()
      else if entry.state <> state then begin
        (match (entry.state, state) with
         | Running, (Paused | Stopped | Crashed | Dead) ->
             Atomic.set running_count_atomic
               (max 0 (Atomic.get running_count_atomic - 1))
         | (Paused | Stopped | Crashed), Running ->
             Atomic.set running_count_atomic (Atomic.get running_count_atomic + 1)
         | _ -> ());
        let dead_since_ts =
          match state with
          | Dead -> entry.dead_since_ts
          | _ -> None
        in
        put_entry key { entry with state; dead_since_ts }
      end
  | None -> ()

let mark_dead ~base_path name ~at =
  update_entry ~base_path name (fun entry ->
    if entry.state <> Dead then begin
      (match entry.state with
       | Running ->
           Atomic.set running_count_atomic
             (max 0 (Atomic.get running_count_atomic - 1))
       | _ -> ());
      { entry with state = Dead; dead_since_ts = Some at }
    end else
      { entry with dead_since_ts = Some (Option.value ~default:at entry.dead_since_ts) })

let record_restart ~base_path name =
  update_entry ~base_path name (fun e ->
    { e with restart_count = e.restart_count + 1;
             last_restart_ts = Time_compat.now () })

let record_error ~base_path name err =
  update_entry ~base_path name (fun e -> { e with last_error = Some err })

let set_failure_reason ~base_path name reason =
  update_entry ~base_path name (fun e -> { e with last_failure_reason = reason })

let is_running ~base_path name =
  match get ~base_path name with
  | Some { state = Running; _ } -> true
  | _ -> false

(** True if the keeper has ANY registry entry (regardless of state).
    Used by reconcile to avoid re-launching Crashed/Dead keepers. *)
let is_registered ~base_path name =
  Option.is_some (get ~base_path name)

let count_running ?base_path () =
  match base_path with
  | None -> Atomic.get running_count_atomic
  | Some expected ->
      StringMap.fold
        (fun _k v acc ->
          if String.equal expected v.base_path && v.state = Running then acc + 1
          else acc)
        !registry 0

let record_crash ~base_path name ts msg =
  update_entry ~base_path name (fun e ->
    { e with crash_log =
        List.filteri (fun i _ -> i < max_crash_log_entries)
          ((ts, msg) :: e.crash_log) })

let set_grpc_close ~base_path name close_fn =
  match StringMap.find_opt (registry_key ~base_path name) !registry with
  | Some entry -> Atomic.set entry.grpc_close close_fn
  | None -> ()

let started_at ~base_path name =
  match get ~base_path name with
  | Some entry -> Some entry.started_at
  | None -> None

let spawn_slots_available () =
  let max_keepers = Env_config.KeeperBootstrap.max_active_keepers in
  max_keepers <= 0
  || Atomic.get running_count_atomic < max_keepers

let wakeup ~base_path name =
  match StringMap.find_opt (registry_key ~base_path name) !registry with
  | Some entry -> Atomic.set entry.fiber_wakeup true
  | None -> ()

let wakeup_all ?base_path () =
  StringMap.iter (fun _k entry ->
    (match base_path with
     | Some expected when not (String.equal expected entry.base_path) -> ()
     | _ -> if entry.state = Running then Atomic.set entry.fiber_wakeup true)
  ) !registry

let fiber_health_of ~base_path name =
  match StringMap.find_opt (registry_key ~base_path name) !registry with
  | None -> Fiber_unknown
  | Some entry ->
      if entry.state = Dead then Fiber_dead
      else
        match Eio.Promise.peek entry.done_p with
        | None -> Fiber_alive
        | Some `Stopped -> Fiber_unknown
        | Some (`Crashed _) ->
            let max_restarts = Env_config.KeeperSupervisor.max_restarts in
            if entry.restart_count >= max_restarts
            then Fiber_dead
            else Fiber_zombie

let crash_log_of ~base_path name =
  match get ~base_path name with
  | Some entry -> entry.crash_log
  | None -> []

let restore_supervisor_state ~base_path name ~restart_count ~last_restart_ts
    ~crash_log =
  update_entry ~base_path name (fun e ->
    {
      e with
      restart_count;
      last_restart_ts;
      dead_since_ts = None;
      crash_log;
      last_failure_reason = None;
    })

let get_last_agent_count ~base_path name =
  match StringMap.find_opt (registry_key ~base_path name) !registry with
  | Some entry -> entry.last_agent_count
  | None -> 0

let set_last_agent_count ~base_path name count =
  update_entry ~base_path name (fun e -> { e with last_agent_count = count })

let board_wakeup_allowed ~base_path name ~post_id ~debounce_sec =
  match StringMap.find_opt (registry_key ~base_path name) !registry with
  | None -> true
  | Some entry ->
      let now_ts = Time_compat.now () in
      match Hashtbl.find_opt entry.board_wakeups post_id with
      | Some last_ts when now_ts -. last_ts < debounce_sec -> false
      | _ ->
          Hashtbl.replace entry.board_wakeups post_id now_ts;
          true

let clear_board_wakeups ~base_path name =
  match StringMap.find_opt (registry_key ~base_path name) !registry with
  | Some entry -> Hashtbl.reset entry.board_wakeups
  | None -> ()

let cleanup_tracking ~base_path name =
  let key = registry_key ~base_path name in
  match StringMap.find_opt key !registry with
  | Some entry ->
      Hashtbl.reset entry.board_wakeups;
      Hashtbl.reset entry.tool_usage;
      put_entry key { entry with last_agent_count = 0; board_cursor_ts = 0.0 }
  | None -> ()

let clear () =
  registry := StringMap.empty;
  Atomic.set running_count_atomic 0

(* -- Board cursor -------------------------------------------------- *)

let get_board_cursor_ts ~base_path name =
  match StringMap.find_opt (registry_key ~base_path name) !registry with
  | Some entry -> entry.board_cursor_ts
  | None -> 0.0

let set_board_cursor_ts ~base_path name ts =
  update_entry ~base_path name (fun e -> { e with board_cursor_ts = ts })

(* -- Tool usage tracking ------------------------------------------- *)

(* Safe without mutex: each keeper has exactly one fiber calling
   record_tool_use for a given (base_path, name) pair.  See module
   docstring for thread-safety reasoning. *)
let record_tool_use ~base_path name ~tool_name ~success =
  match StringMap.find_opt (registry_key ~base_path name) !registry with
  | None -> ()
  | Some entry ->
    let e =
      match Hashtbl.find_opt entry.tool_usage tool_name with
      | Some e -> e
      | None ->
        let e = { count = 0; successes = 0; failures = 0;
                  last_used_at = 0.0 } in
        Hashtbl.replace entry.tool_usage tool_name e; e
    in
    e.count <- e.count + 1;
    (if success then e.successes <- e.successes + 1
     else e.failures <- e.failures + 1);
    e.last_used_at <- Time_compat.now ()

let tool_usage_of ~base_path name =
  match StringMap.find_opt (registry_key ~base_path name) !registry with
  | None -> []
  | Some entry ->
    Hashtbl.fold (fun n e acc -> (n, e) :: acc) entry.tool_usage []
    |> List.sort (fun (_, a) (_, b) -> Int.compare b.count a.count)

(** Look up a keeper by name across all base_paths (O(n) scan). *)
let find_by_name name =
  StringMap.fold
    (fun _k v acc ->
      match acc with
      | Some _ -> acc
      | None -> if String.equal v.name name then Some v else None)
    !registry None

let find_by_agent_name agent_name =
  StringMap.fold
    (fun _k v acc ->
      match acc with
      | Some _ -> acc
      | None ->
        if String.equal v.meta.agent_name agent_name then Some v else None)
    !registry None

let tool_usage_of_by_name name =
  match find_by_name name with
  | None -> []
  | Some entry ->
    Hashtbl.fold (fun n e acc -> (n, e) :: acc) entry.tool_usage []
    |> List.sort (fun (_, a) (_, b) -> Int.compare b.count a.count)
