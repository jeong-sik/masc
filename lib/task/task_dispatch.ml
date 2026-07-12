(** Task_dispatch - Runtime backend selection for MASC Tasks

    Uses JSONL (Workspace.* functions) only.

    @since 0.7.0
*)

module Workspace = Workspace_core
open Masc_domain

(** Backend variant *)
type task_backend =
  | Jsonl

type backend_state =
  | Uninitialized
  | Active of task_backend

(** Current backend state. Single Atomic.t avoids contradictory
    initialized/backend pairs and removes the OCaml 5 multidomain data
    race that the previous [ref] cell had. Mirrors the pattern already
    used by Board_dispatch.backend_state. *)
let backend_state : backend_state Atomic.t = Atomic.make Uninitialized

let is_initialized () =
  match Atomic.get backend_state with
  | Active _ -> true
  | Uninitialized -> false

(** Initialize JSONL backend. Default fallback. *)
let init_jsonl () =
  if (match Atomic.get backend_state with Active _ -> true | Uninitialized -> false) then
    Log.Task.warn "WARNING: already initialized, ignoring init_jsonl"
  else if Atomic.compare_and_set backend_state Uninitialized (Active Jsonl) then
    Log.Task.info "JSONL backend initialized (using Workspace.* functions)."
  else
    Log.Task.warn "WARNING: backend was concurrently initialized; ignoring init_jsonl"

(** Reset for testing *)
let reset_for_test () =
  Atomic.set backend_state Uninitialized

(** Get current backend, auto-init JSONL if not set *)
let backend () =
  match Atomic.get backend_state with
  | Active backend -> backend
  | Uninitialized ->
      let _ = Atomic.compare_and_set backend_state Uninitialized (Active Jsonl) in
      Log.Task.info "JSONL backend initialized (using Workspace.* functions).";
      Jsonl

(** {1 Dispatch Functions} *)

(** Add a new task.
    Delegates to Workspace.add_task. *)
let add_task config ~title ~priority ~description =
  match backend () with
  | Jsonl ->
      (* RFC-0034.v2: pass per-goal cap guard. The current dispatch path
         does not carry [goal_id], so the guard is a no-op (orphan tasks
         bypass the cap). Wired now so future [goal_id]-aware callers
         (or a backend rewrite) inherit the same invariant for free. *)
      Ok
        (Workspace.add_task
           ~reject_if:(Workspace_task_capacity.rejection_for_add_task ?goal_id:None)
           config ~title ~priority ~description)

(** Get a task by ID *)
let get_task config ~task_id =
  match backend () with
  | Jsonl ->
      let backlog = Workspace.read_backlog config in
      Ok (List.find_opt (fun (t : task) -> t.id = task_id) backlog.tasks)

(** List tasks *)
let list_tasks config ?(include_done=false) ?(include_cancelled=false) () =
  match backend () with
  | Jsonl ->
      let backlog = Workspace.read_backlog config in
      let tasks = List.filter (fun (t : task) ->
        let dominated = match t.task_status with
          | Done _ -> not include_done
          | Cancelled _ -> not include_cancelled
          | Todo | Claimed _ | InProgress _ | AwaitingVerification _ | OperatorBlocked _ -> false
        in
        not dominated
      ) backlog.tasks in
      Ok tasks

let backlog_lock_path config =
  Filename.concat (Workspace.tasks_dir config) ".backlog"

let with_locked_backlog
    config
    (f : backlog -> ('a, Masc_error.t) result)
    : ('a, Masc_error.t) result =
  Workspace.with_file_lock config (backlog_lock_path config) (fun () ->
    match Workspace.read_backlog_r config with
    | Error msg -> Error (System (System_error.IoError msg))
    | Ok backlog -> f backlog)

(* update_status / validate_transition were retired by RFC-0323 G-7: the
   direct status writer bypassed the workspace FSM (Workspace.transition_task_r)
   — its private terminal-pair check enforced none of the FSM's ownership,
   RFC-0308 done-guard, or #23719 evidence rules — and had zero production
   callers. Status changes go through the FSM; there is no side door. *)

(** Delete a task.  Also clears any agent [current_task] cache that still
    points to the deleted task id, so the backlog write and cache
    invalidation happen in the same locked transaction. *)
let delete_task config ~task_id =
  match backend () with
  | Jsonl ->
      with_locked_backlog config (fun backlog ->
        let task_opt =
          List.find_opt (fun (t : task) -> t.id = task_id) backlog.tasks
        in
        let new_tasks =
          List.filter (fun (t : task) -> t.id <> task_id) backlog.tasks
        in
        let new_backlog =
          {
            tasks = new_tasks;
            last_updated = now_iso ();
            version = backlog.version + 1;
          }
        in
        let status_for_clear =
          match task_opt with
          | Some t -> t.task_status
          | None -> Masc_domain.Todo
        in
        let clear_stale () =
          Task_cache_invariant.clear_stale_agent_task_for_task
            config
            ~task_id
            ~status:status_for_clear
            ~module_name:"task_dispatch.delete_task"
        in
        Workspace.write_backlog ~after_commit:clear_stale config new_backlog;
        Ok ())
