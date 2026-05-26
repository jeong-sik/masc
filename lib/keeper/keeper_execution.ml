(** Keeper_execution — keeper tool execution loop, prompting,
    compaction, and keepalive runtime.

    Delegates to sub-modules:
    - Keeper_exec_context: checkpoint, compaction, model labels
    - Keeper_coordination: room presence
    - Keeper_prompt: system prompts, mention detection, text processing

    Proactive emission and autonomous goal turns are now handled by
    Keeper_unified_turn via the unified keeper loop. *)


include Keeper_prompt

let log_keeper_exn = Keeper_exec_context.log_keeper_exn
let load_context_from_checkpoint = Keeper_exec_context.load_context_from_checkpoint
let compaction_policy_of_keeper = Keeper_exec_context.compaction_policy_of_keeper
let generate_trace_id = Keeper_exec_context.generate_trace_id
let effective_model_labels_for_turn = Keeper_exec_context.effective_model_labels_for_turn
let ensure_keeper_room_presence = Keeper_coordination.ensure_keeper_room_presence
let room_cursor_for = Keeper_coordination.room_cursor_for
let set_room_cursor = Keeper_coordination.set_room_cursor
let memory_check_default_json = Keeper_exec_context.memory_check_default_json
