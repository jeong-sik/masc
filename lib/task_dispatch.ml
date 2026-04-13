(** Task_dispatch - Runtime backend selection for MASC Tasks

    Uses JSONL (Room.* functions) only.

    @since 0.7.0
*)

open Types

(** Backend variant *)
type task_backend =
  | Jsonl

type backend_state =
  | Uninitialized
  | Active of task_backend

(** Current backend state. Single ref avoids contradictory initialized/backend pairs. *)
let backend_state : backend_state ref = ref Uninitialized

let is_initialized () =
  match !backend_state with
  | Active _ -> true
  | Uninitialized -> false

(** Initialize JSONL backend. Default fallback. *)
let init_jsonl () =
  if match !backend_state with Active _ -> true | Uninitialized -> false then
    Log.Task.warn "WARNING: already initialized, ignoring init_jsonl"
  else begin
    backend_state := Active Jsonl;
    Log.Task.info "JSONL backend initialized (using Room.* functions)."
  end

(** Reset for testing *)
let reset_for_test () =
  backend_state := Uninitialized

(** Get current backend, auto-init JSONL if not set *)
let backend () =
  match !backend_state with
  | Active backend -> backend
  | Uninitialized ->
      backend_state := Active Jsonl;
      Log.Task.info "JSONL backend initialized (using Room.* functions).";
      Jsonl

(** {1 Dispatch Functions} *)

(** Add a new task.
    Delegates to Room.add_task. *)
let add_task config ~title ~priority ~description =
  match backend () with
  | Jsonl ->
      (* Use existing Room.add_task *)
      Ok (Room.add_task config ~title ~priority ~description)

(** Get a task by ID *)
let get_task config ~task_id =
  match backend () with
  | Jsonl ->
      let backlog = Room.read_backlog config in
      Ok (List.find_opt (fun (t : task) -> t.id = task_id) backlog.tasks)

(** List tasks *)
let list_tasks config ?(include_done=false) ?(include_cancelled=false) () =
  match backend () with
  | Jsonl ->
      let backlog = Room.read_backlog config in
      let tasks = List.filter (fun (t : task) ->
        let dominated = match t.task_status with
          | Done _ -> not include_done
          | Cancelled _ -> not include_cancelled
          | _ -> false
        in
        not dominated
      ) backlog.tasks in
      Ok tasks

(** Validate that a state transition is allowed.
    Terminal states (Done, Cancelled) cannot transition to each other. *)
let validate_transition ~(current : task_status) ~(next : task_status) ~task_id =
  match current, next with
  | Done _, Done _ | Done _, Cancelled _ | Cancelled _, Done _ | Cancelled _, Cancelled _ ->
      Error (TaskInvalidState
        (Printf.sprintf "task %s: cannot transition from %s to %s"
           task_id (task_status_to_string current) (task_status_to_string next)))
  | _ -> Ok ()

(** Update task status (claim, start, complete, cancel) *)
let update_status config ~task_id ~status =
  match backend () with
  | Jsonl ->
      let backlog = Room.read_backlog config in
      let task_opt = List.find_opt (fun (t : task) -> t.id = task_id) backlog.tasks in
      (match task_opt with
       | None -> Error (TaskNotFound task_id)
       | Some t ->
          match validate_transition ~current:t.task_status ~next:status ~task_id with
          | Error e -> Error e
          | Ok () ->
            let updated_tasks = List.map (fun (t : task) ->
              if t.id = task_id then { t with task_status = status } else t
            ) backlog.tasks in
            let new_backlog = {
              tasks = updated_tasks;
              last_updated = now_iso ();
              version = backlog.version + 1;
            } in
            Room.write_backlog config new_backlog;
            Ok ())

(** Delete a task *)
let delete_task config ~task_id =
  match backend () with
  | Jsonl ->
      let backlog = Room.read_backlog config in
      let new_tasks = List.filter (fun (t : task) -> t.id <> task_id) backlog.tasks in
      let new_backlog = {
        tasks = new_tasks;
        last_updated = now_iso ();
        version = backlog.version + 1;
      } in
      Room.write_backlog config new_backlog;
      Ok ()

