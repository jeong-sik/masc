(** Keeper_run_prompt — build turn prompt context (Steps 5-6).

    Takes the run context from [Keeper_run_context], calls the
    [build_turn_prompt] callback to get the final system prompt and
    dynamic context, then renders memory/temporal context, builds prompt
    metrics, and appends the user message.

    @since 0.120.0 *)

type turn_prompt_context =
  { turn_system_prompt : string
  ; dynamic_context : string
  ; memory_context : string
  ; temporal_context : string
  ; prompt_metrics : Keeper_agent_prompt_metrics.prompt_metrics
  ; history_messages : Agent_sdk.Types.message list
  ; ctx_work : Keeper_context_runtime.working_context
  }

type extra_system_context_assembly =
  { extra_system_context : string option
  ; blocks : (Prompt_block_id.t * string) list
  }

val sanitize_user_message : string -> string
(** Normalize malformed UTF-8 before appending the complete user message to
    the OAS context. This boundary does not classify or rewrite its meaning. *)

val normalize_memory_fragment : string -> string
(** Normalize malformed UTF-8 while preserving the complete recalled memory.
    Trust and relevance are interpreted by the configured model, not by a
    local string deny-list. *)

val assemble_extra_system_context :
  existing_extra_system_context:string option ->
  blocks:(Prompt_block_id.t * string) list ->
  extra_system_context_assembly
(** Assemble every complete typed prompt block in source order. No local size
    estimate has authority over assembly or dispatch; typed provider overflow
    is handled at the MASC lane boundary. *)

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
