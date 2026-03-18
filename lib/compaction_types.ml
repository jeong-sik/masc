(** Compaction_types — Shared compaction strategy type.

    Single source of truth for the compaction strategy variant used by both
    [Context_manager] and [Context_compact_oas]. Extracted to break the
    type duplication between these modules.

    @since 2.111.0 — M1 shared type extraction *)

(** Compaction strategies applied in order during context reduction.

    - [PruneToolOutputs]: truncate verbose tool results (keep first/last 100 chars)
    - [MergeContiguous]: collapse consecutive same-role messages
    - [DropLowImportance]: remove messages scoring below threshold (0.3)
    - [SummarizeOld]: compress oldest messages into a summary *)
type compaction_strategy =
  | PruneToolOutputs
  | MergeContiguous
  | DropLowImportance
  | SummarizeOld
