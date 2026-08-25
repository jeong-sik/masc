(** Async Agent — Eio fiber-based background agent execution.

    Provides [future]-based spawning, race, and fan-out patterns
    for running agents concurrently without blocking the caller.

    All operations require an Eio switch for structured concurrency.
    Cancellation is best-effort: once the spawned fiber installs its
    sub-switch, [cancel] fails that switch to interrupt in-flight I/O
    and also resolves the future as cancelled.

    @since 0.55.0

    @stability Evolving
    @since 0.93.1 *)

(** {1 Future type} *)

(** An opaque handle to a background agent execution.
    The underlying result is communicated via {!Eio.Promise}. *)
type 'a future

(** {1 Spawning} *)

(** [spawn ~sw ?clock agent prompt] launches [agent] in a background
    Eio fiber and returns a future immediately.

    The agent runs within [sw]'s scope; if [sw] is cancelled, the
    fiber is cancelled too (Eio structured concurrency guarantee). *)
val spawn
  :  sw:Eio.Switch.t
  -> ?clock:_ Eio.Time.clock
  -> Agent.t
  -> string
  -> Types.api_response future

(** {1 Awaiting} *)

(** [await future] blocks the calling fiber until the background
    agent completes (or is cancelled). *)
val await : 'a future -> ('a, Error.t) Result.t

(** [is_ready future] returns [true] if the result is already available. *)
val is_ready : 'a future -> bool

(** {1 Cancellation} *)

(** [cancel future] resolves the future as cancelled and, if the spawned
    fiber has already installed its sub-switch, fails that switch so
    in-flight I/O can be interrupted.

    Result resolution is first-wins: if the agent fiber has already
    resolved the future with a result, [cancel] does not override it — the
    future keeps that result. A [cancel] that races an in-flight completion
    may therefore yield the completion rather than [Error "cancelled"]. The
    call stays idempotent and is visible to callers right away, while
    propagating the cancellation signal into the running fiber when
    possible. *)
val cancel : 'a future -> unit

(** {1 Combinators} *)

(** [race ~sw ?clock agents] runs all [(agent, prompt)] pairs concurrently
    and returns the result of the first agent to finish. Remaining agents
    are cancelled via Eio structured concurrency.

    Returns [(agent_name, response)] on success, where [agent_name]
    is derived from the agent's card. *)
val race
  :  sw:Eio.Switch.t
  -> ?clock:_ Eio.Time.clock
  -> (Agent.t * string) list
  -> (string * Types.api_response, Error.t) Result.t

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
