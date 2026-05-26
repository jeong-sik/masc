(** Keeper_tool_disclosure — tool selection, usage tracking, and
    response normalization.

    Extracted from keeper_agent_run.ml as part of #5732 god-module
    split. Helpers for tool usage snapshots, delta computation,
    response validation, query text extraction, and tool selection
    boundary merging. *)

(** Snapshot of [(tool_name, count)] from [Keeper_registry] for the
    given keeper, sorted by name. *)
val keeper_tool_usage_snapshot
  :  base_path:string
  -> keeper_name:string
  -> (string * int) list

(** Diff [(tool_name, count)] pairs between [before] and [after],
    returning the tool names invoked during that interval — one
    entry per call. *)
val tool_usage_delta
  :  before:(string * int) list
  -> after:(string * int) list
  -> string list

(** Merge provider hook-observed tool names with registry-observed
    deltas. The hook path is the most direct runtime signal, while
    registry deltas are retained for tools that only update the
    keeper registry. Duplicate sources are combined by max count per
    tool instead of double-counting the same execution. *)
val merge_observed_tool_names
  :  registry_observed_tool_names:string list
  -> hook_observed_tool_names:string list
  -> string list

(** Merge model-reported tool names with provider-observed ones.
    When [observed_tool_names] is non-empty it dominates the head
    of the result; reported-only tails are appended. *)
val merge_reported_and_observed_tool_names
  :  reported_tool_names:string list
  -> observed_tool_names:string list
  -> string list

(** Merge reported/observed tool names after public-name canonicalization
    (via [Keeper_tool_alias.route]) and filter to the keeper's canonical
    [allowed_tool_names]. The allowlist may contain either LLM-visible
    aliases (e.g. [Execute]) or internal handler names (e.g. [keeper_bash]). *)
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

(** Names called by the model that are NOT on the keeper's allowed
    surface (deduped, order preserving). [allowed_tool_names] is
    canonicalized before comparison so runtime-reported internal
    handler names can satisfy a public alias surface. *)
val unexpected_tool_names
  :  allowed_tool_names:string list
  -> tool_names:string list
  -> string list

(** [true] iff at least one entry in [tool_names] is absent from
    [unexpected_tool_names] — i.e. some call lands on the keeper
    surface. Used by the partial-tolerance WARN path (#8471). *)
val has_valid_tool_call
  :  unexpected_tool_names:string list
  -> tool_names:string list
  -> bool

(** Keep [text] when non-blank; otherwise synthesize a
    "Completed without a textual reply. Tools used: ..." line if
    [tool_names] is non-empty, else error. *)
val normalize_response_text
  :  text:string
  -> tool_names:string list
  -> unit
  -> (string, string) result

(** [true] when a provider response carries usable keeper progress for
    cascade accept/reject: non-blank text, ToolUse, or a non-terminal
    stop reason. Empty [end_turn] responses are rejected so cascade can
    try the next candidate instead of failing later as "no textual reply". *)
val response_has_text_or_tool_progress : Agent_sdk.Types.api_response -> bool

(** Project a user-message text to the BM25 query text by keeping
    only the world-state header and a curated set of subsections. *)
val tool_query_text_of_user_message : string -> string

(** Case-insensitive substring matching: [true] iff any of
    [needles] occurs in [text]. *)
val contains_any_ci : string -> string list -> bool

(** Code-context needles used by [contains_code_path_hint] and
    code-search/read/symbol query gates. *)
val code_context_needles : string list

val contains_code_path_hint : string -> bool
val query_requests_code_search : string -> bool
val query_requests_code_read : string -> bool
val query_requests_code_symbols : string -> bool

(** Allow a deterministic-prefilter tool only when the user's
    [query_text] passes the corresponding code-* gate; everything
    else passes through unchanged. *)
val allow_deterministic_tool : query_text:string -> string -> bool

(** Deterministic BM25 prefilter — pull tools from [search_index]
    that are NOT in [core], pass [allow_deterministic_tool], and
    cap at [selection_limit]. *)
val deterministic_prefilter_names
  :  search_index:Agent_sdk.Tool_index.t
  -> query_text:string
  -> selection_limit:int
  -> core:string list
  -> string list

(** Merge the four tool selection layers (core /
    deterministic_prefilter / discovered / llm_selected) into a
    single ordered, deduped list. BM25-relevant tools are placed
    ahead of generic core to survive downstream max_tools
    truncation. *)
val merge_tool_selection_boundary
  :  core:string list
  -> deterministic_prefilter:string list
  -> llm_selected:string list
  -> discovered:string list
  -> string list

(** Proactive contract enforcement — when a keeper has accumulated
    [passive_streak] >= [streak_threshold] consecutive passive turns AND
    there is an [actionable_signal] (unclaimed tasks, board activity, or
    discovered work), strip [Passive_status] tools from the surface so the
    model is forced toward Execution or Completion tools.

    Completion tools (stay_silent, release, done, etc.) are never stripped
    because they are the keeper's intentional exit valve. *)
val contract_enforcement_filter
  :  passive_streak:int
  -> streak_threshold:int
  -> actionable_signal:bool
  -> string list
  -> string list
