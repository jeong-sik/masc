(** MASC Mitosis -- Cell Division Pattern for Infinite Agent Lifecycle.

    Implements a biological cell-division metaphor for AI agent context
    management. When an agent's context window fills up, it "divides" by
    extracting compressed DNA (context summary) and spawning a successor.

    Key concepts:
    - {b Mitosis}: Agent division before context overflow.
    - {b Apoptosis}: Graceful death after successful division.
    - {b Stem Cells}: Reserve agents in a pool, ready for instant activation.
    - {b DNA}: Compressed context transferred from parent to child.
    - {b 2-Phase handoff}: DNA extracted at 50% (prepare), handoff at 80%.

    State machine:
    {v
      Stem -> Active -> Prepared -> Dividing -> Apoptotic -> Dead
    v}

    @since 0.3.0 *)

(** {1 Core Types} *)

(** Lifecycle state of an agent cell.

    Transitions follow a strict forward-only path (no backward transitions).
    See the state machine diagram in the module-level documentation. *)
type cell_state =
  | Stem
      (** Reserve cell waiting in the stem pool.
          Transitions to [Active] via {!activate_stem}. *)
  | Active
      (** Currently working on tasks.
          Transitions to [Prepared] when {!should_prepare} returns [true]. *)
  | Prepared
      (** DNA extracted, waiting for handoff threshold.
          Cell continues working but is ready for instant handoff.
          Transitions to [Dividing] when {!should_handoff} returns [true]. *)
  | Dividing
      (** Mitosis in progress; DNA being transferred to child cell.
          Transitions to [Apoptotic] after {!perform_mitosis}. *)
  | Apoptotic
      (** Gracefully shutting down after successful division.
          Has a configurable grace period ({!mitosis_config.apoptosis_delay}).
          Transitions to [Dead] via {!complete_apoptosis}. *)

(** Mitosis phase within the 2-phase handoff approach. *)
type mitosis_phase =
  | Idle
      (** Normal operation, no mitosis activity in progress. *)
  | ReadyForHandoff of string
      (** DNA has been extracted and is stored in the [string] payload.
          Waiting for context ratio to reach {!mitosis_config.handoff_threshold}. *)

(** Agent cell with lifecycle metadata.

    Each cell tracks its generation number (distance from the original agent),
    birth time, activity counters, and any inherited or prepared DNA. *)
type cell = {
  id : string;  (** Collision-resistant identifier (random hex suffix). *)
  generation : int;  (** Number of divisions from the origin cell. *)
  state : cell_state;  (** Current lifecycle state. *)
  phase : mitosis_phase;  (** Current mitosis phase within the 2-phase approach. *)
  born_at : float;  (** Unix timestamp when this cell was created. *)
  last_activity : float;  (** Unix timestamp of last task or tool activity. *)
  context_dna : string option;  (** Compressed context inherited from parent. *)
  prepared_dna : string option;  (** DNA extracted at the prepare phase. *)
  prepare_context_len : int;  (** Context length when DNA was extracted, for delta calculation. *)
  task_count : int;  (** Number of tasks completed by this cell. *)
  tool_call_count : int;  (** Number of tool calls made by this cell. *)
}

(** Stem cell pool -- reserve agents ready for instant activation.

    Maintains a fixed number of pre-created cells in [Stem] state.
    When a cell divides, one stem cell is activated and a new stem
    cell is created to replenish the pool. *)
type stem_pool = {
  cells : cell list;  (** List of reserve cells (may include non-Stem cells during transitions). *)
  max_size : int;  (** Maximum number of cells to maintain. *)
  warm_up_count : int;  (** Number of cells to keep pre-warmed. *)
}

(** Trigger conditions that can initiate mitosis.

    Any single trigger being met will initiate the prepare or handoff phase.
    Multiple triggers can be combined in {!mitosis_config.triggers}. *)
type mitosis_trigger =
  | Time_based of float
      (** Trigger after [float] seconds of cell lifetime. *)
  | Task_count of int
      (** Trigger after completing [int] tasks. *)
  | Tool_calls of int
      (** Trigger after making [int] tool calls. *)
  | Context_threshold of float
      (** Trigger at [float] context usage ratio (0.0--1.0).
          Note: handled by the 2-phase thresholds in practice. *)
  | Complexity_spike
      (** Trigger when task complexity increases. Currently unused. *)

(** Mitosis configuration.

    Controls when and how agent cells divide. Uses a 2-phase approach:
    - Phase 1 (Prepare): Extract DNA at {!field-prepare_threshold}.
    - Phase 2 (Handoff): Execute division at {!field-handoff_threshold}.

    This design ensures DNA is extracted early (no extraction delay at 80%)
    and delta changes between 50%--80% are merged into the final DNA. *)
