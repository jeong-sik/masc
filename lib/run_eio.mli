(** Execution Memory (Run) — track task runs in [.masc/runs/{task_id}].

    Pure synchronous filesystem operations. Per task, the following
    files live under the run directory:

    - [run.json]       — metadata ({!run_record} serialised)
    - [plan.md]        — planning document
    - [deliverable.md] — task output
    - [log.jsonl]      — append-only event log ({!log_entry}) *)

(** {1 Types} *)

type run_record = {
  task_id : string;
  agent_name : string option;
  plan : string;
  deliverable : string;
  created_at : string;
  updated_at : string;
}

type log_entry = {
  timestamp : string;
  note : string;
}

(** {1 JSON serde}

    [_to_json] always succeeds; [_of_json] returns [None] on missing
    required fields (logs via [Log.Misc.error]). *)

val run_record_to_json : run_record -> Yojson.Safe.t

val run_record_of_json : Yojson.Safe.t -> run_record option

val log_entry_to_json : log_entry -> Yojson.Safe.t

val log_entry_of_json : Yojson.Safe.t -> log_entry option

(** {1 Path builders} *)

val runs_dir : Coord_utils.config -> string

val run_dir : Coord_utils.config -> string -> string

val run_json_path : Coord_utils.config -> string -> string

val plan_path : Coord_utils.config -> string -> string

val deliverable_path : Coord_utils.config -> string -> string

val log_path : Coord_utils.config -> string -> string

(** Create {!run_dir} and parents if missing. *)
val ensure_run_dir : Coord_utils.config -> string -> unit

val now_iso : unit -> string

(** [""] when the file does not exist. *)
val read_text_file : string -> string

(** Creates parent directories as needed. *)
val write_text_file : string -> string -> unit

(** {1 Run lifecycle}

    [init] / [update_plan] / [set_deliverable] / [append_log] implement
    read-modify-write safety via per-[run.json] file locks to prevent
    lost updates across concurrent fibers. *)

val write_run : Coord_utils.config -> run_record -> unit

val read_run :
  Coord_utils.config -> string -> (run_record, string) result

(** [init config ~task_id ~agent_name] creates the run directory,
    default [plan.md] / [deliverable.md] / [log.jsonl], and writes an
    initial [run.json]. *)
val init :
  Coord_utils.config ->
  task_id:string ->
  agent_name:string option ->
  (run_record, string) result

(** File-locked read-modify-write on [run.json]. *)
val update_plan :
  Coord_utils.config ->
  task_id:string ->
  content:string ->
  (run_record, string) result

(** File-locked append to [log.jsonl]. *)
val append_log :
  Coord_utils.config ->
  task_id:string ->
  note:string ->
  (log_entry, string) result

(** File-locked read-modify-write on [run.json]. *)
val set_deliverable :
  Coord_utils.config ->
  task_id:string ->
  content:string ->
  (run_record, string) result

(** {1 Queries} *)

(** [read_logs ?limit ()] returns all log entries when [limit] is
    absent; otherwise the last [limit] entries (tail). *)
val read_logs :
  Coord_utils.config ->
  task_id:string ->
  ?limit:int ->
  unit ->
  log_entry list

(** Bundle {!run_record} + plan text + deliverable text + last 50 logs
    into a single JSON object. *)
val get :
  Coord_utils.config ->
  task_id:string ->
  (Yojson.Safe.t, string) result

(** List all runs under {!runs_dir} as
    [{"count": N, "runs": [...]}]. *)
val list : Coord_utils.config -> Yojson.Safe.t
