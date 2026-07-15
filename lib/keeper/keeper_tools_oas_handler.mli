(** Keeper_tools_oas_handler — Tool handler factory for Agent.run().

    Skeleton module: validation and dispatch. The heavy execution body lives
    in [Keeper_tools_oas_handler_exec]; telemetry helpers live in
    [Keeper_tools_oas_handler_telemetry].  Bundle assembly lives in
    [Keeper_tools_oas_bundle].

    @since P1 extraction *)

(** Build the per-tool handler closure used by both internal and
    alias tool entries. The closure dispatches via
    [execute_keeper_tool_call_with_outcome] using [~name] as the
    INTERNAL tool name (telemetry SSOT). [~input_schema] is the
    internal tool schema used for pre-execution validation. Alias callers may
    pass [?pre_validate_input] to validate the raw public payload before
    [?translate_input] reshapes it to the internal payload (identity by
    default). When [?validate_translated_input] is [false], the translated
    payload is dispatched after public validation; runtime handlers remain
    responsible for their legacy internal argument checks. *)
val make_keeper_tool_handler
  :  name:string
  -> input_schema:Yojson.Safe.t
  -> config:Workspace.config
  -> meta:Keeper_meta_contract.keeper_meta
  -> publication_recovery:
       Keeper_publication_recovery_availability.turn_context
  -> ctx_snapshot:Keeper_types.working_context
  -> ?turn_sandbox_factory:Keeper_sandbox_factory.t
  -> exec_cache:Masc_exec.Exec_cache.t option
  -> ?search_fn:(unit -> Keeper_tool_execution.t)
  -> ?clock:float Eio.Time.clock_ty Eio.Resource.t
  -> ?continuation_channel:Keeper_continuation_channel.t
  -> ?gate_context:(unit -> Keeper_gate.causal_context)
  -> ?gate_grant:Keeper_gate.cycle_grant
  -> ?record_gate_result:
       (operation:string -> input:Yojson.Safe.t -> Tool_result.result -> unit)
  -> ?pre_validate_input:
       (Yojson.Safe.t -> (Yojson.Safe.t, Tool_result.result) result)
  -> ?translate_input:(Yojson.Safe.t -> Yojson.Safe.t)
  -> ?validate_translated_input:bool
  -> unit
  -> Yojson.Safe.t
  -> Tool_result.result
