(** Keeper_registry — Single source of truth for keeper state.

    Consolidates keeper_keepalive Hashtbl, keeper_resident_supervisor
    Hashtbl, and file-based meta into one registry.

    All operations are serialized via Eio.Mutex (allows other fibers
    to run while waiting, unlike Stdlib.Mutex which blocks the domain).
    Falls back to unprotected access in non-Eio test contexts. *)

open Keeper_types

type keeper_state =
  | Running
  | Paused
  | Stopped

type registry_entry = {
  base_path : string;
  name : string;
  mutable meta : keeper_meta;
  mutable state : keeper_state;
  fiber_stop : bool ref;
  fiber_wakeup : bool ref;
  started_at : float;
  grpc_close : (unit -> unit) option ref;
  done_p : [ `Stopped | `Crashed of string ] Eio.Promise.t;
  done_r : [ `Stopped | `Crashed of string ] Eio.Promise.u;
  mutable restart_count : int;
  mutable last_restart_ts : float;
  mutable crash_log : (float * string) list;
  mutable last_error : string option;
  mutable last_agent_count : int;
  board_wakeups : (string, float) Hashtbl.t;
  mutable board_cursor_ts : float;
  tool_usage : (string, tool_call_entry) Hashtbl.t;
}

let state_to_string = function
  | Running -> "running"
  | Paused -> "paused"
  | Stopped -> "stopped"

let registry : (string, registry_entry) Hashtbl.t = Hashtbl.create 16
let mu = Eio.Mutex.create ()
let running_count_atomic = Atomic.make 0

let registry_key ~base_path name =
  base_path ^ "\x1f" ^ name

let with_lock_rw f = Eio_guard.with_mutex mu f
let with_lock_ro f = Eio_guard.with_mutex mu f

let max_crash_log_entries = 5

let register ~base_path name meta =
  with_lock_rw (fun () ->
    let done_p, done_r = Eio.Promise.create () in
    let key = registry_key ~base_path name in
    (match Hashtbl.find_opt registry key with
     | Some entry when entry.state = Running ->
         Atomic.set running_count_atomic (max 0 (Atomic.get running_count_atomic - 1))
     | _ -> ());
    let entry = {
      base_path;
      name;
      meta;
      state = Running;
      fiber_stop = ref false;
      fiber_wakeup = ref false;
      started_at = Time_compat.now ();
      grpc_close = ref None;
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
    Hashtbl.replace registry key entry;
    Atomic.set running_count_atomic (Atomic.get running_count_atomic + 1);
    entry)

let unregister ~base_path name =
  with_lock_rw (fun () ->
    let key = registry_key ~base_path name in
    (match Hashtbl.find_opt registry key with
     | Some entry when entry.state = Running ->
         Atomic.set running_count_atomic (max 0 (Atomic.get running_count_atomic - 1))
     | _ -> ());
    Hashtbl.remove registry key)

let get ~base_path name =
  with_lock_ro (fun () -> Hashtbl.find_opt registry (registry_key ~base_path name))

let get_exn ~base_path name =
  match get ~base_path name with
  | Some e -> e
  | None -> raise Not_found

let all ?base_path () =
  with_lock_ro (fun () ->
    Hashtbl.fold
      (fun _k v acc ->
        match base_path with
        | Some expected when not (String.equal expected v.base_path) -> acc
        | _ -> v :: acc)
      registry [])

let update_meta ~base_path name meta =
  with_lock_rw (fun () ->
    match Hashtbl.find_opt registry (registry_key ~base_path name) with
    | Some entry -> entry.meta <- meta
    | None -> ())

let set_state ~base_path name state =
  with_lock_rw (fun () ->
    match Hashtbl.find_opt registry (registry_key ~base_path name) with
    | Some entry ->
        if entry.state <> state then begin
          (match (entry.state, state) with
           | Running, (Paused | Stopped) ->
               Atomic.set running_count_atomic
                 (max 0 (Atomic.get running_count_atomic - 1))
           | (Paused | Stopped), Running ->
               Atomic.set running_count_atomic (Atomic.get running_count_atomic + 1)
           | _ -> ());
          entry.state <- state
        end
    | None -> ())

let record_restart ~base_path name =
  with_lock_rw (fun () ->
    match Hashtbl.find_opt registry (registry_key ~base_path name) with
    | Some entry ->
        entry.restart_count <- entry.restart_count + 1;
        entry.last_restart_ts <- Time_compat.now ()
    | None -> ())

let record_error ~base_path name err =
  with_lock_rw (fun () ->
    match Hashtbl.find_opt registry (registry_key ~base_path name) with
    | Some entry -> entry.last_error <- Some err
    | None -> ())

let is_running ~base_path name =
  match get ~base_path name with
  | Some { state = Running; _ } -> true
  | _ -> false

let count_running ?base_path () =
  match base_path with
  | None -> Atomic.get running_count_atomic
  | Some expected ->
      with_lock_ro (fun () ->
        Hashtbl.fold
          (fun _k v acc ->
            if String.equal expected v.base_path && v.state = Running then acc + 1
            else acc)
          registry 0)

let record_crash ~base_path name ts msg =
  with_lock_rw (fun () ->
    match Hashtbl.find_opt registry (registry_key ~base_path name) with
    | Some entry ->
        entry.crash_log <-
          List.filteri (fun i _ -> i < max_crash_log_entries)
            ((ts, msg) :: entry.crash_log)
    | None -> ())

let set_grpc_close ~base_path name close_fn =
  with_lock_rw (fun () ->
    match Hashtbl.find_opt registry (registry_key ~base_path name) with
    | Some entry -> entry.grpc_close := close_fn
    | None -> ())

let started_at ~base_path name =
  match get ~base_path name with
  | Some entry -> Some entry.started_at
  | None -> None

let spawn_slots_available () =
  let max_keepers = Env_config.KeeperBootstrap.max_active_keepers in
  max_keepers <= 0
  || with_lock_ro (fun () -> Hashtbl.length registry < max_keepers)

let wakeup ~base_path name =
  with_lock_rw (fun () ->
    match Hashtbl.find_opt registry (registry_key ~base_path name) with
    | Some entry -> entry.fiber_wakeup := true
    | None -> ())

let wakeup_all ?base_path () =
  with_lock_rw (fun () ->
    Hashtbl.iter (fun _k entry ->
      (match base_path with
       | Some expected when not (String.equal expected entry.base_path) -> ()
       | _ -> if entry.state = Running then entry.fiber_wakeup := true)
    ) registry)

let fiber_health_of ~base_path name =
  with_lock_ro (fun () ->
    match Hashtbl.find_opt registry (registry_key ~base_path name) with
    | None -> Fiber_unknown
    | Some entry ->
        match Eio.Promise.peek entry.done_p with
        | None -> Fiber_alive
        | Some `Stopped -> Fiber_unknown
        | Some (`Crashed _) ->
            let max_restarts = Env_config.KeeperResidentSupervisor.max_restarts in
            if entry.restart_count >= max_restarts
            then Fiber_dead
            else Fiber_zombie)

