(** Keeper_world_observation — Structured world state for keeper cycles.

    Extracts and normalizes observation signals from workspace state, keeper meta,
    and context so the unified prompt builder and turn runner can consume
    a single coherent snapshot instead of re-reading scattered sources.

    @since Unified Keeper Loop *)

(** Structured event observations delivered to keepers without routing
    heuristics. The historical carrier includes Board, schedule, goal, and
    completion-authority records; typed partition helpers decide placement. *)
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
  | Board_vote_cast of Board_dispatch.board_vote_change
      (** A vote landed on a post or comment this Keeper wrote. Payload-carrying
          like {!Completion_authority_rejected}: the voter and direction are the
          fact the row states, and [post_id] is the post the vote belongs to
          (the parent post for a comment vote). *)
  | Fusion_completed
  | Delegate_completed
  | Ask_answered_row
      (** A human answered a question this Keeper asked. Like
          {!Composition_completed} the row carries the answer itself: the
          asker has nowhere else to read it mid-cycle, and a wake with no
          content is a wake it cannot act on. *)
  | Composition_completed
      (** A turn this Keeper asked another Keeper to run has ended. Like
          {!Fusion_completed} the row carries the answer itself, because the
          asker has nowhere else to read it mid-cycle. *)
  | Schedule_due of Keeper_event_queue.scheduled_wake
      (** The consumed wake, kept typed. The exact occurrence key is
          [(schedule_id, due_at, payload_digest)]; [schedule_id] alone can point
          at a later recurring or updated request. The flat [title] and
          [preview] fields of {!pending_board_event} are a rendering of the
          wake, not its only copy. Carrying the record mirrors
          {!Keeper_event_queue.Connector_attention}'s pointer discipline and
          {!Completion_authority_rejected}'s payload-carrying shape below. *)
  | External_attention of Keeper_counterpart_observation.t
      (** A typed projection of the host-authored connector identity and the
          untrusted speaker content. Unlike the flat event preview, it keeps
          identity visible in the current Keeper prompt. The Librarian reads
          the same producer-owned attention record through its bounded durable
          projection. *)
  | Completion_authority_rejected of Keeper_event_queue.completion_authority_rejection
      (** A system LLM completion authority rejected this Keeper's evidence. *)
  | Task_cancelled of Keeper_event_queue.task_cancellation
      (** Another Keeper cancelled a Task this Keeper authored. Payload-carrying
          like {!Completion_authority_rejected}: the canceller's reason is the
          author's only account of why the work it asked for stopped, and the
          flat [title]/[preview] fields are a rendering of it, not its only
          copy. *)

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

(** [false] for a scheduled-work or system-authority carrier that shares the
    historical observation container but must not be projected as Board activity.

    This partition decides prompt placement, contributes to Owner turn selection,
    and feeds the classifier. {!Keeper_unified_prompt} renders only
    [is_scheduled_automation_event] events under Scheduled Automation,
    [is_completion_authority_rejection_event] events under their own completion
    authority layer, and the [true] events under Board Activity.
    {!Keeper_contract_classifier} counts only the [true] ones into
    [board_activity_count].

    Admission depends on the event kind. A consumed [Schedule_due] stimulus
    carries its own trigger:
    [Keeper_heartbeat_stimulus_intake.event_queue_trigger_of_stimulus] maps
    it to [Scheduled_automation_stimulus] independently of this partition
    ([scheduled_automation.due_ready_count] is a separate live-store
    observation, not the stimulus's trigger; it can already be zero once
    dispatch begins).

    A new event kind placed on the wrong side compiles cleanly and fails
    silently. Classify by its source contract and pin the answer in a test. *)
val is_board_activity_event : pending_board_event -> bool

val is_scheduled_automation_event : pending_board_event -> bool

val is_completion_authority_rejection_event : pending_board_event -> bool

val is_task_cancellation_event : pending_board_event -> bool
(** A cancellation of a Task this Keeper authored. Disjoint from the Board
    Activity and Scheduled Automation predicates: it has no Board post to point
    at and no schedule behind it. *)

(** Read-only projection of one schedule row that needs keeper attention. *)
type scheduled_automation_item = {
  schedule_id : string;
  action : string;
  status : string;
  payload_kind : string option;
  recurrence_summary : string;
  due_at : float;
}

(** Durable scheduled-automation summary from the MASC schedule store. *)
type scheduled_automation_observation = {
  active_count : int;
  due_ready_count : int;
  next_due_at : float option;
  items : scheduled_automation_item list;
}

val empty_scheduled_automation_observation : scheduled_automation_observation

(** One exact Gate request that is still pending for this Keeper. The
    observation deliberately omits the effect input: current-state
    reconciliation needs the approval identity and scope, not another copy of
    potentially large or sensitive arguments. *)
type pending_approval_observation = {
  approval_id : string;
  tool_name : string;
  sequence : int;
  requested_at : float;
  task_id : string option;
  goal_id : string option;
}

(** Whether the pending-approval projection is complete. [Partial] and
    [Unavailable] are distinct from a readable empty result: neither permits a
    Keeper to infer that an approval mentioned in history has resolved. *)
type approval_authority_state =
  | Approval_authority_complete
  | Approval_authority_partial of { read_error_count : int }
  | Approval_authority_unavailable

type approval_authority_observation = {
  revision : int;
  state : approval_authority_state;
  pending : pending_approval_observation list;
}

val read_approval_authority_observation :
  config:Workspace.config ->
  meta:Keeper_meta_contract.keeper_meta ->
  approval_authority_observation
(** Read the current durable Gate authority for one Keeper. A complete empty
    [pending] list is affirmative current state, not an omitted observation.
    Storage failures remain typed instead of collapsing to zero. *)

(** Snapshot of the world as seen by a keeper at heartbeat time. *)
type world_observation = {
  pending_messages : Keeper_world_observation_message_scope.pending_message list;
  (** Unacknowledged mention/scope rows in durable source order. *)

  pending_board_events : pending_board_event list;
  (** Structured event observations needing triage. The field name is retained
      as the existing world-observation carrier; event kinds remain typed and
      are partitioned before prompt rendering. *)

  idle_seconds : int;
  (** Seconds since last keeper activity (turn or scheduled autonomous cycle). *)

  active_goals : string list;
  (** Goal IDs currently assigned to this keeper. *)

  unclaimed_task_count : int;
  (** Number of unclaimed tasks in the workspace backlog. *)

  claimable_tasks : Keeper_world_observation_inputs.claimable_task_identity list;
  held_task_skills : Keeper_world_observation_inputs.held_task_skills list;
      (** Skills named by the other tasks this keeper holds, off the same
          backlog read as the counts (task-364). *)
  (** Typed identities of the tasks this keeper can claim with its current tool
      surface, from the same authoritative backlog read as
      [unclaimed_task_count]. *)

  failed_task_count : int;
  (** Number of failed/cancelled tasks in the workspace backlog. *)

  scheduled_automation : scheduled_automation_observation;
  (** Durable schedule-store state that needs keeper attention, such as due
      requests ready to dispatch. *)

  approval_authority : approval_authority_observation;
  (** Current pending-approval authority, re-read for every direct or
      autonomous turn. This is the typed current-state counterpart to
      historical chat instructions that mention an approval. *)

  backlog_revision : int option;
  (** The backlog commit revision observed through the recovery-backed read.
      [None] means neither primary nor recovery was a valid current backlog;
      callers must not interpret the accompanying zero counts as an observed
      empty backlog. *)

  running_keeper_fiber_count : int;
  (** Number of live keeper fibers for this workspace base path. *)

  connected_surfaces : Gate_surface.surface_presence list;
  (** Connector surfaces attached to this keeper (RFC-0223 P2).
      Recomputed from binding stores + connector liveness on every
      observation; the dashboard entry is always present. Presence
      only — no conversation content, no counts. *)

  connected_surface_failures : Gate_surface.presence_failure list;
  (** Connector binding stores that could not be read during presence
      observation. Healthy connector surfaces remain available. *)

  own_recent_board_posts : Board.post list;
  (** The keeper's own latest board posts, newest first, bounded by
      [Keeper_config.keeper_board_own_recent_max]. Cursor-independent:
      [pending_board_events] tracks OTHER authors' unseen posts and advances
      past them, so without this field a keeper never observes its own
      published posts in-prompt. Raw observation only — no dedup gate. *)

  fleet_messages : Keeper_world_observation_message_scope.fleet_message list;
  (** Keeper broadcasts projected into this transcript, newest
      [Keeper_config.keeper_fleet_messages_max] in arrival order. Standing
      context with no acknowledgement cursor: the reactive lanes admit only
      rows addressed to this keeper, so a projected broadcast would otherwise
      reach the dashboard and never the prompt. Disjoint from
      [pending_messages] by construction. *)

  own_recent_actions : Keeper_own_recent_actions.turn list;
  (** This keeper's own tool calls from its newest
      [Keeper_config.keeper_own_recent_turns_max] turns, oldest turn first,
      each turn's calls in the order they ran. An autonomous turn otherwise
      carries no record of what this keeper already did, so a finished task
      gets claimed again and a rejected call gets repeated. *)
}

val claimable_task_count : world_observation -> int
(** The exact derived count of [claimable_tasks]. It is not stored separately,
    so count and rows cannot represent different snapshots. *)

type keeper_cycle_channel =
  | Reactive
  | Scheduled_autonomous

type event_queue_trigger =
  | Bootstrap_stimulus
  | Scheduled_automation_stimulus
  | Connector_attention_stimulus
  | Ask_answered_stimulus
  | Hitl_resolved_stimulus
  | Completion_authority_rejection_stimulus
  | Task_cancellation_stimulus
  | Workspace_message_stimulus

(** Typed reason for running a keeper cycle. Each variant corresponds to
    exactly one code path in {!keeper_cycle_decision}. *)
type turn_reason =
  | Mention_pending
  | Board_event_pending
  | Scope_message_pending
  | Bootstrap_stimulus_pending
  | Connector_attention_pending
  | Ask_answered_pending
  | Hitl_resolved_pending
  | Completion_authority_rejection_pending
  | Task_cancellation_pending
  | Workspace_message_pending
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

(** Collect board activity after the keeper's durable cursor. A keeper without
    a cursor starts at the beginning of Board history; no time window may hide
    undelivered posts.
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

(** RFC-0266: build the actionable [pending_board_event] for a completed async
    [masc_fusion] deliberation. Surfaces the sink's board result as a just-arrived
    event so the woken turn can inspect it as neutral Board context.
    [board_post_id = ""] falls back to a synthetic [fusion-run:<id>] post id. *)
val pending_board_event_of_fusion_completion :
  meta:Keeper_meta_contract.keeper_meta ->
  arrived_at:float ->
  Keeper_event_queue.fusion_completion ->
  pending_board_event

(** Build the actionable observation for a direct scheduled keeper wake. *)
val pending_board_event_of_scheduled_wake :
  meta:Keeper_meta_contract.keeper_meta ->
  post_id:Keeper_event_queue.post_id ->
  arrived_at:float ->
  Keeper_event_queue.scheduled_wake ->
  pending_board_event

(** Build the actionable observation for a connector-recorded external
    attention item. Mention state and connector coordinates remain context
    fields; they do not grant instruction authority. *)
val pending_board_event_of_ask_answer :
  meta:Keeper_meta_contract.keeper_meta ->
  ask:Keeper_ask.ask ->
  answers:Keeper_ask.answer list ->
  responder:Keeper_ask.responder ->
  answered_at:float ->
  pending_board_event
(** The answer to a question this Keeper asked, as a row the turn can act on.
    Choice ids are resolved to their labels, so the Keeper reads what the
    human picked rather than an opaque identity. *)

val pending_board_event_of_external_attention :
  meta:Keeper_meta_contract.keeper_meta ->
  Keeper_external_attention.item ->
  pending_board_event

(** Convert a queued Event Layer stimulus into structured turn activity
    for the next keeper prompt. [Board_signal], [Fusion_completed] (RFC-0266),
    and [Schedule_due] produce [Some];
    [Bootstrap] returns [None] (no prompt injection).
    [Error unavailable] means the underlying board read for [Board_signal] /
    [Board_attention] failed (board-unavailable-result). Callers classify via
    {!Keeper_world_observation_board_signal.disposition_of_unavailable} and
    decide whether to drop or retain the stimulus — this function only
    reports the read failure, it does not decide. *)
val pending_board_event_of_stimulus :
  meta:Keeper_meta_contract.keeper_meta ->
  Keeper_event_queue.stimulus ->
  (pending_board_event option, Keeper_world_observation_board_signal.board_unavailable) result

(** Build a world observation from workspace state and keeper metadata.

    Reads workspace backlog, agent list, checkpoint context, and recent
    board activity.
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

(** Whether the observation contains actual Board-compatible activity.
    A [Schedule_due] work request is actionable but is not Board activity. *)
val has_pending_board_activity : world_observation -> bool

val keeper_cycle_decision :
  ?event_queue_triggers:event_queue_trigger list ->
  meta:Keeper_meta_contract.keeper_meta -> world_observation -> keeper_cycle_decision