type mitosis_config = {
  triggers : mitosis_trigger list;
      (** List of conditions that trigger mitosis.
          Any single trigger being met initiates division.
          Evaluated in {!check_non_context_triggers}. *)
  stem_pool_size : int;
      (** Number of reserve cells to maintain. Default: 2. *)
  max_generation : int;
      (** Maximum generation to prevent infinite loops. Default: 10. *)
  dna_compression_ratio : float;
      (** Context compression ratio (0.0--1.0). 0.1 keeps 10%. Default: 0.1. *)
  apoptosis_delay : float;
      (** Grace period in seconds before completing apoptosis. Default: 5.0. *)
  prepare_threshold : float;
      (** Context usage ratio to trigger Phase 1 (DNA extraction). Default: 0.5. *)
  handoff_threshold : float;
      (** Context usage ratio to trigger Phase 2 (actual handoff). Default: 0.8. *)
  min_context_for_delta : int;
      (** Minimum context length (chars) to attempt delta extraction.
          Sessions shorter than this skip delta. Default: 1000. *)
  min_delta_len : int;
      (** Minimum compressed delta length (chars) to include in merged DNA.
          Shorter deltas are treated as noise and discarded. Default: 100. *)
}

(** {1 Named Constants} *)

(** Named constants for configuration values.

    Centralized defaults tuned from empirical observations.
    Each constant is referenced by {!mitosis_config} field docs. *)
module Defaults : sig
  val time_trigger_seconds : float
  (** Time-based trigger interval. Default: 300.0 (5 minutes). *)

  val task_trigger_count : int
  (** Task count trigger threshold. Default: 10. *)

  val tool_call_trigger_count : int
  (** Tool call count trigger threshold. Default: 20. *)

  val stem_pool_size : int
  (** Default stem pool size. Default: 2. *)

  val max_generation : int
  (** Maximum generation before forced termination. Default: 10. *)

  val dna_compression_ratio : float
  (** Default DNA compression ratio. Default: 0.1 (keep 10%). *)

  val apoptosis_delay_seconds : float
  (** Grace period before completing apoptosis. Default: 5.0s. *)

  val prepare_threshold : float
  (** Phase 1 threshold for DNA extraction. Default: 0.5 (50%). *)

  val handoff_threshold : float
  (** Phase 2 threshold for handoff execution. Default: 0.8 (80%). *)

  val min_context_for_delta : int
  (** Minimum context length for delta extraction. Default: 1000 chars. *)

  val min_delta_len : int
  (** Minimum delta length to include. Default: 100 chars. *)

  val tool_calls_per_full_context : float
  (** Estimated tool calls to fill 100% context. Default: 125.0. *)

  val emergency_generation : int
  (** Generation number for emergency-created cells. Default: 999. *)

  val spawn_timeout_seconds : int
  (** Timeout for spawning a new agent cell. Delegates to {!Env_config.Spawn}. *)
end

(** {1 Configuration} *)

(** Default mitosis configuration using the 2-phase approach.
    Uses values from {!Defaults}. *)
val default_config : mitosis_config

(** {1 String Conversion} *)

(** [state_to_string state] returns a lowercase string representation
    of [state] (e.g., ["stem"], ["active"], ["prepared"]). *)
val state_to_string : cell_state -> string

(** [phase_to_string phase] returns a string representation
    of the mitosis phase (["idle"] or ["ready_for_handoff"]). *)
val phase_to_string : mitosis_phase -> string

(** {1 State Transition Logging} *)

(** [log_state_transition ~old_state ~new_state ~agent_name ~reason]
    emits a structured log line for observability, including old/new state,
    agent name, timestamp, and transition reason. *)
val log_state_transition :
  old_state:cell_state ->
  new_state:cell_state ->
  agent_name:string ->
  reason:string ->
  unit

(** {1 Cell Creation and Pool Management} *)

(** [create_stem_cell ~generation] creates a new cell in {!Stem} state
    with a collision-resistant random hex ID. *)
val create_stem_cell : generation:int -> cell

(** [init_pool ~config] creates a stem cell pool with
    [config.stem_pool_size] reserve cells. *)
val init_pool : config:mitosis_config -> stem_pool

(** {1 Trigger Evaluation} *)

(** [check_non_context_triggers ~config ~cell] returns [true] if any
    non-context trigger (time, task count, tool calls) is met for [cell]. *)
val check_non_context_triggers : config:mitosis_config -> cell:cell -> bool

(** [should_prepare ~config ~cell ~context_ratio] returns [true] if
    Phase 1 (DNA extraction) should begin.

    Returns [false] if the cell is already in {!ReadyForHandoff} phase.
    Triggers on [context_ratio >= config.prepare_threshold] or any
    non-context trigger. *)
