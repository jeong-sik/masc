(** Keeper_world_observation — Structured world state for unified keeper turns.

    Extracts and normalizes observation signals from room state, keeper meta,
    and context so the unified prompt builder and turn runner can consume
    a single coherent snapshot instead of re-reading scattered sources.

    @since Unified Keeper Loop *)

(** Snapshot of the world as seen by a keeper at heartbeat time. *)
type world_observation = {
  pending_mentions : (string * string) list;
  (** [(from_agent, content)] pairs of unprocessed direct mentions. *)

  pending_board_events : string list;
  (** Post IDs of board events needing triage. *)

  idle_seconds : int;
  (** Seconds since last keeper activity (turn or proactive). *)

  active_goals : string list;
  (** Goal IDs currently assigned to this keeper. *)

  autonomy_level : Keeper_autonomy.autonomy_level;
  (** Parsed autonomy level for tool gating. *)

  continuity_summary : string;
  (** Latest continuity snapshot text (empty if unavailable). *)

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

  triage_triggers : string;
  (** Comma-separated triage trigger strings from last deliberation triage. *)
}

(** Build a world observation from room state and keeper metadata.

    Reads room backlog, agent list, checkpoint context, and economy state.
    All I/O errors are caught and produce safe defaults (0, empty, Normal).

    @param config Room configuration for I/O operations
    @param meta Current keeper metadata *)
val observe : config:Room.config -> meta:Keeper_types.keeper_meta -> world_observation
