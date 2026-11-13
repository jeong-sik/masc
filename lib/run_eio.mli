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

type error =
  | Missing_run of { task_id : string; path : string }
  | Invalid_run of { task_id : string; path : string }
  | Storage_failure of string

val error_to_string : error -> string

(** {1 JSON serde}

    [_to_json] always succeeds; [_of_json] returns [None] on missing
    required fields (logs via [Log.Misc.error]). *)

val run_record_to_json : run_record -> Yojson.Safe.t

(** What {!list} found: [total] is every run there is, [shown] the most
    recently updated ones, newest first. *)
type run_listing = {
  total : int;
  shown : run_record list;
}

(** [{"count": total, "shown": n, "runs": [...]}]. A row is the record without
    its plan text: [task_id], [agent_name] (string or null), [plan_bytes] (the
    plan's length, 0 when none was written), [created_at], [updated_at]. *)
val run_listing_to_json : run_listing -> Yojson.Safe.t

val run_record_of_json : Yojson.Safe.t -> run_record option

(** {1 Path builders} *)

val run_json_path : Workspace_utils.config -> string -> string

(** {1 Run lifecycle}

    [init], [update_plan] and the creation inside [get] write [run.json]
    under one per-[run.json] file lock, so concurrent fibers do not lose
    one another's writes. *)

val write_run : Workspace_utils.config -> run_record -> (unit, error) result
(** An authoritative metadata write failure is returned to the caller.
    A committed Memory backend value remains successful if only its local
    filesystem mirror fails; that mirror failure is logged separately. *)

val read_run :
  Workspace_utils.config -> string -> (run_record, error) result

(** [init config ~task_id ~agent_name] creates the run directory,
    a default [plan.md], and writes an initial [run.json]. *)
val init :
  Workspace_utils.config ->
  task_id:string ->
  agent_name:string option ->
  (run_record, string) result

(** File-locked read-modify-write on [run.json]. [Missing_run] requires
    initializing the run first; it does not create a record or plan. *)
val update_plan :
  Workspace_utils.config ->
  task_id:string ->
  content:string ->
  (run_record, error) result

(** {1 Queries} *)

(** Bundle {!run_record} + plan text into a single JSON object.
    Creates the run scaffold first when [run.json] is missing. *)
val get :
  ?agent_name:string ->
  Workspace_utils.config ->
  task_id:string ->
  (Yojson.Safe.t, string) result

(** The [limit] most recently updated runs under {!runs_dir}, newest first,
    and how many runs there are. A run whose [updated_at] does not parse comes
    after every one that does. [limit] below 1 shows none. *)
val list : Workspace_utils.config -> limit:int -> run_listing

val runs_dirname : string
(** The directory runs sit in below [<base>/.masc]. *)
