(** Checkpoint adaptation at one provider attempt's boundary. Replay-prefix
    validation belongs to {!Keeper_replay_prefix}; this module projects the
    attempt result and validates snapshots before the caller's persistence
    callback. It owns no storage, telemetry or provider effects. *)

type t = private
  { turn_result : (Runtime_agent.run_result, Agent_core.Error.t) result
  ; checkpoint_after : Agent_core.Checkpoint.t option
  }

val project :
  ?checkpoint_after:Agent_core.Checkpoint.t ->
  projection:Keeper_replay_prefix.projection ->
  (Runtime_agent.run_result, Agent_core.Error.t) result -> t
(** Pure projection. A successful result's checkpoint and any separately
    produced checkpoint are restored to canonical input. Prefix drift fails
    the turn explicitly; an invalid separate checkpoint is not returned.
    [None] means no valid separate checkpoint was produced. *)

val canonical_sink :
  projection:Keeper_replay_prefix.projection ->
  Agent_core.Agent.checkpoint_sink -> Agent_core.Agent.checkpoint_sink
(** The effect adapter: validate/restore before invoking the supplied sink.
    Invalid snapshots never reach persistence. Stage, turn and timestamp are
    preserved; the supplied sink's result and exceptions propagate unchanged. *)
