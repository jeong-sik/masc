(** RFC-0145 PR-1: extract Phase 0 wake-time payload telemetry from
    [keeper_agent_run.run_turn] Step 8 body (L565-L609).

    Dead-code when [MASC_PAYLOAD_TELEMETRY] is unset.  Compute logic
    lives in [Keeper_wake_telemetry]; this module is the env-flag
    guard + [Dashboard_harness_health.record_wake_payload] call site.
    Exceptions from the telemetry path never abort the LLM call.

    Side effects only (Option C baseline metrics).
    [Eio.Cancel.Cancelled] is re-raised so the outer turn cleanup
    handler observes the cancellation; other exceptions log a WARN. *)
val emit_if_enabled
  :  meta:Keeper_types.keeper_meta
  -> system_prompt:string
  -> tools:Agent_sdk.Tool_op.t list
  -> history_messages:Agent_sdk.Types.message list
  -> user_message:string
  -> turn_index:int
  -> max_context:int
  -> pre_dispatch_compacted:bool
  -> unit
