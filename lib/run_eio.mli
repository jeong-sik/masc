(** Execution Memory (Run) — track task runs in [.masc/runs/{task_id}].

    Pure synchronous filesystem operations. Per task, the following
    files live under the run directory:

    - [run.json]       — metadata ({!run_record} serialised)
    - [plan.md]        — planning document *)

(** {1 Types} *)

type run_record = {
  task_id : string;
  agent_name : string option;
  plan : string;
  created_at : string;
  updated_at : string;
}

(** {1 JSON serde}

    [_to_json] always succeeds; [_of_json] returns [None] on missing
    required fields (logs via [Log.Misc.error]). *)

val run_record_to_json : run_record -> Yojson.Safe.t

val run_record_of_json : Yojson.Safe.t -> run_record option

(** {1 Path builders} *)

val runs_dir : Workspace_utils.config -> string

val run_dir : Workspace_utils.config -> string -> string

val run_json_path : Workspace_utils.config -> string -> string

val plan_path : Workspace_utils.config -> string -> string

(** Create {!run_dir} and parents if missing. *)
val ensure_run_dir : Workspace_utils.config -> string -> unit

(** [""] when the file does not exist. *)
val read_text_file : string -> string

(** Creates parent directories as needed. *)
val write_text_file : string -> string -> unit

(** {1 Run lifecycle}

    [init] / [update_plan] implement read-modify-write safety via
    per-[run.json] file locks to prevent lost updates across
    concurrent fibers. *)

val write_run_result :
  Workspace_utils.config -> run_record -> (unit, string) result

val write_run : Workspace_utils.config -> run_record -> unit

val read_run : Workspace_utils.config -> string -> (run_record, string) result

(** [init config ~task_id ~agent_name] creates the run directory,
    a default [plan.md], and writes an initial [run.json]. *)
val init :
  Workspace_utils.config ->
  task_id:string ->
  agent_name:string option ->
  (run_record, string) result

(** File-locked read-modify-write on [run.json]. *)
val update_plan :
  Workspace_utils.config ->
  task_id:string ->
  content:string ->
  (run_record, string) result

(** {1 Queries} *)

(** Bundle {!run_record} + plan text into a single JSON object.
    Creates the run scaffold first when [run.json] is missing. *)
val get :
  ?agent_name:string ->
  Workspace_utils.config ->
  task_id:string ->
  (Yojson.Safe.t, string) result

(** List all runs under {!runs_dir} as
    [{"count": N, "runs": [...]}]. *)
val list : Workspace_utils.config -> Yojson.Safe.t
