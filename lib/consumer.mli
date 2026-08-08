(** Consumer API — high-level agent execution with telemetry aggregation.

    Wraps {!Agent.run} and collects all Layer 1 telemetry into a single
    {!run_result} record. Designed for higher-level multi-agent consumers that
    need response + trace + harness data in one call.

    @since 0.55.0

    @stability Evolving
    @since 0.93.1 *)

(** Result of running an agent with telemetry collection. *)
type run_result =
  { response : (Types.api_response, Error.sdk_error) result
  ; trace_ref : Raw_trace.run_ref option
  ; harness_verdict : Harness.verdict option
  ; elapsed : float
  }

(** [run_agent ~sw ?clock ?harness agent prompt] executes the agent
    and returns a {!run_result} with all available telemetry.

    If [harness] is provided, evaluates the behavioral expectation
    against the agent's observation after the run. *)
val run_agent
  :  sw:Eio.Switch.t
  -> ?clock:_ Eio.Time.clock
  -> ?harness:Harness.Behavioral.expectation
  -> Agent.t
  -> string
  -> run_result

(** [run_agents ~sw ?clock ?max_fibers agents] runs multiple
    [(agent, prompt)] pairs concurrently and returns
    [(agent_name, run_result)] pairs. *)
val run_agents
  :  sw:Eio.Switch.t
  -> ?clock:_ Eio.Time.clock
  -> ?max_fibers:int
  -> (Agent.t * string) list
  -> (string * run_result) list
