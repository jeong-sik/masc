(** Keeper_world_observation — Structured world state for keeper cycles.

    Extracts and normalizes observation signals from workspace state, keeper meta,
    and context so the unified prompt builder and turn runner can consume
    a single coherent snapshot instead of re-reading scattered sources.

    @since Unified Keeper Loop *)

(** Structured board activity delivered to keepers without routing heuristics. *)
type board_reaction_event = {
  target_type : Board_types.reaction_target_type;
  target_id : string;
  user_id : string;
  emoji : string;
  reacted : bool;
}

type pending_board_event_kind =
  | Board_post_created
  | Board_comment_added
  | Board_reaction_changed of board_reaction_event
  | Fusion_completed
  | Bg_completed
  | Schedule_due
  | External_attention
  | Failure_judgment
      (** RFC-0313 W2: deterministic turn failure escalated for an
          LLM-boundary verdict on the keeper's next turn. *)
  | Goal_assigned
      (** RFC-0315 P3 W0: a goal entered this keeper's [active_goal_ids];
          the assignment edge surfaces as actionable turn input. *)

type pending_board_event = {
  event_kind : pending_board_event_kind;
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

(** Read-only projection of one schedule row that needs keeper attention. *)
type scheduled_automation_item = {
  schedule_id : string;
  action : string;
  status : string;
  payload_kind : string option;
  recurrence_summary : string;
  due_at : float;
  keeper_next_tool : string option;
  keeper_next_action : string;
}

(** Durable scheduled-automation summary from the MASC schedule store. *)
type scheduled_automation_observation = {
  active_count : int;
  due_ready_count : int;
  next_due_at : float option;
  items : scheduled_automation_item list;
}

val empty_scheduled_automation_observation : scheduled_automation_observation

(** Snapshot of the world as seen by a keeper at heartbeat time. *)
type world_observation = {
  pending_messages : Keeper_world_observation_message_scope.pending_message list;
  (** Unacknowledged mention/scope rows in durable source order. *)

  pending_board_events : pending_board_event list;
  (** Structured board events needing triage. *)

  idle_seconds : int;
  (** Seconds since last keeper activity (turn or scheduled autonomous cycle). *)

  active_goals : string list;
  (** Goal IDs currently assigned to this keeper. *)

  unclaimed_task_count : int;
  (** Number of unclaimed tasks in the workspace backlog. *)

  claimable_task_count : int;
  (** Number of unclaimed tasks this keeper can claim with its current tool
      surface. This is a matched subset of [unclaimed_task_count]. *)

  failed_task_count : int;
  (** Number of failed/cancelled tasks in the workspace backlog. *)

  pending_verification_count : int;
  (** Number of tasks awaiting cross-agent verification. *)

  scheduled_automation : scheduled_automation_observation;
  (** Durable schedule-store state that needs keeper attention, such as due
      requests ready to dispatch. *)

  backlog_updated_since_last_scheduled_autonomous : bool;
  (** [true] when the backlog changed after the keeper's last scheduled
      autonomous attempt. Lets task-triggered wakeups bypass cooldown once
      so newly added work is not delayed behind the previous turn's timer. *)

  running_keeper_fiber_count : int;
  (** Number of live keeper fibers for this workspace base path. *)

  connected_surfaces : Gate_surface.surface_presence list;
  (** Connector surfaces attached to this keeper (RFC-0223 P2).
      Recomputed from binding stores + connector liveness on every
      observation; the dashboard entry is always present. Presence
      only — no conversation content, no counts. *)
}

type keeper_cycle_channel =
  | Reactive
  | Scheduled_autonomous

type event_queue_trigger =
  | Bootstrap_stimulus
  | Scheduled_automation_stimulus
  | Connector_attention_stimulus
  | Hitl_resolved_stimulus
  | Failure_judgment_stimulus

(** Typed reason for running a keeper cycle. Each variant corresponds to
    exactly one code path in {!keeper_cycle_decision}. *)
type turn_reason =
  | Mention_pending
  | Board_event_pending
  | Scope_message_pending
  | Bootstrap_stimulus_pending
  | Connector_attention_pending
  | Hitl_resolved_pending
  | Failure_judgment_pending
  | Scheduled_autonomous_turn
  | Scheduled_automation_due
  | Task_backlog of { unclaimed : int; failed : int }
  | Never_started

(** Typed reason for skipping a keeper turn. *)
type skip_reason =
  | Keeper_paused
  | Scheduled_autonomous_disabled
  | Reactive_disabled

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

(** Convert an Event Queue stimulus trigger into the corresponding run reason. *)
val turn_reason_of_event_queue_trigger : event_queue_trigger -> turn_reason

(** Convert a single skip reason to a flat string tag.
    The tag is a stable snake_case form of the typed variant.
    Variant payloads are intentionally omitted. *)
val skip_reason_to_string : skip_reason -> string

(** Convert channel to its canonical wire tag ("turn" / "scheduled_autonomous"). *)
val channel_to_string : keeper_cycle_channel -> string

(** Strict inverse of {!channel_to_string}; [None] for any non-canonical
    string (legacy "reactive"/"proactive", "heartbeat" status-tick, …). *)
val channel_of_string : string -> keeper_cycle_channel option

(** Whether a typed channel represents an autonomous (scheduled) cycle. *)
val is_autonomous : keeper_cycle_channel -> bool

(** Extract all reasons as flat string tags from a verdict.
    Tags map 1:1 to the typed reasons carried by the verdict and do not
    include variant payloads. *)
val verdict_reasons_to_strings : turn_verdict -> string list

type keeper_cycle_decision = {
  should_run : bool;
  channel : keeper_cycle_channel;
  verdict : turn_verdict;
  since_last_scheduled_autonomous : int option;
}

type board_signal_match = {
  explicit_mention : bool;
  matched_targets : string list;
}

(** Collect recent board activity within the keeper's heartbeat window.
    Returns [(events, new_post_count, mention_count)].
    Used by both the world observation builder and the deliberation triage
    in keepalive to populate board-related triggers. *)
val collect_board_events :
  base_path:string ->
  meta:Keeper_meta_contract.keeper_meta ->
  pending_board_event list * int * int

val collect_board_events_without_advancing_cursor :
  base_path:string ->
  meta:Keeper_meta_contract.keeper_meta ->
  pending_board_event list * int * int

val board_signal_match :
  meta:Keeper_meta_contract.keeper_meta ->
  signal:Board_dispatch.board_signal ->
  board_signal_match

val board_signal_wake_reason :
  meta:Keeper_meta_contract.keeper_meta ->
  signal:Board_dispatch.board_signal ->
  Keeper_world_observation_board_signal.wake_reason option
  Keeper_world_observation_board_signal.board_read

(** RFC-0266: build the actionable [pending_board_event] for a completed async
    [masc_fusion] deliberation. Surfaces the sink's board result as a just-arrived
    event so the woken turn can inspect it as neutral Board context.
    [board_post_id = ""] falls back to a synthetic [fusion-run:<id>] post id. *)
val pending_board_event_of_fusion_completion :
  meta:Keeper_meta_contract.keeper_meta ->
  arrived_at:float ->
  Keeper_event_queue.fusion_completion ->
  pending_board_event

(** RFC-0290: build the actionable [pending_board_event] for a completed
    background job. Mirrors {!pending_board_event_of_fusion_completion}: the
    synthetic System_post event wakes the keeper with the job outcome.
    [bg_board_post_id = ""] falls back to a synthetic [bg-run:<id>] post id. *)
val pending_board_event_of_bg_job_completion :
  meta:Keeper_meta_contract.keeper_meta ->
  arrived_at:float ->
  Keeper_event_queue.bg_job_completion ->
  pending_board_event

(** Build the actionable observation for a direct scheduled keeper wake. *)
val pending_board_event_of_scheduled_wake :
  meta:Keeper_meta_contract.keeper_meta ->
  arrived_at:float ->
  Keeper_event_queue.scheduled_wake ->
  pending_board_event

(** Build the actionable observation for a connector-recorded external
    attention item. Mention state and connector coordinates remain context
    fields; they do not grant instruction authority. *)
val pending_board_event_of_external_attention :
  meta:Keeper_meta_contract.keeper_meta ->
  Keeper_external_attention.item ->
  pending_board_event

val apply_failure_judgment_guidance :
  post_id:string ->
  judge_runtime_id:string ->
  guidance:string ->
  rationale:string ->
  pending_board_event list ->
  (pending_board_event list, string) result
(** Replace exactly one matching [Failure_judgment] observation with the
    independent judge's canonical resume verdict. The full structured verdict
    remains observational data, while the typed control path decides whether
    the action turn is allowed. Missing or duplicate observations are explicit
    errors. *)

(** Convert a queued Event Layer stimulus back into structured board activity
    for the next keeper prompt. [Board_signal], [Fusion_completed] (RFC-0266),
    [Bg_completed] (RFC-0290), and [Schedule_due] produce [Some];
    [Bootstrap] returns [None] (no prompt injection). *)
val pending_board_event_of_stimulus :
  meta:Keeper_meta_contract.keeper_meta ->
  Keeper_event_queue.stimulus ->
  pending_board_event option

val read_scheduled_automation_observation :
  keeper_name:string option ->
  config:Workspace.config ->
  now:float ->
  scheduled_automation_observation

(** Build a world observation from workspace state and keeper metadata.

    Reads workspace backlog, agent list, checkpoint context, economy state,
    and recent board activity.
    All I/O errors are caught and produce safe defaults (0, empty, Normal).

    @param pending_board_events Pre-collected board event summaries for this
      heartbeat, if already fetched during triage
    @param config Workspace configuration for I/O operations
    @param meta Current keeper metadata *)
val observe :
  pending_board_events:pending_board_event list option ->
  config:Workspace.config ->
  meta:Keeper_meta_contract.keeper_meta ->
  world_observation

(** Build the observation used by direct [masc_keeper_msg] turns.

    This intentionally reads durable workspace/task state, including pending
    verification counts, while suppressing transient board/message events and
    cursor updates. Direct operator messages should not advance autonomous
    cursors, inherit unrelated workspace chatter, or synthesize scheduled
    scheduled timer signals, but they must still see the durable work
    signals that drive tool-use contracts. *)
val observe_direct_keeper_msg :
  config:Workspace.config ->
  meta:Keeper_meta_contract.keeper_meta ->
  world_observation

(** Structured work signal present in the observation itself. *)
val actionable_signal_present : world_observation -> bool

val keeper_cycle_decision :
  ?reactive_wake:bool ->
  ?event_queue_triggers:event_queue_trigger list ->
  meta:Keeper_meta_contract.keeper_meta -> world_observation -> keeper_cycle_decision
(** [reactive_wake] (default [false]) marks evaluations triggered by an external
    broadcast wakeup rather than the keeper's own cadence timer. When set, a
    GLOBAL task backlog alone does not drive a turn — this prevents the
    all-keeper stampede on each task release/add. Per-keeper Reactive triggers
    and time-based liveness reasons are unaffected. *)

val should_run_keeper_cycle :
  meta:Keeper_meta_contract.keeper_meta -> world_observation -> bool
