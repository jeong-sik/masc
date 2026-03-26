(** Task_dispatch - Runtime backend selection for MASC Tasks

    Routes Task operations to either JSONL (Room.* functions) or PostgreSQL (Task_pg.t).
    Backend is selected once at server startup based on MASC_POSTGRES_URL env var.

    @since 0.7.0
*)

open Types

(** Backend variant *)
type task_backend =
  | Jsonl
  | Postgres of Task_pg.t

type backend_state =
  | Uninitialized
  | Active of task_backend

(** Current backend state. Single ref avoids contradictory initialized/backend pairs. *)
let backend_state : backend_state ref = ref Uninitialized

let task_mu = Eio.Mutex.create ()
let with_task_rw f = Eio_guard.with_mutex task_mu f
let with_task_ro f = Eio_guard.with_mutex_ro task_mu f

let is_initialized () =
  with_task_ro (fun () ->
    match !backend_state with
    | Active _ -> true
    | Uninitialized -> false)

(** Initialize PostgreSQL backend if URL is available *)
let init_pg pool =
  with_task_rw (fun () ->
    if match !backend_state with Active _ -> true | Uninitialized -> false then begin
      Log.Task.warn "WARNING: already initialized, ignoring init_pg";
      Ok ()
    end else
    match Task_pg.create pool with
    | Ok t ->
        backend_state := Active (Postgres t);
        Log.Task.info "PostgreSQL backend initialized.";
        Ok ()
    | Error e ->
        Log.Task.error "PG init failed, falling back to JSONL: %s"
          (show_masc_error e);
        Error e)

(** Initialize JSONL backend. Default fallback. *)
let init_jsonl () =
  with_task_rw (fun () ->
    if match !backend_state with Active _ -> true | Uninitialized -> false then
      Log.Task.warn "WARNING: already initialized, ignoring init_jsonl"
    else begin
      backend_state := Active Jsonl;
      Log.Task.info "JSONL backend initialized (using Room.* functions)."
    end)

(** Reset for testing *)
let reset_for_test () =
  with_task_rw (fun () -> backend_state := Uninitialized)

(** Get current backend, auto-init JSONL if not set *)
let backend () =
  with_task_rw (fun () ->
    match !backend_state with
    | Active backend -> backend
    | Uninitialized ->
        backend_state := Active Jsonl;
        Log.Task.info "JSONL backend initialized (using Room.* functions).";
        (match !backend_state with
         | Active backend -> backend
         | Uninitialized -> Jsonl))

(** Check if PostgreSQL backend is active *)
let is_postgres () =
  match backend () with
  | Postgres _ -> true
  | Jsonl -> false

(** Get PostgreSQL pool if available *)
let get_pg_pool () =
  with_task_ro (fun () ->
    match !backend_state with
    | Active (Postgres t) -> Some (Task_pg.get_pool t)
    | _ -> None)

(** {1 Dispatch Functions} *)

(** Add a new task.
    In JSONL mode, delegates to Room.add_task.
    In PG mode, inserts directly to database. *)
let add_task config ~title ~priority ~description =
  match backend () with
  | Jsonl ->
      (* Use existing Room.add_task *)
      Ok (Room.add_task config ~title ~priority ~description)
  | Postgres t ->
      let backlog = Room.read_backlog config in
      let task_id = Printf.sprintf "task-%03d" (Room.next_task_number config backlog) in
      let created_at = now_iso () in
      match Task_pg.add_task t ~id:task_id ~title ~description ~priority ~created_at () with
      | Ok _ ->
          let _ = Room.broadcast config ~from_agent:"system"
            ~content:(Printf.sprintf "📋 New quest: %s" title) in
          Ok (Printf.sprintf "✅ Added %s: %s (PG)" task_id title)
      | Error e -> Error e

(** Get a task by ID *)
let get_task config ~task_id =
  match backend () with
  | Jsonl ->
      let backlog = Room.read_backlog config in
      Ok (List.find_opt (fun (t : task) -> t.id = task_id) backlog.tasks)
  | Postgres t ->
      Task_pg.get_task t ~id:task_id

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
  | Postgres t ->
      Task_pg.list_tasks t ~include_done ~include_cancelled

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
  | Postgres t ->
      Task_pg.update_task_status t ~id:task_id ~status

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
  | Postgres t ->
      Task_pg.delete_task t ~id:task_id

(** Migrate all tasks from JSONL to PostgreSQL *)
let migrate_to_pg config =
  match backend () with
  | Jsonl -> Error (IoError "Not in PostgreSQL mode")
  | Postgres t ->
      let backlog = Room.read_backlog config in
      Task_pg.migrate_from_backlog t backlog
