(** Keeper_prompt_names — SSOT for Prompt_registry template keys
    used by keeper modules.

    All keeper prompt lookups must reference these constants
    instead of string literals. *)

val system : string
(** Shared keeper system prompt. Merged from the former [constitution],
    [world], [capabilities], and [core_behavior] keys, which each restated
    the same rule families in a different wording. *)

val reply_guidelines : string
val recovery_block : string
val board_attention_judgment_batch : string
val gate_judgment : string
val librarian_system : string
val librarian_current_selection : string
val memory_os_recall_context : string
val memory_os_recall_unavailable : string
