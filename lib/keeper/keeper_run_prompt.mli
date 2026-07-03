(** Keeper_run_prompt — build turn prompt context (Steps 5-6).

    Takes the run context from [Keeper_run_context], calls the
    [build_turn_prompt] callback to get the final system prompt and
    dynamic context, then renders memory/temporal context, builds prompt
    metrics, appends the user message, and estimates input tokens.

    @since 0.120.0 *)

type turn_prompt_context =
  { turn_system_prompt : string
  ; dynamic_context : string
  ; memory_context : string
  ; temporal_context : string
  ; prompt_metrics : Keeper_agent_prompt_metrics.prompt_metrics
  ; history_messages : Agent_sdk.Types.message list
  ; estimated_input_tokens : int
  ; ctx_work : Keeper_context_runtime.working_context
  }

type tool_schema_context_estimate =
  { tool_count : int
  ; tool_schema_tokens : int
  ; estimated_input_tokens_with_tools : int
  }

type context_window_budget =
  { budget_estimated_input_tokens : int
  ; budget_context_window : int
  ; remaining_context_tokens : int
  ; over_context_tokens : int
  ; context_usage_ratio : float
  }

type context_layer_decision =
  | Within_cap
  | Over_cap_observed
  | Empty

type context_layer_budget =
  { context_layer_name : string
  ; context_layer_priority : string
  ; context_layer_estimated_tokens : int
  ; context_layer_cap_tokens : int
  ; context_layer_budgeted_tokens : int
  ; context_layer_decision : context_layer_decision
  }

type extra_system_context_budget =
  { extra_system_context : string option
  ; included_blocks : (Prompt_block_id.t * string) list
  ; skipped_blocks : Prompt_block_id.t list
  ; skipped_estimated_tokens : int
  ; hook_extra_system_context_estimated_tokens : int
  ; post_hook_estimated_input_tokens : int
  ; post_hook_context_window_budget : context_window_budget
  }

val sanitize_user_message : string -> string
(** Remove role/jailbreak prefixes from a turn user message before it is
    appended to the OAS context. *)

val safe_memory_fragment : string -> string option
(** Return the memory-recall fragment unchanged if it does not contain
    any known prompt-injection or role-jailbreak prefix. Otherwise return
    [None] so the caller can drop the whole fragment instead of trying to
    strip an open-ended prefix list. This is a defensive deny-list style
    guard: fragments containing dangerous leading tokens are denied. *)

val render_recent_failure_context :
  Keeper_failure_circuit_breaker.failure_signature list -> string
(** Render a bounded, non-authoritative dynamic-context block from the
    keeper's recent tool failure signatures. Returns [""] when there is no
    recent failure memory. *)

val dynamic_context_with_recent_failures :
  keeper_name:string -> string -> string
(** Append the bounded recent-failure prompt block exactly as turn dispatch
    does before computing prompt metrics. *)

val estimate_input_tokens :
  prompt_metrics:Keeper_agent_prompt_metrics.prompt_metrics ->
  system_prompt:string ->
  dynamic_context:string ->
  memory_context:string ->
  temporal_context:string ->
  user_message:string ->
  history_messages:Agent_sdk.Types.message list ->
  int
(** Shared pre-call input-token estimate used by retry budget checks and
    normal turn prompt construction. *)

val estimate_tool_schema_context :
  estimated_input_tokens:int ->
  tools:Agent_sdk.Tool.t list ->
  tool_schema_context_estimate
(** Add the serialized tool-schema payload that OAS sends to providers to the
    prompt/history estimate. This matches OAS' default full-schema disclosure. *)

val estimate_unaccounted_extra_system_context_tokens :
  (Prompt_block_id.t * string) list -> int
(** Estimate the hook-injected [extra_system_context] blocks that were not
    already included in the pre-dispatch prompt estimate. *)

val budget_extra_system_context :
  estimated_input_tokens_with_tools:int ->
  max_context:int ->
  existing_extra_system_context:string option ->
  blocks:(Prompt_block_id.t * string) list ->
  extra_system_context_budget
(** Rebuild [extra_system_context] from typed prompt blocks while keeping
    hook-only additions inside the effective context window. The post-hook
    estimate is derived from the assembled [extra_system_context] string so
    separators and existing hook context are accounted. Blocks already
    represented in the pre-dispatch prompt estimate are subtracted from that
    assembled estimate to avoid double-counting; blocks that would exceed the
    remaining window are omitted and reported in [skipped_blocks]. *)

val context_window_budget :
  estimated_input_tokens:int -> max_context:int -> context_window_budget
(** Token-budget ledger for the final pre-dispatch estimate against the
    effective provider-aware context window. *)

val estimate_context_layer_budget :
  layer_name:string ->
  priority:string ->
  cap_tokens:int ->
  text:string ->
  context_layer_budget
(** Estimate one prompt/context layer against its deterministic cap for
    manifest/debug accounting. This function does not mutate the layer text;
    over-cap layers are reported as [over_cap_observed], not as truncated. *)

val context_layer_budget_to_json : context_layer_budget -> Yojson.Safe.t
(** JSON projection for runtime manifests and dashboard/debug surfaces. *)

val preflight_context_window :
  estimated_input_tokens:int ->
  max_context:int ->
  (unit, Agent_sdk.Error.sdk_error) result
(** Return a typed context-window signal when the final pre-call input estimate
    exceeds the effective runtime/provider context window. Callers that can use
    the OAS driver retry/compaction path should defer terminal handling there. *)

val build_turn_context
  :  ctx:Keeper_run_context.run_context
  -> build_turn_prompt:(base_system_prompt:string -> messages:Agent_sdk.Types.message list -> Keeper_agent_prompt_metrics.turn_prompt)
  -> user_message:string
  -> config:Workspace.config
  -> meta:Keeper_meta_contract.keeper_meta
  -> history_user_source:string
  -> is_retry:bool
  -> start_turn_count:int
  -> turn_prompt_context
