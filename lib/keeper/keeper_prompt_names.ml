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
let turn_intent = "keeper.turn_intent"

(** Turn-intent substitution prose files. Each holds a single bullet (or
    short block) that the OCaml side injects into [turn_intent] when the
    corresponding toggle is active. Externalized from
    [keeper_unified_prompt.ml] per the in-file policy stating that prose
    edits belong alongside the other keeper prompt markdown files. *)
let turn_intent_claim_guidance_a = "keeper.turn_intent.claim_guidance_a"
let turn_intent_claim_guidance_b = "keeper.turn_intent.claim_guidance_b"
let turn_intent_board_activity_guidance = "keeper.turn_intent.board_activity_guidance"
let turn_intent_board_post_guidance = "keeper.turn_intent.board_post_guidance"
let turn_intent_board_curation_guidance = "keeper.turn_intent.board_curation_guidance"
let turn_intent_broadcast_guidance = "keeper.turn_intent.broadcast_guidance"

(** User-prompt "Immediate Task Move" section body, emitted when a
    claimable backlog is visible and the keeper holds no task. *)
let immediate_task_move = "keeper.immediate_task_move"
