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

type context_window_observation =
  { observed_estimated_input_tokens : int
  ; observed_context_window : int
  ; observed_remaining_context_tokens : int
  ; observed_over_context_tokens : int
  ; observed_context_usage_ratio : float
  }

type extra_system_context_assembly =
  { extra_system_context : string option
  ; blocks : (Prompt_block_id.t * string) list
  ; hook_extra_system_context_estimated_tokens : int
  ; post_hook_estimated_input_tokens : int
  ; post_hook_context_window_observation : context_window_observation
  }

val sanitize_user_message : string -> string
(** Normalize malformed UTF-8 before appending the complete user message to
    the OAS context. This boundary does not classify or rewrite its meaning. *)

val normalize_memory_fragment : string -> string
(** Normalize malformed UTF-8 while preserving the complete recalled memory.
    Trust and relevance are interpreted by the configured model, not by a
    local string deny-list. *)

val estimate_input_tokens :
  system_prompt:string ->
  dynamic_context:string ->
  memory_context:string ->
  temporal_context:string ->
  user_message:string ->
  history_messages:Agent_sdk.Types.message list ->
  int
(** Shared pre-call input-token observation for manifests and request metrics.
    It does not authorize omission, truncation, or dispatch failure. *)

val estimate_tool_schema_context :
  estimated_input_tokens:int ->
  tools:Agent_sdk.Tool.t list ->
  tool_schema_context_estimate
(** Add the serialized tool-schema payload that OAS sends to providers to the
    prompt/history estimate. This matches OAS' default full-schema disclosure. *)

val estimate_unaccounted_extra_system_context_tokens :
  preflight_accounted_blocks:Prompt_block_id.t list ->
  (Prompt_block_id.t * string) list -> int
(** Estimate the hook-injected [extra_system_context] blocks that were not
    already included in the pre-dispatch prompt estimate. The caller supplies
    [preflight_accounted_blocks] from the actual turn prompt assembly ledger;
    this function does not maintain an internal prompt-block allowlist. *)

val assemble_extra_system_context :
  estimated_input_tokens_with_tools:int ->
  max_context:int ->
  existing_extra_system_context:string option ->
  preflight_accounted_blocks:Prompt_block_id.t list ->
  blocks:(Prompt_block_id.t * string) list ->
  extra_system_context_assembly
(** Assemble every complete typed prompt block in source order. Token estimates
    and the provider-declared context window are recorded only as observations;
    MASC never omits a block based on an estimate. The complete request reaches
    OAS, whose typed [ContextOverflow] and compaction path own overflow handling. *)

val observe_context_window :
  estimated_input_tokens:int -> max_context:int -> context_window_observation
(** Observe the aggregate estimate against the provider-declared window. This
    value has no authority over prompt assembly or dispatch. *)

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
