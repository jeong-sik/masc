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

    Block order: the shared [keeper] body in the system tags, the world's
    [keeper.worldview], the world's articles, the keeper's identity and
    workspace, then [instructions] in the role tags. The first three are the
    same for every keeper in a world, so the shared prefix stays maximal.

    [constitution] is the world's own articles, already rendered
    ({!World_constitution_render.articles}); an empty one renders nothing at
    all. *)

(** {1 Text Processing}

    Re-exported from [Keeper_text_processing]. *)

include module type of Keeper_text_processing
