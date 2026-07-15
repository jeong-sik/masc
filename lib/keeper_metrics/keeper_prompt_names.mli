(** Keeper_prompt_names — SSOT for Prompt_registry template keys
    used by keeper modules.

    All keeper prompt lookups must reference these constants
    instead of string literals. *)

val constitution : string
val world : string
val capabilities : string
val deliberation : string
val unified_system : string
val reply_guidelines : string
val core_behavior : string
val recovery_block : string
val failure_judgment : string
val board_attention_judgment : string
val gate_judgment : string
val turn_intent : string
val librarian_system : string
val librarian_episode_extraction : string
val librarian_memory_consolidation : string
val memory_os_recall_context : string
val memory_os_recall_facts_section : string
val memory_os_recall_episodes_section : string
val memory_os_recall_unavailable : string

(** User-prompt "Claimable Work" section template key. *)
val immediate_task_move : string
