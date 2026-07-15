(** Keeper_execution — keeper tool execution loop, prompting,
    compaction, and keepalive runtime.

    Delegates to sub-modules:
    - Keeper_context_runtime: checkpoint, compaction, model labels
    - Keeper_prompt: system prompts, mention detection, text processing

    Proactive emission and autonomous turns are now handled by
    Keeper_unified_turn via the unified keeper loop. *)


include Keeper_prompt

let log_keeper_exn = Keeper_context_runtime.log_keeper_exn
let load_context_from_checkpoint = Keeper_context_runtime.load_context_from_checkpoint
let compaction_policy_of_keeper = Keeper_context_runtime.compaction_policy_of_keeper
let generate_trace_id = Keeper_context_runtime.generate_trace_id
let effective_model_labels_for_turn = Keeper_context_runtime.effective_model_labels_for_turn
let memory_check_default_json = Keeper_context_runtime.memory_check_default_json