let crash_log_of ~base_path name =
  match get ~base_path name with
  | Some entry -> entry.crash_log
  | None -> []

let restore_supervisor_state ~base_path name ~restart_count ~last_restart_ts
    ~crash_log =
  with_lock_rw (fun () ->
    match Hashtbl.find_opt registry (registry_key ~base_path name) with
    | Some entry ->
        entry.restart_count <- restart_count;
        entry.last_restart_ts <- last_restart_ts;
        entry.crash_log <- crash_log
    | None -> ())

let get_last_agent_count ~base_path name =
  with_lock_ro (fun () ->
    match Hashtbl.find_opt registry (registry_key ~base_path name) with
    | Some entry -> entry.last_agent_count
    | None -> 0)

let set_last_agent_count ~base_path name count =
  with_lock_rw (fun () ->
    match Hashtbl.find_opt registry (registry_key ~base_path name) with
    | Some entry -> entry.last_agent_count <- count
    | None -> ())

let board_wakeup_allowed ~base_path name ~post_id ~debounce_sec =
  with_lock_rw (fun () ->
    match Hashtbl.find_opt registry (registry_key ~base_path name) with
    | None -> true
    | Some entry ->
        let now_ts = Time_compat.now () in
        match Hashtbl.find_opt entry.board_wakeups post_id with
        | Some last_ts when now_ts -. last_ts < debounce_sec -> false
        | _ ->
            Hashtbl.replace entry.board_wakeups post_id now_ts;
            true)

let clear_board_wakeups ~base_path name =
  with_lock_rw (fun () ->
    match Hashtbl.find_opt registry (registry_key ~base_path name) with
    | Some entry -> Hashtbl.reset entry.board_wakeups
    | None -> ())

let cleanup_tracking ~base_path name =
  with_lock_rw (fun () ->
    match Hashtbl.find_opt registry (registry_key ~base_path name) with
    | Some entry ->
        entry.last_agent_count <- 0;
        Hashtbl.reset entry.board_wakeups;
        entry.board_cursor_ts <- 0.0;
        Hashtbl.reset entry.tool_usage
    | None -> ())

let clear () =
  with_lock_rw (fun () ->
    Hashtbl.clear registry;
    Atomic.set running_count_atomic 0)

(* ── Board cursor ────────────────────────────────────────────── *)

let get_board_cursor_ts ~base_path name =
  with_lock_ro (fun () ->
    match Hashtbl.find_opt registry (registry_key ~base_path name) with
    | Some entry -> entry.board_cursor_ts
    | None -> 0.0)

let set_board_cursor_ts ~base_path name ts =
  with_lock_rw (fun () ->
    match Hashtbl.find_opt registry (registry_key ~base_path name) with
    | Some entry -> entry.board_cursor_ts <- ts
    | None -> ())

(* ── Tool usage tracking ─────────────────────────────────────── *)

let record_tool_use ~base_path name ~tool_name ~success =
  with_lock_rw (fun () ->
    match Hashtbl.find_opt registry (registry_key ~base_path name) with
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
      e.last_used_at <- Time_compat.now ())

let tool_usage_of ~base_path name =
  with_lock_ro (fun () ->
    match Hashtbl.find_opt registry (registry_key ~base_path name) with
    | None -> []
    | Some entry ->
      Hashtbl.fold (fun n e acc -> (n, e) :: acc) entry.tool_usage []
      |> List.sort (fun (_, a) (_, b) -> Int.compare b.count a.count))

(** Look up a keeper by name across all base_paths (O(n) scan). *)
let find_by_name name =
  with_lock_ro (fun () ->
    Hashtbl.fold
      (fun _k v acc ->
        match acc with
        | Some _ -> acc
        | None -> if String.equal v.name name then Some v else None)
      registry None)

let tool_usage_of_by_name name =
  with_lock_ro (fun () ->
    match find_by_name name with
    | None -> []
    | Some entry ->
      Hashtbl.fold (fun n e acc -> (n, e) :: acc) entry.tool_usage []
      |> List.sort (fun (_, a) (_, b) -> Int.compare b.count a.count))
