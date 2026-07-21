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

type user_turn_record =
  | Record_user_turn
  | Skip_uninformative_wake
(** Whether this turn's user message belongs in the durable transcript.

    [Skip_uninformative_wake] is the autonomous wake marker on its own: a
    constant whose observation frame rides [dynamic_context], rebuilt fresh
    every turn. Recording it appends a byte-identical message per wake and
    becomes pure duplication — one keeper accumulated the same 147B message
    x359 (RFC-0351 section 5, #25462). The distinction is typed, not inferred
    from message text. *)

val user_turn_record_of_hitl_resolution : _ option -> user_turn_record
(** Map the unified lane's HITL resolution slot to a transcript decision.
    Absent resolution means the user turn is the bare wake marker. *)

type memory_extraction_record =
  | Extract_turn
  | Skip_inert_turn
(** Whether this turn is worth running librarian extraction over.

    [Skip_inert_turn] is a bare autonomous wake that also called no tool: the
    input carried nothing forward ({!Skip_uninformative_wake}) and the turn
    changed nothing observable. The librarian fires on a turn cadence rather
    than on activity, so an idle stretch keeps extracting, and what it can
    extract from such a turn is the model's prose about its own idleness.
    Those land in the fact store as [ephemeral] claims ("Agent idle across 72
    consecutive autonomous wake cycles"), are recalled the next turn, and are
    read back as evidence that there is nothing to do — a loop that runs while
    the world observation on the same prompt reports claimable tasks.

    The distinction is typed and derived from the wake decision plus the
    turn's tool-call list, never from response text. *)

val memory_extraction_record_of_turn
  :  user_turn_record:user_turn_record
  -> tool_calls_made:bool
  -> memory_extraction_record
(** [Skip_inert_turn] only when the wake was bare {b and} no tool ran. A wake
    that called a tool did something worth recording; a turn carrying operator
    or HITL input can hold a durable fact even with no tool call. *)

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
  -> user_turn_record:user_turn_record
  -> is_retry:bool
  -> start_turn_count:int
  -> turn_prompt_context
