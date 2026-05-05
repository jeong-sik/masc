(** Bounded — Constrained multi-agent execution loop with formal
    guarantees.

    Termination, safety, and soundness properties from MAGI review
    (Gemini + Qwen3 formal verification):

    - {b Termination}: always terminates via
      {!constraints.hard_max_iterations}.
    - {b Safety}: post-execution constraint check prevents silent
      violations (turns / tokens / cost / time).
    - {b Soundness}: typed comparisons + explicit error handling
      via {!comparison} variants and parser fallbacks.

    Internal: 13 helpers stay private — \[bounded_rng] (Random.State
    seeded at module load), \[retryable_error_re] (14 hoisted Re.t
    patterns), \[create_state], \[check_single] / \[check_single_float]
    / \[check_constraints] / \[check_constraints_with_buffer],
    \[resolve_path] / \[json_to_float], \[update_state],
    \[format_agent_failure] / \[format_agent_execution_failure],
    \[retry_config_of_json].  All consumed only inside
    {!bounded_run} or the {!constraints_of_json} parser.

    The predictive token-budget check used to read
    \[constraints.token_buffer] as a magic constant (5000 by default).
    Since RFC-0028 it instead consults {!Usage_history.predict_p95}
    over per-agent empirical distributions, falling back to a
    documented constant only when fewer than ten samples have
    accumulated for an agent.  The \[token_buffer] field is retained
    for JSON-input compatibility and is no longer read; see
    {!constraints} for the deprecation note. *)

(** {1 Goal conditions} *)

(** Comparison operators for goal conditions.  [Eq] / [Neq] take
    arbitrary [Yojson.Safe.t]; the rest take floats / lists. *)
type comparison =
  | Eq of Yojson.Safe.t
  | Neq of Yojson.Safe.t
  | Lt of float
  | Lte of float
  | Gt of float
  | Gte of float
  | Between of float * float
  | In of Yojson.Safe.t list

type goal = {
  path : string;       (** JSONPath-like locator (["$.field.sub"]). *)
  condition : comparison;
}
(** Goal condition.  [path] uses a minimal JSONPath subset
    ([$.field], [$.field.subfield]); see {!check_goal} for
    resolution. *)

(** {1 Retry / constraints} *)

type retry_config = {
  max_retries : int;          (** Maximum retry attempts per agent call. *)
  base_delay_ms : int;        (** Base delay (ms) before exponential growth. *)
  max_delay_ms : int;         (** Delay cap (ms). *)
  jitter_factor : float;      (** Jitter multiplier in [\[0.0, 1.0\]]. *)
}

val default_retry_config : retry_config
(** Conservative defaults: [max_retries = 3], [base_delay_ms = 1000],
    [max_delay_ms = 30000], [jitter_factor = 0.2]. *)

type constraints = {
  max_turns : int option;
  max_tokens : int option;
  max_cost_usd : float option;
  max_time_seconds : float option;
  token_buffer : int;
  (** {b Deprecated since RFC-0028.}  Retained for JSON-input
      compatibility ({!constraints_of_json} still parses it without
      raising), but no longer consulted by the predictive token check.
      The next-turn estimate now comes from
      {!Usage_history.predict_p95}.  Set to [0] in
      {!default_constraints}.  Plan: removed once external producers
      stop emitting it. *)
  hard_max_iterations : int;   (** Absolute failsafe — termination guarantee. *)
  retry : retry_config;
}

val default_constraints : constraints
(** Safe defaults: [max_turns = Some 10], [max_tokens = Some 100000],
    [max_cost_usd = Some 1.0], [max_time_seconds = Some 300.0],
    [token_buffer = 0] (deprecated; see field doc), [hard_max_iterations = 100],
    [retry = default_retry_config]. *)

(** {1 Execution state} *)

type bounded_state = {
  mutable turns : int;
  mutable tokens_in : int;
  mutable tokens_out : int;
  mutable cost_usd : float;
  mutable total_retries : int;
  start_time : float;          (** [Time_compat.now ()] at state creation. *)
  constraints : constraints;
}
(** Mutable execution accumulator.  Carried through the loop and
    snapshotted into {!bounded_result.stats} at termination. *)

(** {1 Per-agent token-usage history (RFC-0028)} *)

module Usage_history : sig
  (** Empirical distribution of per-turn output-token counts, keyed
      by agent name.  Populated by {!bounded_run} after each successful
      spawn (see RFC-0028 §4.4).  Used by the predictive token-budget
      check to estimate the next turn's cost from the high quantile
      of the recent samples instead of the linear average that
      {!check_constraints_with_buffer} historically used.

      Storage is a module-level hashtable (one bounded ring buffer per
      agent) protected by an internal mutex.  All operations are
      O(samples) with samples capped at 64 per agent. *)

  val record : agent:string -> tokens_out:int -> unit
  (** [record ~agent ~tokens_out] appends a sample to [agent]'s ring
      buffer.  When the buffer is full the oldest sample is evicted
      first.  Negative or zero [tokens_out] are dropped silently —
      mock spawns and degenerate turns must not pollute the
      distribution. *)

  val predict_p95 : ?agent:string -> unit -> int
  (** [predict_p95 ?agent ()] returns the 95th-percentile output-token
      count for [agent]'s recent samples.  When [agent] is omitted or
      fewer than [min_samples_for_p95] samples are recorded for that
      agent, returns {!unknown_agent_fallback}.  The agent's queue is
      copied and sorted; the source ring buffer is not mutated. *)

  val sample_count : ?agent:string -> unit -> int
  (** [sample_count ?agent ()] returns the current number of samples
      recorded for [agent], or [0] when no agent is supplied or the
      agent has no samples.  Test inspection helper — not consumed in
      production paths. *)

  val reset : unit -> unit
  (** [reset ()] clears every agent's ring buffer.  Used by the test
      suite to isolate cases that depend on a fresh distribution. *)

  val min_samples_for_p95 : int
  (** Minimum samples required before {!predict_p95} returns a
      distribution-derived value.  Below this threshold the predictor
      returns {!unknown_agent_fallback} instead of a noisy estimate.
      Currently [10] (RFC-0028 §4.2). *)

  val unknown_agent_fallback : int
  (** Conservative per-turn output-token estimate used when the
      empirical distribution for an agent is missing or too small.
      Currently [1024] (RFC-0028 §4.2 — the value lacks measurement
      evidence today and is intentionally documented as such). *)
