(** Keeper_prompt_token_integrity — scan rendered prompts and continuity
    summaries for keeper_*/masc_* tokens and verify each one resolves through
    the policy tool-name chain.

    P0-3: Rendered Prompt Token Scanner. Emits the
    [masc_keeper_prompt_unknown_tool_tokens_total] CI metric for every token
    that does not resolve via [Keeper_tool_resolution.resolve]. *)

(** Which prompt/continuity surface a token came from. *)
type source =
  | System_prompt
  | User_message
  | Continuity

val source_to_string : source -> string

(** Scan a single text surface. Unknown tokens are deduplicated within the
    surface, the counter is incremented once per unknown token, and a warning
    is logged. Returns the deduplicated list of unknown token names in the
    order they were first seen. *)
val scan_text : keeper_name:string -> source:source -> string -> string list

(** Scan the rendered system prompt, user message, and raw continuity summary.
    Returns the deduplicated list of unknown token names across all three
    surfaces. *)
val scan_rendered_prompt :
  keeper_name:string ->
  system_prompt:string ->
  user_message:string ->
  continuity_summary:string ->
  string list
(** [scan_rendered_prompt] is the generic all-text scanner used for explicit
    caller-supplied text. It must not be used for a structured world-state
    observation, because observation values are data rather than tool
    instructions. Use {!scan_instruction_surfaces} from the unified prompt
    builder. *)

(** Scan only prompt surfaces that are owned by the instruction/memory
    producer. The unified prompt's structured world-state user message is
    intentionally absent: board/task/connector observations must remain
    immutable even when a field happens to contain a [keeper_*] or [masc_*]
    diagnostic name. *)
val scan_instruction_surfaces :
  keeper_name:string ->
  system_prompt:string ->
  continuity_summary:string ->
  string list

(** Sanitize keeper_*/masc_* tokens that do not resolve to a live tool via
    [Keeper_tool_resolution]. Registry-driven presentation-layer band-aid for
    stale tool names leaking into prompts, replacing the hardcoded
    retired-prefix list. Resolved tools and aliases are kept; env-var-shaped
    (all-uppercase, e.g. [MASC_BASE_PATH]) tokens are kept (not tool
    invocations). Unresolved tokens are replaced with
    [<stale_tool_token>] to avoid leaving semantic holes in sentences.

    When [~keeper_name] is supplied, each replacement emits
    [masc_keeper_prompt_token_stripped_total] and a warning log so the
    producer-side alarm is not silenced. *)
val strip_unresolved_tool_tokens : ?keeper_name:string -> string -> string
