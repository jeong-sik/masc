(** Keeper_run_prompt — build turn prompt context (Steps 5-6).

    Takes the run context from [Keeper_run_context], calls the
    [build_turn_prompt] callback to get the final system prompt and
    dynamic context, then renders memory/temporal context, builds prompt
    metrics, and appends the user message.

    @since 0.120.0 *)

type turn_prompt_context =
  { turn_system_prompt : string
  ; dynamic_context : string
  ; temporal_context : string
  ; prompt_metrics : Keeper_agent_prompt_metrics.prompt_metrics
  ; history_messages : Agent_core.Types.message list
  ; ctx_work : Keeper_context_runtime.working_context
  }

type user_turn_record =
  | Record_user_turn
  | Skip_already_checkpointed_user_turn
(** Whether this turn's user message belongs in the durable transcript.

    [Record_user_turn] is the ordinary path, including autonomous [Continue.]
    turns. [Skip_already_checkpointed_user_turn] is reserved for a resumed
    checkpoint that already contains the exact current input, so replay does
    not append a duplicate. The distinction is typed, not inferred from text. *)

type extra_system_context_assembly =
  { extra_system_context : string option
  ; blocks : (Prompt_block_id.t * string) list
  }

val sanitize_user_message : string -> string
(** Normalize malformed UTF-8 before appending the complete user message to
    the AGENT_CORE context. This boundary does not classify or rewrite its meaning. *)

val assemble_extra_system_context :
  existing_extra_system_context:string option ->
  blocks:(Prompt_block_id.t * string) list ->
  extra_system_context_assembly
(** Assemble every complete typed prompt block in source order. No local size
    estimate has authority over assembly or dispatch; typed provider overflow
    is handled at the MASC lane boundary. *)

val ends_with_tool_results : Agent_core.Types.message list -> bool
(** Whether the conversation's last message is a Tool-role message — i.e. the
    next provider round immediately continues a tool loop.

    This is a position question, not a containment question:
    [Hooks.last_tool_results] reports the results of the last Tool message
    anywhere in history, so it is non-empty for almost every turn of a keeper
    that has ever used a tool. Gating the recurring context blocks on that
    predicate suppressed the world state on the first round of ordinary turns
    (live: sangsu turn 15, 2026-08-24 08:08Z — ctx absent on round one). The
    first round of a turn ends with the user's message; only rounds that
    follow tool execution end with the Tool message. *)

val build_turn_context
  :  ctx:Keeper_run_context.run_context
  -> build_turn_prompt:(base_system_prompt:string -> messages:Agent_core.Types.message list -> Keeper_agent_prompt_metrics.turn_prompt)
  -> user_message:string
  -> config:Workspace.config
  -> meta:Keeper_meta_contract.keeper_meta
  -> history_user_source:string
  -> user_turn_record:user_turn_record
  -> is_retry:bool
  -> start_turn_count:int
  -> turn_prompt_context