end

(** {1 Helpers (test-visible)} *)

val calc_backoff_delay : retry_config -> int -> int
(** [calc_backoff_delay retry_config attempt] returns the next
    delay in ms: exponential ([base * 2^attempt]) capped by
    [max_delay_ms], plus uniform jitter in
    [\[-jitter_range/2, +jitter_range/2\]] with
    [jitter_range = capped * jitter_factor]. *)

val is_retryable_error : string -> bool
(** [is_retryable_error msg] is [true] when [msg] matches any of
    the 14 hoisted patterns: [timeout], [timed out],
    [connection refused], [connection reset], [network],
    [ECONNREFUSED], [ETIMEDOUT], [rate limit], [429], [503], [502],
    [504], [overloaded], [temporarily unavailable].  Case-insensitive
    via pre-compiled DFAs (rebuilding 14 [Re.t] per call would be
    wasted on the hot retry path). *)

val check_goal : Yojson.Safe.t -> goal -> bool
(** [check_goal result goal] resolves [goal.path] under [result]
    and evaluates [goal.condition] against the resolved value.
    Returns [false] when the path does not resolve. *)

(** {1 History / result} *)

type history_entry = {
  turn : int;
  agent : string;
  tokens_in : int;
  tokens_out : int;
  cost_usd : float;
  elapsed_ms : int;
  retries : int;
  goal_met : bool;
}
(** Per-turn history record.  Aggregated into
    {!bounded_result.history} in chronological order. *)

type bounded_result = {
  status : [ `Goal_reached | `Constraint_exceeded | `Error ];
  reason : string;
  final_output : string option;
  stats : bounded_state;
  history : history_entry list;
  warning : string option;
}
(** Terminal result.  [status] enumerates the 3 termination modes;
    [final_output] is set on success or partial-result constraint
    exceedance.  [warning] carries a post-check observation when
    constraints were tight but not exceeded mid-loop. *)

(** {1 Main loop} *)

val bounded_run :
  constraints:constraints ->
  goal:goal ->
  agents:string list ->
  prompt:string ->
  spawn_fn:(string -> string -> Spawn.spawn_result) ->
  bounded_result
(** [bounded_run ~constraints ~goal ~agents ~prompt ~spawn_fn]
    runs a constrained execution loop:

    + {b Empty agents} -> [`Error] with reason ["No agents available"].
    + Hard iteration check -> [`Constraint_exceeded] when
      [state.turns >= constraints.hard_max_iterations].
    + Predictive constraint check ({!check_constraints_with_buffer})
      -> [`Constraint_exceeded] when projected tokens would exceed
      the cap.
    + Round-robin agent selection
      ([List.nth agents (state.turns mod n)], fallback to head).
    + Spawn with retry: [is_retryable_error]-classified failures
      retry up to [constraints.retry.max_retries] with
      {!calc_backoff_delay}; non-retryable or exhausted retries
      yield [`Error].
    + Goal check via {!check_goal} on the parsed JSON output.
    + Post-check constraint observation populates
      [bounded_result.warning].

    [Eio.Cancel.Cancelled] propagates upward — the retry loop
    only swallows non-cancellation exceptions. *)

(** {1 JSON encoding} *)

val result_to_json : bounded_result -> Yojson.Safe.t
(** [result_to_json result] renders the result as a JSON object
    suitable for tool output.  Status string is one of
    ["goal_reached"] / ["constraint_exceeded"] / ["error"].
    [stats.elapsed_seconds] is computed at render time
    ([Time_compat.now () -. stats.start_time]) — successive renders
    of the same result drift in the [elapsed_seconds] field. *)

val constraints_of_json : Yojson.Safe.t -> constraints
(** [constraints_of_json json] parses a constraints object.
    [json = `Null] returns {!default_constraints} verbatim.
    Missing scalar fields fall back to {!default_constraints}
    via {!Safe_ops}.  Unknown keys are silently ignored
    (permissive). *)

val goal_of_json : Yojson.Safe.t -> goal
(** [goal_of_json json] parses a goal object with [path] +
    [condition].  Recognised condition keys: [eq], [neq], [lt],
    [lte], [gt], [gte], [between] (2-element array), [in].
    Default when no key matches: [Eq (`Bool true)] (truthy
    check).  [between] arrays with fewer than 2 elements raise
    [Invalid_argument "Bounded.rule_of_yojson: 'between' array
    must have at least 2 elements"]. *)
