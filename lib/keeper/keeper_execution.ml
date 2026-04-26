(** Keeper_execution — keeper tool execution loop, prompting,
    compaction, and keepalive runtime.

    Delegates to sub-modules:
    - Keeper_coordination: checkpoint, room presence, compaction
    - Keeper_prompt: system prompts, mention detection, text processing

    Proactive emission and autonomous goal turns are now handled by
    Keeper_unified_turn via the unified keeper loop. *)

include Keeper_coordination
include Keeper_prompt

let memory_check_default_json = Keeper_exec_context.memory_check_default_json
