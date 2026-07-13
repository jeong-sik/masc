(** Typed envelope for a single tool invocation inside a {!Tool_batch}.

    A [Tool_job.t] is the unit of scheduling, locking, evidence, and replay.
    It carries everything the orchestrator needs to decide whether a tool can
    run in parallel, which resource it touches, whether it is idempotent, and
    how its result maps back to a turn/goal/keeper. *)

(** {1 Job envelope} *)

type t = {
  job_id : string;
  batch_id : string;
  turn_id : string option [@default None];
  goal_id : string option [@default None];
  keeper_id : string option [@default None];
  tool_name : string;
  tool_version : string option [@default None];
  schema_hash : string;
  input_json : Yojson.Safe.t;
  read_only : bool;
  resource_keys : string list;
  idempotency_key : string option [@default None];
  deadline_ms : int option [@default None];
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
    - [resource_keys] uses the explicit list if provided; otherwise read-only
      tools get no lock key and writer/unknown tools get a coarse ["write:any"]
      key so they serialize until a caller supplies typed resource keys.
    - [job_id] defaults to a fresh UUIDv4. Pass an explicit id in tests. *)

(** {1 Schema hashing} *)

val normalize_input_for_hash : Yojson.Safe.t -> Yojson.Safe.t
(** Recursively sort object keys so that equivalent schemas produce the same
    hash regardless of key order. Lists are kept in order. *)

val schema_hash_of_yojson : Yojson.Safe.t -> string
(** Deterministic SHA-256 hash (hex) of a normalized JSON value. *)

(** {1 Resource key inference} *)

val default_resource_keys_of_tool :
  read_only:bool -> tool_name:string -> input_json:Yojson.Safe.t -> string list
(** Conservative default resource key selection.

    This function deliberately does not infer resource keys from tool-name
    strings. Read-only tools return [[]]. Writer or unknown tools return the
    coarse ["write:any"] key, forcing serialization until the planner or
    executor supplies typed resource keys from a real tool contract. *)

(** {1 Field updates} *)

val with_attempt : t -> int -> t
