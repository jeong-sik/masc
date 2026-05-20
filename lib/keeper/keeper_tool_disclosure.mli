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
    aliases (e.g. [Bash]) or internal handler names (e.g. [keeper_bash]). *)
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

(** Pure canonicalisation — no telemetry side-effect.

    Used by set-logic call sites (required-tool canonicalisation, surface
    composition, satisfaction checks) where every invocation should NOT
    count as an observation event. *)
val canonical_tool_name : string -> string

(** Observation-emitting canonicalisation.

    Emits exactly one [masc_keeper_tool_call_total] sample with bounded
    [tool] / [routed_to] / [result] labels. Use only at the keeper turn
    observation boundary (e.g. canonicalising LLM-reported tool calls in
    [Keeper_agent_run]). Non-observation call sites should use
    [canonical_tool_name] to avoid double-counting. *)
val canonical_tool_name_observed : string -> string

(** Return a model-facing correction when a tool call uses a keeper-internal
    implementation name whose public alias is the supported LLM surface. *)
val public_alias_guidance_for_internal_call
  :  visible_tool_names:string list -> string -> string option

(** Canonical names of claim-context tools (Task_claim, Claim_next). *)
val claim_context_tool_names : string list

(** Canonical names of completion tools (Task_done variants,
    Stay_silent, Cancel_task, etc.). *)
val completion_tool_names : string list

val is_claim_tool_name : string -> bool
val is_claim_context_tool_name : string -> bool
val is_completion_tool_name : string -> bool

(** [true] iff the tool name represents productive execution progress for a
    required-action gate. Completion tools are exempted even when read-only;
    passive keeper observation tools remain [false] here so liveness metrics
    and surface trimming keep treating them as passive. *)
val tool_name_can_satisfy_required_contract : string -> bool

(** Validate an observed generic [Require_tool_use] call. This accepts mutating
    tools and completion tools. Keeper-local observation/discovery tools and
    LLM-native read/search aliases remain passive: they can inform a later
    action, but cannot satisfy a required-action contract by themselves.

    When [satisfying_tools] is provided and non-empty, the error message
    appends actionable alternatives so the model knows which tools to call
    instead of the rejected passive one. *)
val required_tool_satisfaction
  :  ?satisfying_tools:string list
  -> Agent_sdk.Completion_contract.tool_call
  -> (unit, string) result

(** Variant of [required_tool_satisfaction] for an explicit
    [required_tools] contract. A non-keeper read-only tool can satisfy the turn
    only when the operator/task contract named that exact tool. *)
val required_tool_satisfaction_for_required_names
  :  ?satisfying_tools:string list
  -> required_tool_names:string list
  -> Agent_sdk.Completion_contract.tool_call
  -> (unit, string) result

(** OAS-level satisfaction callback for keeper turns.

    Generic required-tool gates use OAS to enforce tool presence only; MASC
    classifies passive-only / no-execution-progress calls after the run, where
    it can emit a precise receipt without converting the turn into a provider
    contract error that can durable-pause the keeper. Explicit
    [required_tool_names] still require the named tool.

    [satisfying_tools] is forwarded to [required_tool_satisfaction] so
    the rejection message includes actionable alternatives. *)
val required_tool_satisfaction_for_turn
  :  ?satisfying_tools:string list
  -> required_tool_names:string list
  -> Agent_sdk.Completion_contract.tool_call
  -> (unit, string) result

(** Extract OAS completion-contract satisfying-tool hints from an error reason.

    OAS v0.196.4 appends a line shaped like
    ["Satisfying tools for this contract: [keeper_board_post, masc_broadcast]"].
    Keeper recovery prompts consume this so retry guidance does not lose the
    provider-side violation detail. Returns [] when the reason has no hint or
    the hint is empty. *)
val satisfying_tools_from_contract_violation_reason : string -> string list

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
  -> actionable_signal_context:Keeper_contract_classifier.actionable_signal_context
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
