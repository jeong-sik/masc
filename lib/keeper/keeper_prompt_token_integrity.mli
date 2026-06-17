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

(** Remove keeper_*/masc_* tokens that do not resolve to a live tool via
    [Keeper_tool_resolution]. Registry-driven root fix for stale tool names
    leaking into prompts, replacing the hardcoded retired-prefix list. Resolved
    tools and aliases are kept; env-var-shaped (all-uppercase, e.g.
    [MASC_BASE_PATH]) tokens are kept (not tool invocations). *)
val strip_unresolved_tool_tokens : string -> string
