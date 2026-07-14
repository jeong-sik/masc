(** Worker_container_runners — OAS-backed and legacy-backed worker
    spawn entry points.

    Re-exported by {!Worker_runtime} (the public facade) which
    does \[include module type of Worker_container_runners\] in its
    .mli.  Callers reach the run helpers + lookup utilities
    through {!Worker_runtime}.

    {b Runtime chain}: starts with [include Worker_container],
    transitively bringing the {!Worker_container} +
    {!Worker_container_types} surfaces into scope (notably
    [list_masc_tools], [parse_text_tool_calls], [run_result]).

    Internal helpers stay private — \[resolve_net\],
    \[build_execution_spec\],
    \[workspace_path_of_spec\], \[dedupe_tools_by_name\],
    \[create_raw_trace\]. All consumed
    inside the run / preflight pipelines. *)

include module type of struct
  include Worker_container
end

(** {1 OAS-backed run} *)

val run_worker_oas :
  sw:Eio.Switch.t ->
  ?net:Eio_context.eio_net ->
  workspace_config:Workspace.config option ->
  Worker_execution_spec.t ->
  unit ->
  (run_result, string) result
(** [run_worker_oas ~sw ?net ~workspace_config spec] returns a thunk
    that runs (or resumes) the worker via OAS:

    - Resolve net (from [?net] or {!Eio_context}).
    - Resolve the exact typed provider config from the explicit spec label.
      A resumed checkpoint must carry the same exact model id.
    - Build the MASC/OAS tool set and dedupe by tool name.
    - Create / open raw trace under
      [<base_path>/workers/<worker_name>/raw_trace.jsonl].
    - Dispatch to {!Worker_oas.run_worker_via_oas} (cold start)
      or {!Worker_oas.resume_worker_via_oas} (when checkpoint
      present).

    Returns a thunk so callers can defer the run inside their
    own switch / fiber. *)