val should_prepare :
  config:mitosis_config -> cell:cell -> context_ratio:float -> bool

(** [should_handoff ~config ~cell ~context_ratio] returns [true] if
    Phase 2 (actual handoff) should execute.

    Fires when [context_ratio >= config.handoff_threshold], regardless
    of whether the cell was previously prepared (emergency handoff). *)
val should_handoff :
  config:mitosis_config -> cell:cell -> context_ratio:float -> bool

(** [should_divide ~config ~cell ~context_ratio] is a legacy alias
    for {!should_handoff}. Kept for backward compatibility. *)
val should_divide :
  config:mitosis_config -> cell:cell -> context_ratio:float -> bool

(** {1 DNA Extraction and Compression} *)

(** [compress_to_dna ~ratio ~context] compresses [context] to approximately
    [ratio] of its original length. For contexts longer than 200 chars,
    keeps 60% from the head and 40% from the tail with a gap marker. *)
val compress_to_dna : ratio:float -> context:string -> string

(** [extract_dna ~config ~parent_cell ~full_context] builds complete DNA
    from a parent cell's context, including continuity anchors (goal, task,
    recent turns), mentor wisdom, and compressed context. *)
val extract_dna :
  config:mitosis_config -> parent_cell:cell -> full_context:string -> string

(** [bounded_handoff_dna ~config ~parent_cell ~full_context] extracts DNA
    and truncates it to the handoff token budget (20,000 tokens / ~80,000 chars). *)
val bounded_handoff_dna :
  config:mitosis_config -> parent_cell:cell -> full_context:string -> string

(** [extract_delta ~config ~full_context ~since_len] extracts and compresses
    context changes since position [since_len].

    Returns empty string if:
    - Full context is shorter than {!mitosis_config.min_context_for_delta}
    - No new content since [since_len]
    - Compressed delta is shorter than {!mitosis_config.min_delta_len} *)
val extract_delta :
  config:mitosis_config -> full_context:string -> since_len:int -> string

(** [merge_dna_with_delta ~prepared_dna ~delta] merges Phase 1 DNA with
    delta changes from the 50%--80% window. Deduplicates overlapping lines
    and adds a section marker for the delta portion. *)
val merge_dna_with_delta : prepared_dna:string -> delta:string -> string

(** {1 Mentor Wisdom} *)

(** [generate_mentor_wisdom ~parent_cell] produces advice from the parent
    cell to its successor based on lifecycle experience: age, task count,
    tool usage patterns, and context pressure status. *)
val generate_mentor_wisdom : parent_cell:cell -> string

(** {1 Cell Lifecycle Operations} *)

(** [prepare_for_division ~config ~cell ~full_context] executes Phase 1:
    extracts DNA, transitions cell to {!Prepared} state with
    {!ReadyForHandoff} phase, and logs the state transition.

    @return the updated cell in [Prepared] state. *)
val prepare_for_division :
  config:mitosis_config -> cell:cell -> full_context:string -> cell

(** [activate_stem ~pool ~dna] activates one stem cell from the pool
    and injects [dna] as its inherited context.

    If the pool is empty, creates an emergency cell with generation
    {!Defaults.emergency_generation} (999).

    @return [(activated_cell, updated_pool)] *)
val activate_stem : pool:stem_pool -> dna:string -> cell * stem_pool

(** [begin_apoptosis cell] transitions [cell] to {!Apoptotic} state
    and logs the transition. *)
val begin_apoptosis : cell -> cell

