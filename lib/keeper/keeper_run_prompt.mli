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
  ; ctx_work : Keeper_exec_context.working_context
  }

val sanitize_user_message : string -> string
(** Remove role/jailbreak prefixes from a turn user message before it is
    appended to the OAS context. *)

val build_turn_context
  :  ctx:Keeper_run_context.run_context
  -> build_turn_prompt:(base_system_prompt:string -> messages:Agent_sdk.Types.message list -> Keeper_agent_prompt_metrics.turn_prompt)
  -> user_message:string
  -> config:Coord.config
  -> meta:Keeper_types.keeper_meta
  -> history_user_source:string
  -> is_retry:bool
  -> start_turn_count:int
  -> turn_prompt_context
