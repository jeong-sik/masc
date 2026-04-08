(** Task_pg - PostgreSQL backend for MASC Tasks

    Uses Caqti for database access, sharing the pool from Backend.PostgresNative.
    Auto-creates schema on initialization.

    Task status is stored as a simple string in the database:
    - 'todo', 'claimed', 'in_progress', 'done', 'cancelled'
    Extra status fields (assignee, timestamps, notes) are stored as nullable columns.

    @since 0.7.0
*)

open Types

open Result_syntax

type t = {
  pool: (Caqti_eio.connection, Caqti_error.t) Caqti_eio.Pool.t;
}

(** Get pool for external use *)
let get_pool t = t.pool

(** Convert Caqti errors to masc_error *)
let caqti_err e = IoError (Caqti_error.show e)

(** {1 Schema DDL} *)

open Pg_infix

let create_tasks_table_q =
  (Caqti_type.unit ->. Caqti_type.unit)
  "CREATE TABLE IF NOT EXISTS masc_tasks (\
     id TEXT PRIMARY KEY, \
     title TEXT NOT NULL, \
     description TEXT NOT NULL DEFAULT '', \
     priority INT NOT NULL DEFAULT 3, \
     status TEXT NOT NULL DEFAULT 'todo', \
     assignee TEXT, \
     claimed_at TEXT, \
     started_at TEXT, \
     completed_at TEXT, \
     cancelled_at TEXT, \
     cancelled_by TEXT, \
     notes TEXT, \
     reason TEXT, \
     files TEXT NOT NULL DEFAULT '[]', \
     created_at TEXT NOT NULL, \
     updated_at TEXT NOT NULL, \
     version INT NOT NULL DEFAULT 1, \
     worktree_branch TEXT, \
     worktree_path TEXT, \
     worktree_git_root TEXT, \
     worktree_repo_name TEXT \
   )"

let create_idx_status_q =
  (Caqti_type.unit ->. Caqti_type.unit)
  "CREATE INDEX IF NOT EXISTS idx_tasks_status ON masc_tasks (status)"

let create_idx_priority_q =
  (Caqti_type.unit ->. Caqti_type.unit)
  "CREATE INDEX IF NOT EXISTS idx_tasks_priority ON masc_tasks (priority DESC)"

let create_idx_assignee_q =
  (Caqti_type.unit ->. Caqti_type.unit)
  "CREATE INDEX IF NOT EXISTS idx_tasks_assignee ON masc_tasks (assignee)"

let create_idx_created_q =
  (Caqti_type.unit ->. Caqti_type.unit)
  "CREATE INDEX IF NOT EXISTS idx_tasks_created ON masc_tasks (created_at DESC)"

(** Migration: add required_role column (idempotent via IF NOT EXISTS trick).
    PostgreSQL lacks IF NOT EXISTS for ALTER TABLE ADD COLUMN before v11,
    so we catch the duplicate-column error gracefully. *)
let add_required_role_column_q =
  (Caqti_type.unit ->. Caqti_type.unit)
  "DO $$ BEGIN \
     ALTER TABLE masc_tasks ADD COLUMN required_role TEXT NOT NULL DEFAULT 'unassigned'; \
   EXCEPTION WHEN duplicate_column THEN NULL; \
   END $$"

(** {1 Initialization} *)

let create pool =
  let init_result = Caqti_eio.Pool.use (fun conn ->
    let module C = (val conn : Caqti_eio.CONNECTION) in
    let* () = C.exec create_tasks_table_q () in
    let* () = C.exec create_idx_status_q () in
    let* () = C.exec create_idx_priority_q () in
    let* () = C.exec create_idx_assignee_q () in
    let* () = C.exec create_idx_created_q () in
    let* () = C.exec add_required_role_column_q () in
    Ok ()
  ) pool in
  match init_result with
  | Ok () -> Ok { pool }
  | Error e -> Error (caqti_err e)

(** {1 Task Status Conversion} *)

(** Convert task_status to DB representation *)
let status_to_db (status : task_status) : string * string option * string option * string option * string option * string option * string option * string option =
  match status with
  | Todo -> ("todo", None, None, None, None, None, None, None)
  | Claimed { assignee; claimed_at } ->
      ("claimed", Some assignee, Some claimed_at, None, None, None, None, None)
  | InProgress { assignee; started_at } ->
      ("in_progress", Some assignee, None, Some started_at, None, None, None, None)
  | Done { assignee; completed_at; notes } ->
      ("done", Some assignee, None, None, Some completed_at, None, None, notes)
  | Cancelled { cancelled_by; cancelled_at; reason } ->
      ("cancelled", None, None, None, None, Some cancelled_at, Some cancelled_by, reason)

