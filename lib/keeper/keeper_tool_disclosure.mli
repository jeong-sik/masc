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

(** Compose [merge_reported_and_observed_tool_names] with public-name
    canonicalization (via [Keeper_tool_alias.route]) and filter to the
    keeper's [allowed_tool_names]. *)
val final_keeper_tool_names
  :  reported_tool_names:string list
  -> observed_tool_names:string list
  -> allowed_tool_names:string list
  -> string list

(** Names called by the model that are NOT on the keeper's allowed
    surface (deduped, order preserving). *)
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

(** Required-tool contract carried per turn / per run. *)
type completion_contract =
  | Allow_text_or_tool
  | Require_tool_use

(** Monotonic merge — once [Require_tool_use] enters either side,
    the result is [Require_tool_use]. *)
val merge_completion_contract
  :  previous:completion_contract
  -> current:completion_contract
  -> completion_contract

(** Map an [Agent_sdk.Types.tool_choice option] to the corresponding
    [completion_contract] (#8696: exhaustive match against
    [Agent_sdk.Types.tool_choice] so SDK drift is caught at compile time). *)
val completion_contract_of_tool_choice
  :  Agent_sdk.Types.tool_choice option
  -> completion_contract

(** Combine a per-turn contract with the run-level
    [required_tool_use_seen] flag — once [true], the run becomes
    [Require_tool_use]. *)
val run_completion_contract
  :  turn_contract:completion_contract
  -> required_tool_use_seen:bool
  -> completion_contract

(** Validate a turn's [contract] given whether any keeper-surface
    tool was called. *)
val validate_completion_contract_presence
  :  contract:completion_contract
  -> tool_present:bool
  -> (unit, string) result

(** Validate a turn's [contract] given the list of called tool
    names (non-empty list satisfies [Require_tool_use]). *)
val validate_completion_contract
  :  contract:completion_contract
  -> tool_names:string list
  -> unit
  -> (unit, string) result

(** Tool progress class — shared contract between prompt
    disclosure, required-tool validation, runtime receipts, and
    liveness metrics. *)
type tool_progress_class =
  | Passive_status
  | Claim_context
  | Execution
  | Completion

val tool_progress_class_to_string : tool_progress_class -> string

(** Canonicalize a tool name via [Keeper_tool_alias]. *)
val canonical_tool_name : string -> string

(** Canonical names of claim-context tools (Task_claim, Claim_next,
    Claim_task). *)
val claim_context_tool_names : string list

(** Canonical names of completion tools (Task_done variants,
    Stay_silent, Cancel_task, etc.). *)
val completion_tool_names : string list

val is_claim_tool_name : string -> bool
val is_claim_context_tool_name : string -> bool
val is_completion_tool_name : string -> bool

(** [true] iff the tool name represents a non-read-only effect
    (Masc_coordination / Playground_write / Main_worktree_write). *)
val tool_name_can_satisfy_required_contract : string -> bool

(** Validate that an observed tool call actually mutates state —
    used by the run contract to reject read-only calls under
    [Require_tool_use]. *)
val required_tool_satisfaction
  :  Agent_sdk.Completion_contract.tool_call
  -> (unit, string) result

(** Variant of [required_tool_satisfaction] for an explicit
    [required_tools] contract. A read-only tool can satisfy the turn only when
    the operator/task contract named that exact tool; generic required-tool
    gates remain mutating-only. *)
val required_tool_satisfaction_for_required_names
  :  required_tool_names:string list
  -> Agent_sdk.Completion_contract.tool_call
  -> (unit, string) result

(** Project a tool name to its [tool_progress_class]. *)
val classify_tool_progress : string -> tool_progress_class

val is_passive_status_tool_name : string -> bool
val is_execution_progress_tool_name : string -> bool

(** Increment the [keeper_require_tool_use_violations] Prometheus
    counter with [keeper] / [has_current_task] / [contract_status]
    labels. *)
val record_require_tool_use_violation
  :  keeper_name:string
  -> has_current_task:bool
  -> contract_status:string
  -> unit

(** Build an actionable contract-violation reason describing why
    the keeper failed [Require_tool_use], or [None] when the
    actionable signal context does not apply. *)
val actionable_tool_contract_violation_reason
  :  claim_context_allowed:bool
  -> actionable_signal_context:bool
  -> tool_names:string list
  -> string option

(** Keep [text] when non-blank; otherwise synthesize a
    "Completed without a textual reply. Tools used: ..." line if
    [tool_names] is non-empty, else error. *)
val normalize_response_text
  :  text:string
  -> tool_names:string list
  -> unit
  -> (string, string) result

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
