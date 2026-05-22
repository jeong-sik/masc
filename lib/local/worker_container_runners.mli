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