(** Convert DB representation to task_status *)
let status_of_db ~id ~status ~assignee ~claimed_at ~started_at ~completed_at ~cancelled_at ~cancelled_by ~notes ~reason : task_status =
  match status with
  | "todo" -> Todo
  | "claimed" ->
      Claimed {
        assignee = Option.value assignee ~default:"unknown";
        claimed_at = Option.value claimed_at ~default:"";
      }
  | "in_progress" ->
      InProgress {
        assignee = Option.value assignee ~default:"unknown";
        started_at = Option.value started_at ~default:"";
      }
  | "done" ->
      Done {
        assignee = Option.value assignee ~default:"unknown";
        completed_at = Option.value completed_at ~default:"";
        notes;
      }
  | "cancelled" ->
      Cancelled {
        cancelled_by = Option.value cancelled_by ~default:"system";
        cancelled_at = Option.value cancelled_at ~default:"";
        reason;
      }
  | unknown ->
      Log.Backend.warn "[task_pg] unknown task status %S for task %S in DB, defaulting to Todo" unknown id;
      Todo

(** {1 Queries} *)

(* Row type for task: 13 fields packed as t2(t4(t3,t3,t3,t3), string)
   Core: id, title, description
   Meta: priority, status, assignee
   Timestamps: claimed_at, started_at, completed_at
   Extra: created_at, notes, files
   Role: required_role *)
let task_row_t = Caqti_type.(
  t2
    (t4
      (t3 string string string)                              (* id, title, description *)
      (t3 int string (option string))                        (* priority, status, assignee *)
      (t3 (option string) (option string) (option string))   (* claimed_at, started_at, completed_at *)
      (t3 string (option string) string))                    (* created_at, notes, files *)
    string                                                   (* required_role *)
)

(* Insert type: 11 fields packed as t2(t4(t3, t3, t2, t2), string) *)
let insert_task_t = Caqti_type.(
  t2
    (t4
      (t3 string string string)                              (* id, title, description *)
      (t3 int string (option string))                        (* priority, status, assignee *)
      (t2 (option string) (option string))                   (* claimed_at, started_at *)
      (t2 (option string) string))                           (* completed_at, created_at *)
    string                                                   (* required_role *)
)

let insert_task_q =
  (insert_task_t ->. Caqti_type.unit)
  "INSERT INTO masc_tasks \
   (id, title, description, priority, status, assignee, claimed_at, started_at, \
    completed_at, created_at, updated_at, files, required_role) \
   VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $10, '[]', $11) \
   ON CONFLICT (id) DO UPDATE SET \
     title = EXCLUDED.title, \
     description = EXCLUDED.description, \
     priority = EXCLUDED.priority, \
     status = EXCLUDED.status, \
     assignee = EXCLUDED.assignee, \
     claimed_at = EXCLUDED.claimed_at, \
     started_at = EXCLUDED.started_at, \
     completed_at = EXCLUDED.completed_at, \
     updated_at = EXCLUDED.created_at, \
     required_role = EXCLUDED.required_role, \
     version = masc_tasks.version + 1"

let task_columns =
  "id, title, description, priority, status, assignee, \
   claimed_at, started_at, completed_at, created_at, notes, files, required_role"

let get_task_q =
  (Caqti_type.string ->? task_row_t)
  ("SELECT " ^ task_columns ^ " FROM masc_tasks WHERE id = $1")

let list_tasks_q =
  (Caqti_type.unit ->* task_row_t)
  ("SELECT " ^ task_columns ^ " FROM masc_tasks ORDER BY priority DESC, created_at ASC")

let list_active_tasks_q =
  (Caqti_type.unit ->* task_row_t)
  ("SELECT " ^ task_columns ^ " FROM masc_tasks WHERE status NOT IN ('done', 'cancelled') \
   ORDER BY priority DESC, created_at ASC")

let delete_task_q =
  (Caqti_type.string ->. Caqti_type.unit)
  "DELETE FROM masc_tasks WHERE id = $1"

(* Update status query: t3(t2, t2, t2) for 6 params *)
let update_status_t = Caqti_type.(
  t3
    (t2 string (option string))      (* status, assignee *)
    (t2 (option string) (option string))  (* claimed_at, started_at *)
    (t2 (option string) string)      (* completed_at, id *)
)

let update_status_q =
  (update_status_t ->. Caqti_type.unit)
  "UPDATE masc_tasks SET \
     status = $1, assignee = $2, claimed_at = $3, started_at = $4, \
     completed_at = $5, updated_at = CURRENT_TIMESTAMP, version = version + 1 \
   WHERE id = $6"

(** {1 Operations} *)

