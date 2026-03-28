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

    Implementation: registry_entry records are immutable (except embedded
    Hashtbl fields board_wakeups and tool_usage which remain mutable
    containers -- Phase 2 target).  Inter-fiber signaling uses [Atomic.t]
    instead of [ref] for lock-free visibility.  The global registry is a
    persistent [StringMap] behind a single [ref]. *)

open Keeper_types

module StringMap = Map.Make (String)

type keeper_state =
  | Running
  | Paused
  | Stopped

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
  crash_log : (float * string) list;
  last_error : string option;
  last_agent_count : int;
  board_wakeups : (string, float) Hashtbl.t;
  board_cursor_ts : float;
  tool_usage : (string, tool_call_entry) Hashtbl.t;
}

let state_to_string = function
  | Running -> "running"
  | Paused -> "paused"
  | Stopped -> "stopped"

let registry : registry_entry StringMap.t ref = ref StringMap.empty
let running_count_atomic = Atomic.make 0

let registry_key ~base_path name =
  base_path ^ "\x1f" ^ name

(** Write an entry back to the registry map. *)
let put_entry key entry =
  registry := StringMap.add key entry !registry

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
    crash_log = [];
    last_error = None;
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
  let key = registry_key ~base_path name in
  match StringMap.find_opt key !registry with
  | Some entry -> put_entry key { entry with meta }
  | None -> ()

let () =
  register_runtime_meta_write_sync (fun config meta ->
      update_meta ~base_path:config.base_path meta.name meta)

let set_state ~base_path name state =
  let key = registry_key ~base_path name in
  match StringMap.find_opt key !registry with
  | Some entry ->
      if entry.state <> state then begin
        (match (entry.state, state) with
         | Running, (Paused | Stopped) ->
             Atomic.set running_count_atomic
               (max 0 (Atomic.get running_count_atomic - 1))
         | (Paused | Stopped), Running ->
             Atomic.set running_count_atomic (Atomic.get running_count_atomic + 1)
         | _ -> ());
        put_entry key { entry with state }
      end
  | None -> ()

let record_restart ~base_path name =
  let key = registry_key ~base_path name in
  match StringMap.find_opt key !registry with
  | Some entry ->
      put_entry key { entry with
        restart_count = entry.restart_count + 1;
        last_restart_ts = Time_compat.now () }
  | None -> ()

let record_error ~base_path name err =
  let key = registry_key ~base_path name in
  match StringMap.find_opt key !registry with
  | Some entry -> put_entry key { entry with last_error = Some err }
  | None -> ()

let is_running ~base_path name =
  match get ~base_path name with
  | Some { state = Running; _ } -> true
  | _ -> false

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
  let key = registry_key ~base_path name in
  match StringMap.find_opt key !registry with
  | Some entry ->
      put_entry key { entry with
        crash_log =
          List.filteri (fun i _ -> i < max_crash_log_entries)
            ((ts, msg) :: entry.crash_log) }
  | None -> ()

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
  || StringMap.cardinal !registry < max_keepers

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
  let key = registry_key ~base_path name in
  match StringMap.find_opt key !registry with
  | Some entry ->
      put_entry key { entry with restart_count; last_restart_ts; crash_log }
  | None -> ()

let get_last_agent_count ~base_path name =
  match StringMap.find_opt (registry_key ~base_path name) !registry with
  | Some entry -> entry.last_agent_count
  | None -> 0

let set_last_agent_count ~base_path name count =
  let key = registry_key ~base_path name in
  match StringMap.find_opt key !registry with
  | Some entry -> put_entry key { entry with last_agent_count = count }
  | None -> ()

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
  let key = registry_key ~base_path name in
  match StringMap.find_opt key !registry with
  | Some entry -> put_entry key { entry with board_cursor_ts = ts }
  | None -> ()

(* -- Tool usage tracking ------------------------------------------- *)

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
