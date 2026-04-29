(** Worker_container_runners — OAS-backed and legacy-backed worker
    spawn entry points.

    Re-exported by {!Worker_runtime} (the public facade) which
    does \[include module type of Worker_container_runners\] in its
    .mli.  Callers reach the run helpers + lookup utilities
    through {!Worker_runtime}.

    {b Cascade chain}: starts with [include Worker_container],
    transitively bringing the {!Worker_container} +
    {!Worker_container_types} surfaces into scope (notably
    [list_masc_tools], [parse_text_tool_calls], [run_result]).

    Internal: 7 helpers stay private — \[resolve_net\],
    \[default_shell_tool_names\], \[build_execution_spec\],
    \[workspace_path_of_spec\], \[effective_model_of_resume\],
    \[dedupe_tools_by_name\], \[create_raw_trace\].  All consumed
    inside the run / preflight pipelines. *)

include module type of struct
  include Worker_container
end

(** {1 OAS-backed run} *)

val run_worker_oas :
  sw:Eio.Switch.t ->
  ?net:Eio_context.eio_net ->
  room_config:Coord.config option ->
  Worker_execution_spec.t ->
  unit ->
  (run_result, string) result
(** [run_worker_oas ~sw ?net ~room_config spec] returns a thunk
    that runs (or resumes) the worker via OAS:

    - Resolve net (from [?net] or {!Eio_context}).
    - Resolve effective model from
      {!Worker_container.load_worker_meta} when checkpoint
      exists, otherwise from the spec.
    - Build MASC + shell tool sets and dedupe by tool name.
    - Create / open raw trace under
      [<base_path>/workers/<worker_name>/raw_trace.jsonl].
    - Dispatch to {!Worker_oas.run_worker_via_oas} (cold start)
      or {!Worker_oas.resume_worker_via_oas} (when checkpoint
      present).

    Returns a thunk so callers can defer the run inside their
    own switch / fiber. *)

(** {1 Preflight (Docker batches)} *)

val preflight_spawn_batch :
  ?clock_opt:_ ->
  Worker_execution_spec.t list ->
  (unit, string) result
(** [preflight_spawn_batch ?clock_opt specs] runs the per-batch
    Docker preflight check ({!Worker_runtime_docker.preflight_batch})
    when {!Worker_runtime_config.backend} is [Docker]; returns
    [Ok ()] immediately for [Local_playground].  Operator calls
    once before spawning all workers in the batch — errors
    short-circuit the whole batch.  See cycle 143
    ({!Worker_runtime_docker}) for the Docker-side details. *)

(** {1 Backend-dispatching run} *)

val run_worker :
  sw:Eio.Switch.t ->
  ?net:Eio_context.eio_net ->
  runtime_backend:Worker_execution_backend.t ->
  base_path:string ->
  worker_name:string ->
  model_label:string ->
  room_config:Coord.config option ->
  ?working_dir:string ->
  ?thinking_enabled:bool ->
  ?worker_run_id:string ->
  role:string option ->
  selection_note:string option ->
  prompt:string ->
  timeout_sec:int ->
  unit ->
  (run_result, string) result
(** [run_worker ~sw ?net ~runtime_backend ~base_path ~worker_name
      ~model_label ~room_config ?working_dir ?thinking_enabled
      ?worker_run_id ~role ~selection_note ~prompt ~timeout_sec]
    builds a {!Worker_execution_spec.t} from the explicit args
    and dispatches by [runtime_backend]:

    - [Local_playground] -> {!run_worker_oas} with the spec.
    - [Docker] -> rewrite spec for container via
      {!Worker_runtime_docker.rewrite_spec_for_container}, then
      {!Worker_runtime_docker.run_worker_spec}.

    Returns the same thunk shape as {!run_worker_oas}.  Pinned
    at the contract seam: adding a new backend variant requires
    extending this match. *)
