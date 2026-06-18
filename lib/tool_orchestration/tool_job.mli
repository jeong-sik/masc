(** Typed envelope for a single tool invocation inside a {!Tool_batch}.

    A [Tool_job.t] is the unit of scheduling, locking, evidence, and replay.
    It carries everything the orchestrator needs to decide whether a tool can
    run in parallel, which resource it touches, whether it is idempotent, and
    how its result maps back to a turn/goal/keeper. *)

(** {1 Policy verdict} *)

type policy_verdict =
  | Approved
  | Pending of string
  | Denied of string
[@@deriving yojson, show, eq]

(** {1 Job envelope} *)

type t = {
  job_id : string;
  batch_id : string;
  turn_id : string option;
  goal_id : string option;
  keeper_id : string option;
  tool_name : string;
  tool_version : string option;
  schema_hash : string;
  input_json : Yojson.Safe.t;
  read_only : bool;
  resource_keys : string list;
  idempotency_key : string option;
  deadline_ms : int option;
  approval : policy_verdict;
  attempt : int;
}
[@@deriving yojson, show]

(** {1 Constructors} *)

val make :
  ?job_id:string ->
  ?turn_id:string ->
  ?goal_id:string ->
  ?keeper_id:string ->
  ?tool_version:string ->
  ?idempotency_key:string ->
  ?deadline_ms:int ->
  ?approval:policy_verdict ->
  ?attempt:int ->
  ?resource_keys:string list ->
  batch_id:string ->
  tool_name:string ->
  input_json:Yojson.Safe.t ->
  unit ->
  t
(** Build a job envelope.

    - [schema_hash] is computed from the currently registered input schema for
      [tool_name], or from a minimal empty object schema when the tool has no
      registered schema.
    - [read_only] is derived from {!Tool_catalog} metadata when available.
    - [resource_keys] uses the explicit list if provided; otherwise falls back
      to {!default_resource_keys_of_tool}.
    - [job_id] defaults to a fresh UUIDv4. Pass an explicit id in tests. *)

(** {1 Schema hashing} *)

val normalize_input_for_hash : Yojson.Safe.t -> Yojson.Safe.t
(** Recursively sort object keys so that equivalent schemas produce the same
    hash regardless of key order. Lists are kept in order. *)

val schema_hash_of_yojson : Yojson.Safe.t -> string
(** Deterministic SHA-256 hash (hex) of a normalized JSON value. *)

(** {1 Resource key inference} *)

val default_resource_keys_of_tool :
  tool_name:string -> input_json:Yojson.Safe.t -> string list
(** Best-effort resource key inference from known tool naming patterns.

    The returned keys are intentionally conservative: a tool that does not
    match a known pattern yields an empty list, forcing the caller (planner or
    executor) to supply explicit [resource_keys]. This avoids pretending a
    write is read-only or locking the wrong resource.

    Examples:
    - [masc_goal_*] with [goal_id] -> ["goal:<id>"]
    - [masc_task_*] with [task_id] -> ["task:<id>"]
    - [tool_read_file]/[tool_edit_file]/[tool_write_file] with [path] -> ["file:<path>"]
    - [tool_search_files] with [path] -> ["repo:<path>"] *)

(** {1 Field updates} *)

val with_approval : t -> policy_verdict -> t
val with_attempt : t -> int -> t