(** [complete_apoptosis cell] finalizes the cell's death.
    @return [`Dead] *)
val complete_apoptosis : cell -> [> `Dead ]

(** [perform_mitosis ~config ~pool ~parent ~full_context] executes the
    full mitosis division: builds merged DNA, begins parent apoptosis,
    activates a stem cell, and replenishes the pool.

    @return [(child, dying_parent, replenished_pool, dna)] *)
val perform_mitosis :
  config:mitosis_config ->
  pool:stem_pool ->
  parent:cell ->
  full_context:string ->
  cell * cell * stem_pool * string

(** [build_mitosis_prompt ~child ~dna] constructs the handoff prompt
    injected into the successor agent's context. Includes generation
    number, inherited DNA, and continuation instructions. *)
val build_mitosis_prompt : child:cell -> dna:string -> string

(** [execute_mitosis ~config ~pool ~parent ~full_context ~spawn_fn]
    performs the full mitosis cycle: division, prompt construction,
    agent spawn, and parent apoptosis.

    @param spawn_fn callback that spawns a new agent with the given prompt
    @return [(spawn_result, child, new_pool, dna)] *)
val execute_mitosis :
  config:mitosis_config ->
  pool:stem_pool ->
  parent:cell ->
  full_context:string ->
  spawn_fn:(prompt:string -> Spawn.spawn_result) ->
  Spawn.spawn_result * cell * stem_pool * string

(** [record_activity ~cell ~task_done ~tool_called] increments the
    cell's activity counters and updates [last_activity] timestamp.

    @param task_done if [true], increments {!field-task_count}
    @param tool_called if [true], increments {!field-tool_call_count} *)
val record_activity : cell:cell -> task_done:bool -> tool_called:bool -> cell

(** {1 Auto-Mitosis Check} *)

(** Result of the 2-phase auto-mitosis check. *)
type mitosis_check_result =
  | NoAction
      (** Neither prepare nor handoff threshold reached. *)
  | Prepared of cell
      (** Phase 1 complete: cell has been prepared with extracted DNA. *)
  | Handoff of Spawn.spawn_result * cell * stem_pool * string
      (** Phase 2 complete: handoff executed. Contains
          [(spawn_result, child_cell, new_pool, dna)]. *)

(** [auto_mitosis_check_2phase ~config ~pool ~cell ~context_ratio
      ~full_context ~spawn_fn]
    runs the 2-phase mitosis check. Phase 2 (handoff) has higher priority
    than Phase 1 (prepare).

    @return {!mitosis_check_result} *)
val auto_mitosis_check_2phase :
  config:mitosis_config ->
  pool:stem_pool ->
  cell:cell ->
  context_ratio:float ->
  full_context:string ->
  spawn_fn:(prompt:string -> Spawn.spawn_result) ->
  mitosis_check_result

(** [auto_mitosis_check ~config ~pool ~cell ~context_ratio ~full_context
      ~spawn_fn]
    is a legacy single-phase auto-mitosis check. Kept for backward
    compatibility. Prefer {!auto_mitosis_check_2phase}. *)
val auto_mitosis_check :
  config:mitosis_config ->
  pool:stem_pool ->
  cell:cell ->
  context_ratio:float ->
  full_context:string ->
  spawn_fn:(prompt:string -> Spawn.spawn_result) ->
  (Spawn.spawn_result * cell * stem_pool * string) option

(** {1 JSON Serialization} *)

(** [cell_to_json cell] serializes a cell to a JSON object. *)
val cell_to_json : cell -> Yojson.Safe.t

(** [pool_to_json pool] serializes a stem pool to a JSON object,
    including a computed [stem_count] field. *)
val pool_to_json : stem_pool -> Yojson.Safe.t

(** [trigger_to_json trigger] serializes a mitosis trigger to JSON. *)
val trigger_to_json : mitosis_trigger -> Yojson.Safe.t

(** [config_to_json config] serializes mitosis configuration to JSON. *)
val config_to_json : mitosis_config -> Yojson.Safe.t

(** {1 Status Persistence} *)

(** [write_status ~base_path ~cell ~config] writes mitosis status
    to [{base_path}/.masc/mitosis-status.json] for hook consumption.
    The hook reads this file to warn about context pressure.

    Status levels: ["healthy"], ["warning"] (>= prepare threshold),
    ["critical"] (>= handoff threshold). *)
val write_status :
  base_path:string -> cell:cell -> config:mitosis_config -> unit

(** [write_status_with_backend ~room_config ~cell ~config] writes status
    to both local file (for hooks) and the backend key-value store
    (for cross-machine collaboration). Backend key format: [mitosis:{node_id}]. *)
val write_status_with_backend :
  room_config:Room_utils.config -> cell:cell -> config:mitosis_config -> unit

(** [get_all_statuses ~room_config] retrieves mitosis statuses from all
    agents via the backend store. Useful for monitoring context pressure
    across the cluster.

    @return list of [(node_id, status, estimated_ratio)] tuples. *)
val get_all_statuses :
  room_config:Room_utils.config -> (string * string * float) list

(** {1 Internal Helpers (exposed for testing)} *)

(** [safe_sub s start len] extracts a substring without raising exceptions.
    Returns empty string on invalid range. *)
val safe_sub : string -> int -> int -> string

(** Approximate token budget for handoff DNA. *)
val handoff_token_budget : int

(** Maximum character count derived from {!handoff_token_budget}. *)
val handoff_max_chars : unit -> int

(** [truncate_to_handoff_budget context] truncates [context] to fit
    within {!handoff_token_budget}, keeping the latest content. *)
val truncate_to_handoff_budget : string -> string

(** [deduplicate_lines ~base ~delta] removes lines from [delta] that
    already appear in [base]. Uses {!StringSet} for O(n log n) lookup.
    Only tracks lines longer than 10 characters. *)
val deduplicate_lines : base:string -> delta:string -> string

(** String set module used for line deduplication. *)
module StringSet : Set.S with type elt = string