(** Convert nested tuple row to task *)
let row_to_task (((id, title, description), (priority, status, assignee),
                 (claimed_at, started_at, completed_at), (created_at, notes, files_json)),
                 required_role_str) : task =
  let files = try
    match Yojson.Safe.from_string files_json with
    | `List items -> List.filter_map Yojson.Safe.Util.to_string_option items
    | _ -> []
  with Eio.Cancel.Cancelled _ as e -> raise e | exn ->
    Log.Misc.warn "task_pg: files JSON parse failed: %s" (Printexc.to_string exn);
    [] in
  let required_role = Types_core.role_of_string required_role_str in
  {
    id; title; description; priority; files; created_at;
    worktree = None;  (* Worktree loaded separately if needed *)
    required_role;
    required_preset = None;
    stage = None;
    contract = None;
    handoff_context = None;
    task_status = status_of_db ~id ~status ~assignee ~claimed_at ~started_at
                    ~completed_at ~cancelled_at:None ~cancelled_by:None ~notes ~reason:None;
  }

let add_task t ~id ~title ~description ~priority ~created_at
    ?(required_role = Types_core.Unassigned) () =
  let status_str, assignee, claimed_at, started_at, completed_at, _, _, _ =
    status_to_db Todo in
  let required_role_str = Types_core.role_to_string required_role in
  let params = (
    ((id, title, description),
     (priority, status_str, assignee),
     (claimed_at, started_at),
     (completed_at, created_at)),
    required_role_str
  ) in
  let result = Caqti_eio.Pool.use (fun conn ->
    let module C = (val conn : Caqti_eio.CONNECTION) in
    C.exec insert_task_q params
  ) t.pool in
  match result with
  | Ok () -> Ok id
  | Error e -> Error (caqti_err e)

let get_task t ~id =
  let result = Caqti_eio.Pool.use (fun conn ->
    let module C = (val conn : Caqti_eio.CONNECTION) in
    C.find_opt get_task_q id
  ) t.pool in
  match result with
  | Ok (Some row) -> Ok (Some (row_to_task row))
  | Ok None -> Ok None
  | Error e -> Error (caqti_err e)

let list_tasks t ~include_done ~include_cancelled =
  let query = if include_done && include_cancelled then list_tasks_q else list_active_tasks_q in
  let result = Caqti_eio.Pool.use (fun conn ->
    let module C = (val conn : Caqti_eio.CONNECTION) in
    C.collect_list query ()
  ) t.pool in
  match result with
  | Ok rows -> Ok (List.map row_to_task rows)
  | Error e -> Error (caqti_err e)

let update_task_status t ~id ~status =
  let status_str, assignee, claimed_at, started_at, completed_at, _, _, _ =
    status_to_db status in
  let params = (
    (status_str, assignee),
    (claimed_at, started_at),
    (completed_at, id)
  ) in
  let result = Caqti_eio.Pool.use (fun conn ->
    let module C = (val conn : Caqti_eio.CONNECTION) in
    C.exec update_status_q params
  ) t.pool in
  match result with
  | Ok () -> Ok ()
  | Error e -> Error (caqti_err e)

let delete_task t ~id =
  let result = Caqti_eio.Pool.use (fun conn ->
    let module C = (val conn : Caqti_eio.CONNECTION) in
    C.exec delete_task_q id
  ) t.pool in
  match result with
  | Ok () -> Ok ()
  | Error e -> Error (caqti_err e)

(** {1 Migration from JSONL} *)

let migrate_from_backlog t (backlog : backlog) =
  let results = List.map (fun (task : task) ->
    let status_str, assignee, claimed_at, started_at, completed_at, _, _, _ =
      status_to_db task.task_status in
    let required_role_str = Types_core.role_to_string task.required_role in
    let params = (
      ((task.id, task.title, task.description),
       (task.priority, status_str, assignee),
       (claimed_at, started_at),
       (completed_at, task.created_at)),
      required_role_str
    ) in
    let result = Caqti_eio.Pool.use (fun conn ->
      let module C = (val conn : Caqti_eio.CONNECTION) in
      C.exec insert_task_q params
    ) t.pool in
    match result with
    | Ok () -> Ok task.id
    | Error e -> Error (caqti_err e)
  ) backlog.tasks in
  let successes = List.filter_map (function Ok id -> Some id | Error _ -> None) results in
  let failures = List.filter_map (function Error e -> Some e | Ok _ -> None) results in
  if failures = [] then
    Ok (Printf.sprintf "Migrated %d tasks" (List.length successes))
  else
    Error (IoError (Printf.sprintf "Migrated %d tasks, %d failures" (List.length successes) (List.length failures)))
