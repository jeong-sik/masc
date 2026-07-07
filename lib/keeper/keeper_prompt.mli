(** Keeper_prompt — System prompts, personality evolution, and text processing
    for keeper agents. OAS-aligned: these functions define agent identity and
    text output. *)

val exact_direct_mention_present : targets:string list -> string -> bool

val keeper_constitution : unit -> string

val substitute_state_block_instruction_fallback : string -> string
(** Replace every [{{state_block_instruction}}] placeholder in [raw] with
    [Keeper_state_block_prompt.instruction_text].  Exposed so the constitution
    Error-fallback in {!keeper_constitution} can substitute the variable even
    when the registry's [render_prompt_template] returns [Error] (e.g. a
    newly-introduced unresolved variable, or a malformed template).  Without
    this substitution the raw template surfaces the literal placeholder, the
    "State block template" anchor goes missing, and
    [missing_critical_prompt_anchors] reports [state_block_template] missing —
    the regression observed as ~51 emissions per restart with
    [keeper_name=null] (the constitution path runs before per-keeper context
    binding).  Pure: no I/O, no logging. *)

val ensure_critical_prompt_anchors : string -> string
(** Append a minimal technical recovery block when the keeper system prompt
    lost critical continuity/world/policy anchors. Normal prompts are returned
    unchanged. *)

val state_block_output_guard_text : string
(** Turn-level output guard for runtime-managed continuity. The runtime may
    synthesize and persist STATE metadata, so direct/no-state turns should not
    ask the model to emit raw STATE markers in visible text. *)

val build_keeper_system_prompt :
  goal:string ->
  instructions:string ->
  ?persona_extended:string ->
  ?keeper_name:string ->
  ?home_ground:string ->
  ?active_goals:(string * string) list ->
  ?registered_repos:string list ->
  unit ->
  string
(** [registered_repos] lists the keeper's registered repository ids (from
    [repositories.toml]). When non-empty it renders a [<registered_repositories>]
    block enumerating the valid [repos/<name>] segments, so the keeper does not
    guess org-prefixed / renamed / invented names that fail as unregistered. *)

val append_direct_reply_mode_prompt :
  base_prompt:string ->
  string

val append_trait_clause : base:string -> clause:string -> string

(** {1 Text Processing}

    Re-exported from [Keeper_text_processing]. *)

include module type of Keeper_text_processing
