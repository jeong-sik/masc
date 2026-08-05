(** Keeper_prompt_names — SSOT for Prompt_registry template keys
    used by keeper modules.

    All keeper prompt lookups must reference these constants
    instead of string literals. *)

let system = "keeper.system"
let board_attention_judgment_batch = "keeper.board_attention_judgment_batch"
let gate_judgment = "keeper.gate_judgment"
let verification_anti_rationalization = "verification.anti_rationalization"
let memory_os_recall_context = "keeper.memory_os_recall.context"
let librarian_current_selection = "keeper.librarian.current_selection"
