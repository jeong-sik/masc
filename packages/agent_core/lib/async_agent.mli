(** Async Agent — Eio fiber-based concurrent agent execution.

    Provides a fan-out pattern for running agents concurrently.

    All operations require an Eio switch for structured concurrency.

    @since 0.55.0

    @stability Evolving
    @since 0.93.1 *)

(** [all ~sw ?clock ?max_fibers agents] runs all [(agent, prompt)] pairs
    and waits for all to complete. Returns a list of
    [(agent_name, result)] pairs in the same order as input.
    Agent-level timeouts, provider errors, raw-trace failures, and ordinary
    exceptions are contained to that agent's result; parent switch cancellation
    still propagates through Eio structured concurrency.

    @param max_fibers limits concurrent fibers (default: no limit). *)
val all
  :  sw:Eio.Switch.t
  -> ?clock:_ Eio.Time.clock
  -> ?max_fibers:int
  -> (Agent.t * string) list
  -> (string * (Types.api_response, Error.t) Result.t) list
