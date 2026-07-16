(** Deterministic rebase of a compacted checkpoint over live append-only
    Keeper progress.

    The caller supplies only the replacement messages.  The candidate
    checkpoint is constructed from [source] inside this boundary, so
    compaction cannot alter checkpoint identity, metadata, context, usage, or
    turn coordinates. *)

type error =
  | Source_superseded of
      { source_trace_id : Keeper_id.Trace_id.t
      ; source_generation : int
      ; current_trace_id : Keeper_id.Trace_id.t
      ; current_generation : int
      }
  | Current_messages_prefix_mismatch of Keeper_replay_prefix.prefix_mismatch

val rebase
  :  source:Keeper_checkpoint_store.exact_checkpoint_snapshot
  -> compacted_messages:Agent_sdk.Types.message list
  -> current:Keeper_checkpoint_store.exact_checkpoint_snapshot
  -> (Agent_sdk.Checkpoint.t, error) result
(** Returns the source checkpoint with [compacted_messages] when the source
    and current snapshot references are identical.

    For a later checkpoint in the same trace and generation, [source.messages]
    must be an exact structural prefix of [current.messages].  The exact live
    suffix is appended to [compacted_messages], while every other field comes
    from [current].

    Checkpoints and their references arrive as one exact snapshot type, so a
    mismatched pair is not representable.  Diverged lineage and prefix
    mismatches fail explicitly.  No serialization, semantic matching, size
    threshold, or time heuristic is used. *)
