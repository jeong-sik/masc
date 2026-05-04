(** Keeper_world_observation — Structured world state for keeper cycles.

    Extracts and normalizes observation signals from room state, keeper meta,
    and context so the unified prompt builder and turn runner can consume
    a single coherent snapshot instead of re-reading scattered sources.

    @since Unified Keeper Loop *)

(** Structured board activity delivered to keepers without routing heuristics. *)
type pending_board_event = {
  post_id : string;
  author : string;
  title : string;
  preview : string;
  hearth : string option;
  post_kind : Board_types.post_kind;
  updated_at : float;
  explicit_mention : bool;
  matched_targets : string list;
  self_commented : bool;
  (** [true] if this keeper has previously commented on this post. *)
  new_external_since : int;
  (** Number of external comments posted after the keeper's latest comment. *)
  latest_external_author : string option;
  (** Author of the most recent external comment (for prompt context). *)
  latest_external_preview : string option;
  (** Preview of the most recent external comment content. *)
}

(** Snapshot of the world as seen by a keeper at heartbeat time. *)
type world_observation = {
  pending_mentions : (string * string) list;
  (** [(from_agent, content)] pairs of unprocessed direct mentions. *)

  pending_board_events : pending_board_event list;
  (** Structured board events needing triage. *)

  pending_scope_messages : (string * string) list;
  (** [(from_agent, content)] pairs of unprocessed non-direct messages that a
      global/all keeper is explicitly allowed to observe in the flattened
      namespace. *)

  message_cursor_updates : (string * int) list;
  (** Deterministic message cursor watermarks collected during observation.
      These are applied to keeper meta before the next turn to avoid
      reprocessing the same broadcast stream. *)

  idle_seconds : int;
  (** Seconds since last keeper activity (turn or scheduled autonomous cycle). *)

  active_goals : string list;
  (** Goal IDs currently assigned to this keeper. *)

  continuity_summary : string;
  (** Latest continuity snapshot text (empty if unavailable). *)

  worktree_change_summary : string option;
  (** Git worktree delta detected since the previous keeper turn, if any. *)

  context_ratio : float;
  (** Current context window utilization [0.0, 1.0]. *)

  economic_pressure : Agent_economy.pressure_mode;
  (** Agent economy mode: Normal, Frugal, or Hustle. *)

  unclaimed_task_count : int;
  (** Number of unclaimed tasks in the room backlog. *)

  claimable_task_count : int;
  (** Number of unclaimed tasks this keeper can claim with its current tool
      surface. This is a matched subset of [unclaimed_task_count]. *)

  failed_task_count : int;
  (** Number of failed/cancelled tasks in the room backlog. *)

  pending_verification_count : int;
  (** Number of tasks awaiting cross-agent verification. *)

  backlog_updated_since_last_scheduled_autonomous : bool;
  (** [true] when the backlog changed after the keeper's last scheduled
      autonomous attempt. Lets task-triggered wakeups bypass cooldown once
      so newly added work is not delayed behind the previous turn's timer. *)

  active_agent_count : int;
  (** Number of agents currently active in the room. *)

  last_turn_budget : (int * int) option;
  (** Previous generation's turn usage as [(used, total)], if available. *)

  last_tools_used : string list;
  (** Tools used in the previous cycle. Empty on first cycle or when unavailable.
      Used by the prompt builder to generate data-driven anti-repetition hints. *)

  work_discovery_due : bool;
}

type keeper_cycle_channel =
  | Reactive
  | Scheduled_autonomous

type unified_turn_channel = keeper_cycle_channel

(** Typed reason for running a keeper cycle. Each variant corresponds to
    exactly one code path in {!keeper_cycle_decision}. *)
type turn_reason =
  | Mention_pending
  | Board_event_pending
  | Scope_message_pending
  | Scheduled_autonomous_turn
  | Idle_cooldown_elapsed of { idle_sec : int; cooldown : int }
  | Cooldown_elapsed
  | Task_backlog of { unclaimed : int; failed : int }
  | Task_reactive_cooldown_elapsed
  | Never_started
  | Min_interval_elapsed
  | Entropic_oscillation

(** Typed reason for skipping a keeper turn. *)
type skip_reason =
  | Keeper_paused
  | Approval_pending
  | Scheduled_autonomous_disabled
  | Provider_cooldown_pending of { remaining_sec : int }
  | Idle_gate_pending of { remaining_sec : int }
  | Cooldown_pending of { remaining_sec : int }
  | No_signal

(** Keeper cycle decision with non-empty reason list (NEL).
    [Run] guarantees at least one trigger reason.
    [Skip] guarantees at least one skip reason.
    Channel is held by [keeper_cycle_decision], not duplicated here. *)
type turn_verdict =
  | Run of { reasons : turn_reason * turn_reason list }
  | Skip of { reasons : skip_reason * skip_reason list }

(** Convert a single turn reason to a flat string tag.
    The tag is a stable snake_case form of the typed variant.
    Variant payloads are intentionally omitted. *)
val turn_reason_to_string : turn_reason -> string

(** Convert a single skip reason to a flat string tag.
    The tag is a stable snake_case form of the typed variant.
    Variant payloads are intentionally omitted. *)
val skip_reason_to_string : skip_reason -> string

(** Convert channel to string tag. *)
val channel_to_string : keeper_cycle_channel -> string

(** Check if a string channel tag represents an autonomous cycle
    (scheduled_autonomous or proactive). *)
val is_autonomous_channel : string -> bool

(** Extract all reasons as flat string tags from a verdict.
    Tags map 1:1 to the typed reasons carried by the verdict and do not
    include variant payloads. *)
val verdict_reasons_to_strings : turn_verdict -> string list

type keeper_cycle_decision = {
  should_run : bool;
  channel : keeper_cycle_channel;
  verdict : turn_verdict;
  since_last_scheduled_autonomous : int option;
  effective_cooldown : int option;
  task_reactive_cooldown : int option;
  idle_gate_sec : int option;
}

type unified_turn_decision = keeper_cycle_decision

type board_signal_match = {
  explicit_mention : bool;
  matched_targets : string list;
  score : int;
}

(** Collect recent board activity within the keeper's heartbeat window.
    Returns [(events, new_post_count, mention_count)].
    Used by both the world observation builder and the deliberation triage
    in keepalive to populate board-related triggers. *)
val collect_board_events :
  base_path:string ->
  continuity_summary:string ->
  meta:Keeper_types.keeper_meta ->
  pending_board_event list * int * int

val board_signal_match :
  continuity_summary:string ->
  meta:Keeper_types.keeper_meta ->
  signal:Board_dispatch.keeper_board_signal ->
  board_signal_match

val board_signal_wake_reason :
  continuity_summary:string ->
  meta:Keeper_types.keeper_meta ->
  signal:Board_dispatch.keeper_board_signal ->
  string option

(** Convert a queued Event Layer stimulus back into structured board activity
    for the next keeper prompt. Returns [None] for non-board stimuli. *)
val pending_board_event_of_stimulus :
  continuity_summary:string ->
  meta:Keeper_types.keeper_meta ->
  Keeper_event_queue.stimulus ->
  pending_board_event option

(** Read the best available continuity summary for a keeper.
    Recovery order is progress log -> checkpoint snapshot -> meta summary. *)
val read_continuity_summary :
  config:Coord.config ->
  meta:Keeper_types.keeper_meta ->
  string

(** Build a world observation from room state and keeper metadata.

    Reads room backlog, agent list, checkpoint context, economy state,
    and recent board activity.
    All I/O errors are caught and produce safe defaults (0, empty, Normal).

    @param pending_board_events Pre-collected board event summaries for this
      heartbeat, if already fetched during triage
    @param config Coord configuration for I/O operations
    @param meta Current keeper metadata *)
val observe :
  allowed_tool_names:string list option ->
  pending_board_events:pending_board_event list option ->
  config:Coord.config ->
  meta:Keeper_types.keeper_meta ->
  world_observation

(** Structured work signal present in the observation itself. *)
val actionable_signal_present : world_observation -> bool

val apply_message_cursor_updates :
  Keeper_types.keeper_meta ->
  (string * int) list ->
  Keeper_types.keeper_meta

(** Compute effective scheduled autonomous cooldown with idle decay.
    After extended idle (> base cooldown), halve the cooldown each
    additional period, down to a configurable floor. *)
val effective_scheduled_autonomous_cooldown :
  base_cooldown:int -> since_last:int ->
  ?consecutive_noop_count:int -> unit -> int

(** Backward-compatible alias for the pre-rename helper name. *)
val effective_proactive_cooldown :
  base_cooldown:int -> since_last:int ->
  ?consecutive_noop_count:int -> unit -> int

val provider_cooldown_remaining_sec_for_cascade :
  cascade_name:Keeper_cascade_profile.runtime_name -> int option

val keeper_cycle_decision :
  ?provider_cooldown_remaining_sec:
    (cascade_name:Keeper_cascade_profile.runtime_name -> int option) ->
  meta:Keeper_types.keeper_meta -> world_observation -> keeper_cycle_decision

val unified_turn_decision :
  ?provider_cooldown_remaining_sec:
    (cascade_name:Keeper_cascade_profile.runtime_name -> int option) ->
  meta:Keeper_types.keeper_meta -> world_observation -> keeper_cycle_decision

val should_run_keeper_cycle :
  meta:Keeper_types.keeper_meta -> world_observation -> bool

val should_run_unified_turn :
  meta:Keeper_types.keeper_meta -> world_observation -> bool
