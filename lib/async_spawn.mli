(** Async_spawn — non-blocking agent execution with job tracking.

    Wraps spawn functions in Eio fibers so callers get a job_id
    immediately and can poll/cancel later.

    @since 2.112.0 *)

(** Job lifecycle status. *)
type job_status =
  | Running
  | Completed of Spawn_eio.spawn_result
  | Failed of string
  | Cancelled

(** Immutable identification + mutable status for a background job. *)
type job = {
  job_id : string;
  agent_name : string;
  prompt_preview : string;
  started_at : float;
  mutable status : job_status;
  mutable finished_at : float option;
}

(** Opaque job registry. Thread-safe under Eio cooperative scheduling. *)
type registry

val create_registry : unit -> registry

(** Submit a background job. [run_fn] executes in a forked Eio fiber.
    Returns the job record immediately with status [Running]. *)
val submit_job :
  registry ->
  sw:Eio.Switch.t ->
  agent_name:string ->
  prompt:string ->
  (unit -> Spawn_eio.spawn_result) ->
  job

val get_job : registry -> string -> job option
val cancel_job : registry -> string -> bool
val list_jobs : registry -> job list

(** Remove finished jobs older than [max_age_s]. Returns count removed. *)
val cleanup_completed : registry -> max_age_s:float -> int

(** Serialize status variant to string. *)
val status_to_string : job_status -> string

(** Serialize a job record to JSON. *)
val job_to_json : job -> Yojson.Safe.t
