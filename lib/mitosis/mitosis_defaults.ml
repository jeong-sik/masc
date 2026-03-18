(** Mitosis defaults — named constants for configuration values.

    These defaults are tuned based on empirical observations:
    - Claude's context window fills ~80% after ~100 tool calls
    - 5-minute sessions typically reach 50% context
    - 10 tasks or 20 tool calls correlate with significant context growth

    All magic numbers are centralized here for easy tuning.
    Each constant is referenced by mitosis_config field documentation. *)

(** Time-based trigger interval in seconds.
    Rationale: 5 minutes is long enough for meaningful work,
    short enough to prevent context overflow in long sessions. *)
let time_trigger_seconds = 300.0

(** Task count trigger threshold.
    Rationale: 10 tasks typically accumulate enough context
    to benefit from division, based on average task complexity. *)
let task_trigger_count = 10

(** Tool call count trigger threshold.
    Rationale: 20 tool calls = 16% context (20/125).
    Used as early warning with other triggers. *)
let tool_call_trigger_count = 20

(** Number of reserve cells to maintain in stem pool.
    Rationale: 2 cells balance instant availability vs memory cost.
    1 for immediate use, 1 as backup during replenishment. *)
let stem_pool_size = 2

(** Maximum allowed generation before forced termination.
    Rationale: 10 generations = 10 divisions, enough for any session.
    Prevents infinite loops from runaway mitosis bugs. *)
let max_generation = 10

(** DNA compression ratio (0.0-1.0).
    Rationale: 10% retains key context while reducing handoff size.
    Empirically: first 10% contains task definition, recent work. *)
let dna_compression_ratio = 0.1

(** Grace period in seconds before completing apoptosis.
    Rationale: 5 seconds allows cleanup (file writes, log flush)
    without blocking the new cell for too long. *)
let apoptosis_delay_seconds = 5.0

(** Phase 1 threshold: extract DNA and enter Prepared state.
    Rationale: 50% leaves room for delta capture (50% to 80%).
    Early preparation avoids extraction delay at critical moment. *)
let prepare_threshold = 0.5

(** Phase 2 threshold: execute handoff to child cell.
    Rationale: 80% is the industry-standard LLM context threshold.
    Higher risks overflow, lower wastes context capacity. *)
let handoff_threshold = 0.8

(** Minimum context length to attempt delta extraction.
    Rationale: Sessions under 1000 chars are too short for
    meaningful delta. Full DNA is sufficient for short sessions. *)
let min_context_for_delta = 1000

(** Minimum compressed delta length to include in merged DNA.
    Rationale: Deltas under 100 chars are likely noise
    (whitespace, minor edits). Quality threshold per BALTHASAR feedback. *)
let min_delta_len = 100

(** Estimated tool calls to fill 100% context.
    Derivation: 100 tool calls = 80% context -> 100/0.8 = 125.
    Used to estimate context_ratio from tool call count. *)
let tool_calls_per_full_context = 125.0

(** Generation number for emergency-created cells.
    When stem pool is empty, emergency cell is created with this gen.
    999 signals abnormal creation for debugging/monitoring. *)
let emergency_generation = 999

(** Timeout for spawning a new agent cell in seconds.
    Rationale: 10 minutes allows for slow network/API conditions
    while preventing indefinite hangs.
    Now delegated to Env_config.Spawn.timeout_seconds for centralized config. *)
let spawn_timeout_seconds = Env_config.Spawn.timeout_seconds
