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

(** Current backend. Set once at server startup. *)
let current_backend : task_backend option ref = ref None
let initialized = ref false

(** Initialize PostgreSQL backend if URL is available *)
let init_pg pool =
  if !initialized then begin
    Printf.eprintf "[Task_dispatch] WARNING: already initialized, ignoring init_pg\n%!";
    Ok ()
  end else
  match Task_pg.create pool with
  | Ok t ->
      current_backend := Some (Postgres t);
      initialized := true;
      Printf.eprintf "[Task_dispatch] PostgreSQL backend initialized.\n%!";
      Ok ()
  | Error e ->
      Printf.eprintf "[Task_dispatch] PG init failed, falling back to JSONL: %s\n%!"
        (show_masc_error e);
      Error e

(** Initialize JSONL backend. Default fallback. *)
let init_jsonl () =
  if !initialized then
    Printf.eprintf "[Task_dispatch] WARNING: already initialized, ignoring init_jsonl\n%!"
  else begin
    current_backend := Some Jsonl;
    initialized := true;
    Printf.eprintf "[Task_dispatch] JSONL backend initialized (using Room.* functions).\n%!"
  end

(** Reset for testing *)
let reset_for_test () =
  current_backend := None;
  initialized := false

(** Get current backend, auto-init JSONL if not set *)
let backend () =
  match !current_backend with
  | Some b -> b
  | None ->
      init_jsonl ();
      Jsonl  (* Always succeeds *)

(** Check if PostgreSQL backend is active *)
let is_postgres () =
  match backend () with
  | Postgres _ -> true
  | Jsonl -> false

(** Get PostgreSQL pool if available *)
let get_pg_pool () =
  match !current_backend with
  | Some (Postgres t) -> Some (Task_pg.get_pool t)
  | _ -> None

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

(** Update task status (claim, start, complete, cancel) *)
let update_status config ~task_id ~status =
  match backend () with
  | Jsonl ->
      (* This delegates to Room functions via status type *)
      let backlog = Room.read_backlog config in
      let updated_tasks = List.map (fun (t : task) ->
        if t.id = task_id then { t with task_status = status } else t
      ) backlog.tasks in
      let new_backlog = {
        tasks = updated_tasks;
        last_updated = now_iso ();
        version = backlog.version + 1;
      } in
      Room.write_backlog config new_backlog;
      Ok ()
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
