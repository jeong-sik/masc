(** Keeper_tools_oas_handler — Tool handler factory for Agent.run().

    Skeleton module: validation, circuit-breaking, workflow-rejection
    gating, and resource-gate wrapping.  The heavy execution body lives
    in [Keeper_tools_oas_handler_exec]; telemetry helpers live in
    [Keeper_tools_oas_handler_telemetry].  Bundle assembly lives in
    [Keeper_tools_oas_bundle].

    @since P1 extraction *)

(** Build the per-tool handler closure used by both internal and
    alias tool entries. The closure dispatches via
    [execute_keeper_tool_call_with_outcome] using [~name] as the
    INTERNAL tool name (telemetry SSOT). [~input_schema] is the
    internal tool schema used for pre-execution validation after
    [?translate_input] reshapes incoming JSON from a public alias
    schema to the internal payload (identity by default). *)
val make_keeper_tool_handler
  :  name:string
  -> input_schema:Yojson.Safe.t
  -> config:Coord.config
  -> meta:Keeper_types.keeper_meta
  -> ctx_snapshot:Keeper_types.working_context
  -> ?turn_sandbox_factory:Keeper_sandbox_factory.t
  -> ?turn_sandbox_factory_git:Keeper_sandbox_factory.t
  -> exec_cache:Masc_exec.Exec_cache.t option
  -> ?search_fn:(query:string -> max_results:int -> Yojson.Safe.t)
  -> ?on_tool_called:(string -> unit)
  -> ?clock:float Eio.Time.clock_ty Eio.Resource.t
  -> ?translate_input:(Yojson.Safe.t -> Yojson.Safe.t)
  -> failure_counts:Keeper_tools_oas.failure_counts
  -> unit
  -> Yojson.Safe.t
  -> Tool_result.result
