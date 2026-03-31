(** Keeper-private compaction strategies.

    These strategies are used only by keeper's destructive compaction path
    (keeper_exec_context.ml). They are NOT exposed as public
    Context_compact_oas.strategy variants.

    @since keeper-lossy-fold *)

(** Create a lossy fold strategy that compresses completed subtask turns
    into structured stubs. More informative than SummarizeOld.

    The strategy uses OAS [Context_reducer.Custom] internally.
    Fold is lossy (no unfold) since keeper compaction is destructive —
    compacted messages are persisted to checkpoint.

    [keep_recent] turns are preserved unchanged (default 10). *)
val fold_completed_strategy :
  ?keep_recent:int ->
  unit ->
  Agent_sdk.Context_reducer.t
