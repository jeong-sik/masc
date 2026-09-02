(** Keeper_prompt — System prompts, Keeper instructions, and text processing
    for keeper agents. AGENT_CORE-aligned: these functions define agent identity and
    text output. *)

val exact_direct_mention_present : targets:string list -> string -> bool

val system_prompt_body : unit -> string
(** The shared [keeper] block, read from the prompt registry. *)

val build_keeper_system_prompt :
  instructions:string ->
  ?keeper_name:string ->
  ?workspace_root:string ->
  unit ->
  string
(** Repository identity and checkout freshness are obtained from the typed
    context projection rather than inferred from prompt prose. *)

(** {1 Text Processing}

    Re-exported from [Keeper_text_processing]. *)

include module type of Keeper_text_processing
