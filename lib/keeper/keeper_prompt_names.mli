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
val tool_workflow_gh_full : string
val tool_workflow_gh_no_pr : string
val tool_workflow_gh_minimal : string
val tool_unknown_guard : string
