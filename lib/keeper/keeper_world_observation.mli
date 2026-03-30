(** Keeper_world_observation — Structured world state for unified keeper turns.

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
}

(** Snapshot of the world as seen by a keeper at heartbeat time. *)
type world_observation = {
  pending_mentions : (string * string) list;
  (** [(from_agent, content)] pairs of unprocessed direct mentions. *)

  pending_board_events : pending_board_event list;
  (** Structured board events needing triage. *)

  idle_seconds : int;
  (** Seconds since last keeper activity (turn or proactive). *)

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

  failed_task_count : int;
  (** Number of failed/cancelled tasks in the room backlog. *)

  active_agent_count : int;
  (** Number of agents currently active in the room. *)

}

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

(** Build a world observation from room state and keeper metadata.

    Reads room backlog, agent list, checkpoint context, economy state,
    and recent board activity.
    All I/O errors are caught and produce safe defaults (0, empty, Normal).

    @param pending_board_events Pre-collected board event summaries for this
      heartbeat, if already fetched during triage
    @param config Room configuration for I/O operations
    @param meta Current keeper metadata *)
val observe :
  pending_board_events:pending_board_event list option ->
  config:Room.config ->
  meta:Keeper_types.keeper_meta ->
  world_observation

val should_run_unified_turn :
  meta:Keeper_types.keeper_meta -> world_observation -> bool
