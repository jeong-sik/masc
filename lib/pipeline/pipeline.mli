(** Turn pipeline: 6-stage decomposition of agent turn execution.

    [Input] -> [Parse] -> [Route] -> [Collect] -> [Output]
    (Execute runs inside Output on StopToolUse.)

    Each stage is a well-defined function.  The pipeline coordinates
    them, threading agent state through mutable updates.  This module
    replaces the monolithic [run_turn_core] in agent.ml.

    @stability Evolving
    @since 0.93.1 *)

type api_strategy =
  | Sync
  | Stream of
      { on_event : Types.sse_event -> unit
      ; on_telemetry : (Llm_provider.Telemetry_event.t -> unit) option
      }

type turn_outcome =
  | Complete of Types.api_response
  | ToolsExecuted of Agent_types.checkpoint_stage
  | TerminalToolCompleted of Terminal_tool_receipt.t

(** Observation-only domain label stamped on a durable [Error_occurred] event,
    derived from the actual error's typed [Error.category] (not hardcoded).
    A journal/store-write failure surfaces as [Error.Internal] and is labeled
    "Internal", not "Api"; genuine provider ([Error.Api]) errors stay "Api".
    This projection is for observation only; it does not affect control flow,
    retry, or provider-failure attribution. *)
val error_domain_of : Error.sdk_error -> string

(** Persist [state] using the same pre-commit checkpoint transaction as turn
    collection. The live agent state is not changed by this function. *)
val persist_turn_checkpoint_for_state
  :  Agent_types.t
  -> Agent_types.checkpoint_stage
  -> Types.agent_state
  -> (unit, Error.sdk_error) result

(** Run a single agent turn through the 6-stage pipeline.
    Equivalent to the previous [run_turn_core].

    [before_tool_execution], when present, runs exactly once for a non-empty
    tool batch after assistant collection has committed successfully and before
    the first tool hook or implementation starts.  Exceptions propagate and
    prevent tool execution.

    A private fiber-local execution scope, when bound by [Agent], owns the turn
    and exact selected provider attempt before provider I/O. The caller owns
    root settlement; this function closes its successful turn descendants,
    while an error leaves them open for the caller's atomic abort. *)
val run_turn
  :  sw:Eio.Switch.t
  -> ?clock:_ Eio.Time.clock
  -> api_strategy:api_strategy
  -> ?raw_trace_run:Raw_trace.active_run
  -> ?on_provider_failure:(Provider_failure_attribution.t option -> unit)
  -> ?before_tool_execution:(unit -> unit)
  -> Agent_types.t
  -> (turn_outcome, Error.sdk_error) result
