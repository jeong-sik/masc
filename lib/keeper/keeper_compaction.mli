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

(** Keywords that each [soul_profile] considers important for retention.
    @since persona-fold *)
val keywords_for_profile : string -> string list

(** Extract up to 3 profile-relevant first-sentence excerpts. *)
val extract_profile_relevant_excerpts :
  soul_profile:string ->
  Agent_sdk.Types.message list ->
  string list

(** Persona-aware lossy fold. Same recency logic as [fold_completed_strategy],
    but stubs include profile-relevant excerpts via [keywords_for_profile].
    @since persona-fold *)
val persona_fold_strategy :
  ?keep_recent:int ->
  soul_profile:string ->
  unit ->
  Agent_sdk.Context_reducer.t
