(** Keeper_prompt_names — SSOT for Prompt_registry template keys
    used by keeper modules.

    All keeper prompt lookups must reference these constants
    instead of string literals. *)

let constitution = "keeper.constitution"
let world = "keeper.world"
let capabilities = "keeper.capabilities"
let deliberation = "keeper.deliberation"
let unified_system = "keeper.unified.system"
let reply_guidelines = "keeper.reply_guidelines"
let core_behavior = "keeper.core_behavior"
let tool_preferred_header = "keeper.tool_preferred_header"
let tool_preferred_empty = "keeper.tool_preferred_empty"
let tool_workflow_gh_full = "keeper.tool_workflow_gh_full"
let tool_workflow_gh_no_pr = "keeper.tool_workflow_gh_no_pr"
let tool_workflow_gh_minimal = "keeper.tool_workflow_gh_minimal"
let tool_unknown_guard = "keeper.tool_unknown_guard"
let recovery_block = "keeper.recovery_block"
