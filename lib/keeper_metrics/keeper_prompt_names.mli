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
val tool_preferred_header : string
val tool_preferred_empty : string
val tool_unknown_guard : string
val recovery_block : string
val turn_intent : string
val librarian_system : string
val librarian_episode_extraction : string
val librarian_memory_consolidation : string
val memory_os_recall_context : string
val memory_os_recall_facts_section : string
val memory_os_recall_episodes_section : string
val memory_os_recall_unavailable : string

(** Turn-intent substitution prose template keys. *)
val turn_intent_claim_guidance_a : string
val turn_intent_claim_guidance_b : string
val turn_intent_board_activity_guidance : string
val turn_intent_board_post_guidance : string
val turn_intent_board_curation_guidance : string
val turn_intent_broadcast_guidance : string
val turn_intent_task_create_guidance : string
val turn_intent_pr_duplicate_search_guidance : string

(** User-prompt "Claimable Work" section template key. *)
val immediate_task_move : string
