(** Keeper_prompt — System prompts, Keeper instructions, and text processing
    for keeper agents. AGENT_CORE-aligned: these functions define agent identity and
    text output. *)

val system_prompt_body : unit -> string
(** The shared [keeper] block, read from the prompt registry. *)

val build_keeper_system_prompt :
  instructions:string ->
  ?keeper_name:string ->
  ?workspace_root:string ->
  ?constitution:string ->
  unit ->
  string
(** Repository identity and checkout freshness are obtained from the typed
    context projection rather than inferred from prompt prose.

    [constitution] is the world's own articles, already rendered
    ({!World_constitution_render.articles}). It sits ahead of the
    keeper-specific blocks because every keeper in a world reads the same text,
    and an empty one renders nothing at all. *)

(** {1 Text Processing}

    Re-exported from [Keeper_text_processing]. *)

include module type of Keeper_text_processing
