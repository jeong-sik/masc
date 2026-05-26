(** Core execution body for keeper tool OAS handler. *)

(** Execute a keeper tool call with full observability: telemetry,
    failure classification, retry-state management, and exception
    handling.  Called from [Keeper_tools_oas_handler] after validation,
    circuit-breaking, and workflow-rejection checks have passed.

    All parameters that were previously captured from the outer
    [make_keeper_tool_handler] closure are passed explicitly. *)
val execute_with_observers
  :  name:string
  -> config:Coord.config
  -> meta:Keeper_types.keeper_meta
  -> ctx_snapshot:Keeper_types.working_context
  -> ?turn_sandbox_factory:Keeper_sandbox_factory.t
  -> ?turn_sandbox_factory_git:Keeper_sandbox_factory.t
  -> exec_cache:Masc_exec.Exec_cache.t option
  -> ?search_fn:(query:string -> max_results:int -> Yojson.Safe.t)
  -> ?on_tool_called:(string -> unit)
  -> failure_counts:Keeper_tools_oas.failure_counts
  -> key:string
  -> input:Yojson.Safe.t
  -> unit
  -> Tool_result.result
