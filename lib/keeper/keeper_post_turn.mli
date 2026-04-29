(** Keeper_post_turn — post-turn lifecycle: compaction, handoff
    rollover, continuity summary, and overflow retry recovery.

    Orchestrates the end-of-turn pipeline that decides whether to
    compact the context, roll over to a new generation, and update
    the continuity summary from the latest state snapshot.

    This module owns only the checkpoint/lineage tail of a keeper
    turn. Memory bank append, episode flush, and Hebbian learning
    are recorded elsewhere:
    - memory bank / episodes: [Keeper_agent_run] tail after [Agent.run]
    - hebbian: task lifecycle in [Coord_task]

    Extracted from Keeper_exec_context as part of #4955 god-file split. *)

(** Outcome of the compaction step. [applied] iff a compaction
    strategy actually ran; [trigger] is the gate label that fired
    ([ratio]/[messages]/[tokens]/[tool_heavy]). *)
type compaction_event =
  { attempted : bool
  ; applied : bool
  ; failure_reason : string option
  ; trigger : string option
  ; decision : Keeper_compact_policy.compaction_decision
  ; before_tokens : int
  ; after_tokens : int
  ; saved_tokens : int
  }

(** Combined post-turn outcome — compaction + rollover + continuity
    summary update + per-turn context metrics. *)
type post_turn_lifecycle =
  { updated_meta : Keeper_types.keeper_meta
  ; checkpoint : Oas.Checkpoint.t option
  ; handoff_json : Yojson.Safe.t option
  ; handoff_attempted : bool
  ; handoff_failure_reason : string option
  ; compaction : compaction_event
  ; turn_generation : int
  ; context_ratio : float
  ; context_tokens : int
  ; context_max : int
  ; message_count : int
  }

(** Recovered checkpoint + applied compaction event used by the
    overflow-retry flow to restart the turn from a smaller context.

    [@@warning "-69"]: declared in the .ml because not every field
    is read at the call site, but the record is exported so callers
    can match exhaustively. *)
type overflow_retry_recovery =
  { checkpoint : Oas.Checkpoint.t
  ; compaction : compaction_event
  ; turn_generation : int
  } [@@warning "-69"]

(** End-of-turn pipeline. Decides compaction, rolls over generations
    when the handoff gate fires, refreshes the continuity summary
    from the latest state snapshot, and persists the result to the
    keeper meta + dashboard surface.

    {b Tier A5} (Cycle 22): when the [MASC_AUTONOMOUS] environment
    variable is on (see {!Autonomous.Wirein_helpers.masc_autonomous_enabled}),
    the resulting [post_turn_lifecycle.checkpoint]'s working_context
    is enriched with an ["autonomous_meta"] sub-tree carrying the
    suspended {!Autonomous_bridge} state. Off-mode behaviour is
    unchanged (zero impact). *)
val apply_post_turn_lifecycle :
  on_compaction_started:(unit -> unit) ->
  on_handoff_started:(unit -> unit) ->
  base_dir:string ->
  meta:Keeper_types.keeper_meta ->
  model:string ->
  primary_model_max_tokens:int ->
  current_turn_overflow_blocker:string option ->
  checkpoint:Oas.Checkpoint.t option ->
  post_turn_lifecycle

(** Build the relaxed-policy meta used during forced overflow
    retry: zero compaction gates so the next compaction always
    fires. *)
val forced_overflow_retry_meta :
  Keeper_types.keeper_meta ->
  turn_generation:int ->
  now_ts:float ->
  Keeper_types.keeper_meta

(** Reload the latest OAS / legacy checkpoint and apply forced
    compaction so the turn can retry from a smaller context.
    Returns [None] when no checkpoint exists, when compaction did
    not actually shrink the token count, or when the recovery save
    failed. *)
val recover_latest_checkpoint_for_overflow_retry :
  base_dir:string ->
  meta:Keeper_types.keeper_meta ->
  model:string ->
  primary_model_max_tokens:int ->
  overflow_retry_recovery option
