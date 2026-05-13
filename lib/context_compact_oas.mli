(** Context_compact_oas — context-window compaction strategies
    for OAS message lists.

    Wraps {!Agent_sdk.Context_reducer} with MASC-specific strategies
    (tool-output pruning, contiguous-message merging,
    low-importance dropping, summarization) plus a {!Dynamic}
    runtime selector for adaptive policies based on
    {!observation_context}.

    Internal: 5 \[*_prefix\] string constants (memory summary /
    goal markers + legacy variants), 9 scoring weights cached
    from env at module init ([w_recency], [w_role], [w_tool],
    role weights, tool-presence weights, [anchor_boost],
    [drop_importance_threshold], [summarize_keep_recent]),
    \[tool_output_prune_limit\] env constant, 4 dynamic-context
    thresholds, [first_sentence] / [summarize_chunk] /
    [extractive_summarizer] / [score_message] / [score_messages] /
    [oas_strategy_of] helpers — all consumed only inside
    {!compact}'s pipeline. *)

(** {1 Observation context} *)

type observation_context = {
  context_ratio : float;
      (** [\[0.0, 1.0\]] — current context window utilization. *)
  active_agent_count : int;
      (** Agents currently active in the room. *)
  unclaimed_task_count : int;
      (** Pending tasks in the backlog. *)
  is_single_focused_task : bool;
      (** Keeper working on exactly one task. *)
  context_window : int;
      (** Model context window in tokens. *)
  is_local_model : bool;
      (** Whether model runs locally. *)
}
(** Snapshot of room / model conditions used by {!Dynamic}
    strategies to choose concrete sub-strategies at runtime.
    Concrete record because callers (notably
    {!Keeper_compact_policy}) construct it field-by-field. *)

(** {1 Strategy variants} *)

(** Compaction strategies.  {!Dynamic} carries a callback that
    returns concrete strategies based on observation context —
    {!resolve_strategies} flattens nested {!Dynamic} into the
    base 4 variants before dispatch. *)
type strategy =
  | PruneToolOutputs
      (** Truncate tool-call result content beyond
          [tool_output_prune_limit]. *)
  | MergeContiguous
      (** Merge adjacent same-role messages into a single
          message. *)
  | DropLowImportance
      (** Drop messages whose composite importance score falls
          below [drop_importance_threshold]. *)
  | SummarizeOld
      (** Replace messages older than [summarize_keep_recent]
          with a single \[MEMORY_SUMMARY\] / \[GOAL\] paragraph. *)
  | Dynamic of (observation_context -> strategy list)
      (** Select strategies at runtime based on observation
          context.  Resolves to a list of concrete strategies
          (no nested [Dynamic]).  @since #3070 *)

(** {1 Public API} *)

val compact :
  messages:Agent_sdk.Types.message list ->
  strategies:strategy list ->
  ?observation:observation_context ->
  unit ->
  Agent_sdk.Types.message list
(** [compact ~messages ~strategies ?observation ()] applies the
    OAS-backed compaction pipeline.  When any [strategy] is {!Dynamic} and
    [?observation] is supplied, runtime resolution flattens it.

    Logs the resolved strategy names + observation summary at
    INFO via {!Log.Compact.info} on every call — used to debug
    "why is keeper context not shrinking" cascades. *)

val resolve_strategies :
  obs:observation_context option ->
  strategy list ->
  strategy list
(** [resolve_strategies ~obs strategies] expands every
    [Dynamic f] into its concrete [f obs] result; passes through
    non-Dynamic variants unchanged.  When [obs = None] and a
    [Dynamic] is present, falls back to a default strategy set
    (typically [\[PruneToolOutputs; MergeContiguous\]]). *)

val strategy_name : strategy -> string
(** [strategy_name s] returns the canonical label.  Pinned
    literals: ["PruneToolOutputs"] / ["MergeContiguous"] /
    ["DropLowImportance"] / ["SummarizeOld"] / ["Dynamic"].
    Used by {!Keeper_compact_policy} to log applied strategies
    and by the .info call in {!compact}. *)

val observation_summary : observation_context option -> string
(** [observation_summary o] renders [o] as a single-line summary
    for log output:

    - [None] returns the literal [obs=none].
    - [Some _] returns formatted key=value pairs covering every
      record field. *)

val score_messages :
  Agent_sdk.Types.message list -> (int * float) list
(** [score_messages msgs] is the SSOT importance scorer used by
    {!DropLowImportance} and {!SummarizeOld}. Returns a list of
    [(index, score)] pairs in the same order as [msgs] with
    [score \in [0.0, 1.0]].

    Composite of recency (quadratic position weight), role
    (system / user / assistant / tool weights), tool-call
    presence, and an anchor boost for messages prefixed with
    \[MEMORY_SUMMARY\] / \[GOAL\] (current + legacy markers).
    Pure — reads only the cached env-derived weights. *)

val small_local_ctx_floor : int
(** Context-window threshold below which {!default_dynamic_selector}
    classifies a local model as "small" and switches to a
    lightweight strategy set. Mirrors
    [Env_config.ContextCompact.small_local_floor]; exposed so
    boundary tests can pin the threshold without duplicating the
    env lookup. *)

val default_dynamic_selector :
  observation_context -> strategy list
(** [default_dynamic_selector obs] is the recommended
    [Dynamic _] callback for keeper compaction policies.
    Branches on observation thresholds:

    - High context utilization + multi-agent room -> aggressive
      pruning ([\[PruneToolOutputs; DropLowImportance;
        MergeContiguous; SummarizeOld\]]).
    - High utilization + single focused task -> moderate
      pruning ([\[PruneToolOutputs; SummarizeOld\]]).
    - Low utilization on small local model -> minimal
      ([\[MergeContiguous\]]).
    - Default -> [\[PruneToolOutputs; MergeContiguous\]]. *)

(** {1 Test-visible scoring helpers} *)

val score_message :
  index:int -> total:int -> Agent_sdk.Types.message -> float
(** [score_message ~index ~total msg] returns the importance score
    of a single message for context compaction.  Score is in
    [0.0, 1.0].  Pinned for behaviour-tests and for injecting into
    OAS {!Agent_sdk.Context_reducer.importance_scored}. *)
