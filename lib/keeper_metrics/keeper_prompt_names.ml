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
let tool_unknown_guard = "keeper.tool_unknown_guard"
let recovery_block = "keeper.recovery_block"
let failure_judgment = "keeper.failure_judgment"
let board_attention_judgment = "keeper.board_attention_judgment"
let gate_judgment = "keeper.gate_judgment"
let turn_intent = "keeper.turn_intent"
let librarian_system = "keeper.librarian.system"
let librarian_episode_extraction = "keeper.librarian.episode_extraction"
let librarian_memory_consolidation = "keeper.librarian.memory_consolidation"
let memory_os_recall_context = "keeper.memory_os_recall.context"
let memory_os_recall_facts_section = "keeper.memory_os_recall.facts_section"
let memory_os_recall_episodes_section = "keeper.memory_os_recall.episodes_section"
let memory_os_recall_unavailable = "keeper.memory_os_recall.unavailable"

(** User-prompt "Claimable Work" section body, emitted when a claimable backlog
    is visible and the keeper holds no task. *)
let immediate_task_move = "keeper.immediate_task_move"
