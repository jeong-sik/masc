(** Keeper_tool_observation - runtime tool-call observation and surface
    reconciliation.

    This module owns registry/hook/model-reported tool-name merging and keeper
    surface validation. It is separate from tool disclosure/selection so
    runtime evidence does not live in the prompt-surface module. *)

(** Snapshot of [(tool_name, count)] from [Keeper_registry] for the given
    keeper, sorted by name. *)
val keeper_tool_usage_snapshot
  :  base_path:string
  -> keeper_name:string
  -> (string * int) list

(** Diff [(tool_name, count)] pairs between [before] and [after], returning
    the tool names invoked during that interval - one entry per call. *)
val tool_usage_delta
  :  before:(string * int) list
  -> after:(string * int) list
  -> string list

(** Merge provider hook-observed tool names with registry-observed deltas. The
    hook path is the most direct runtime signal, while registry deltas are
    retained for tools that only update the keeper registry. Duplicate sources
    are combined by max count per tool instead of double-counting the same
    execution. *)
val merge_observed_tool_names
  :  registry_observed_tool_names:string list
  -> hook_observed_tool_names:string list
  -> string list

(** Merge model-reported tool names with provider-observed ones. When
    [observed_tool_names] is non-empty it dominates the head of the result;
    reported-only tails are appended. *)
val merge_reported_and_observed_tool_names
  :  reported_tool_names:string list
  -> observed_tool_names:string list
  -> string list

(** Merge reported/observed tool names after public-name canonicalization and
    filter to the keeper's canonical [allowed_tool_names]. The allowlist may
    contain either LLM-visible aliases (e.g. [Execute]) or internal handler
    names (e.g. [tool_execute]). *)
val final_keeper_tool_names
  :  reported_tool_names:string list
  -> observed_tool_names:string list
  -> allowed_tool_names:string list
  -> string list

(** [true] when a successful tool result should count as material keeper
    progress. Idempotent setup confirmations such as an already-existing task
    worktree remain successful tool calls, but they do not satisfy execution
    progress contracts by themselves. *)
val tool_result_has_material_progress
  :  tool_name:string
  -> output_text:string
  -> bool

(** Names called by the model that are NOT on the keeper's allowed surface
    (deduped, order preserving). [allowed_tool_names] is canonicalized before
    comparison so runtime-reported internal handler names can satisfy a public
    alias surface. *)
val unexpected_tool_names
  :  allowed_tool_names:string list
  -> tool_names:string list
  -> string list

(** [true] iff at least one entry in [tool_names] is absent from
    [unexpected_tool_names] - i.e. some call lands on the keeper surface. Used
    by the partial-tolerance WARN path (#8471). *)
val has_valid_tool_call
  :  unexpected_tool_names:string list
  -> tool_names:string list
  -> bool
