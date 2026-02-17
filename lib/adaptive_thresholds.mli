(** Adaptive Thresholds -- EMA-based threshold learning from handoff outcomes.

    Learns optimal prepare/handoff context thresholds by observing handoff
    quality signals ({!Handoff_quality.handoff_outcome}). After each handoff,
    thresholds are adjusted toward values that produce better outcomes.

    {2 Safety bounds}

    Thresholds are strictly clamped:
    - [0.20 <= prepare < handoff <= 0.95]
    - Minimum gap between prepare and handoff: 0.15

    {2 Persistence}

    State is persisted per room at [~/.masc/adaptive_thresholds_{room}.json].

    {2 Fallback chain}

    Effective thresholds are resolved in order:
    + Adaptive state (if enabled and state file exists for the room)
    + Environment variables ([MASC_MITOSIS_PREPARE_THRESHOLD],
      [MASC_MITOSIS_HANDOFF_THRESHOLD])
    + Module defaults (prepare=0.50, handoff=0.80)

    @since 0.5.0 *)

(** {1 Types} *)

(** A pair of context usage thresholds for the 2-phase mitosis approach. *)
type thresholds = {
  prepare : float;
      (** Context usage percentage (0.0--1.0) at which to start
          DNA preparation (Phase 1). *)
  handoff : float;
      (** Context usage percentage (0.0--1.0) at which to execute
          the handoff (Phase 2). Must be > [prepare + min_gap]. *)
}

(** Persisted adaptive state for a single room.

    Tracks the current thresholds, how many sessions have contributed
    to adaptation, the cumulative adjustment for the current session,
    and the last update timestamp. *)
type adaptive_state = {
  thresholds : thresholds;
      (** Current learned thresholds. *)
  session_count : int;
      (** Number of handoff outcomes that have been applied. *)
  cumulative_delta : float;
      (** Total threshold adjustment accumulated in this session.
          Used to enforce the per-session cap from
          {!Handoff_quality.max_session_delta}. *)
  last_updated : string;
      (** ISO 8601 timestamp of the last adaptation. *)
}

(** {1 Constants} *)

(** Default thresholds matching {!Mitosis.Defaults}:
    prepare=0.50, handoff=0.80. *)
val default_thresholds : thresholds

(** Minimum allowed prepare threshold. Value: 0.20. *)
val min_prepare : float

(** Maximum allowed handoff threshold. Value: 0.95. *)
val max_handoff : float

(** Minimum gap between prepare and handoff thresholds. Value: 0.15. *)
val min_gap : float

(** {1 Threshold Operations} *)

(** [clamp_thresholds t] constrains [t] to the safety bounds:
    - [handoff] is clamped to [\[min_prepare + min_gap, max_handoff\]]
    - [prepare] is clamped to [\[min_prepare, handoff - min_gap\]]

    Always maintains the minimum gap between prepare and handoff. *)
val clamp_thresholds : thresholds -> thresholds

(** [initial_state ()] creates a fresh adaptive state with
    {!default_thresholds}, zero session count, zero cumulative delta,
    and the current timestamp. *)
val initial_state : unit -> adaptive_state

(** [adapt state outcome] applies a handoff outcome to the adaptive state.

    The handoff threshold receives the full (clamped) delta from
    {!Handoff_quality.compute_adjustment}. The prepare threshold tracks
    proportionally to maintain the historical ratio between prepare and
    handoff. Both thresholds are clamped to safety bounds after adjustment.

    The cumulative delta for the session is updated and caps further
    adjustments when {!Handoff_quality.max_session_delta} is reached. *)
val adapt : adaptive_state -> Handoff_quality.handoff_outcome -> adaptive_state

(** {1 JSON Serialization} *)

(** [state_to_json state] serializes [state] to a JSON object with fields:
    [prepare_threshold], [handoff_threshold], [session_count],
    [cumulative_delta], [last_updated]. *)
val state_to_json : adaptive_state -> Yojson.Safe.t

(** [state_of_json json] deserializes an adaptive state from JSON.

    @return [Some state] on success (thresholds are clamped during
      deserialization), [None] if required fields are missing or
      have wrong types. *)
val state_of_json : Yojson.Safe.t -> adaptive_state option

(** {1 File Persistence} *)

(** [state_file_path ~room] returns the path to the persistence file:
    [~/.masc/adaptive_thresholds_{room}.json].

    Falls back to [/tmp/.masc/] if [$HOME] is not set. *)
val state_file_path : room:string -> string

(** [save_state ~room state] writes [state] to the persistence file.
    Creates the [~/.masc/] directory if it does not exist. *)
val save_state : room:string -> adaptive_state -> unit

(** [load_state ~room] reads and deserializes the state from the
    persistence file.

    @return [None] if the file does not exist, cannot be read,
      or contains invalid JSON. *)
val load_state : room:string -> adaptive_state option

(** {1 Effective Thresholds} *)

(** [get_effective_thresholds ~enabled ~room] resolves thresholds using
    the fallback chain:
    + If [enabled], try loading adaptive state for [room].
    + Check environment variables [MASC_MITOSIS_PREPARE_THRESHOLD] and
      [MASC_MITOSIS_HANDOFF_THRESHOLD].
    + Fall back to {!default_thresholds}.

    All returned thresholds are clamped to safety bounds. *)
val get_effective_thresholds : enabled:bool -> room:string -> thresholds
