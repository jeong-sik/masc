(** Keeper_execution — keeper tool execution loop, prompting,
    checkpointing, and keepalive runtime.

    Delegates to sub-modules:
    - Keeper_context_runtime: checkpoint and model labels
    - Keeper_prompt: system prompts, mention detection, text processing

    Proactive emission and autonomous goal turns are now handled by
    Keeper_unified_turn via the unified keeper loop. *)


include Keeper_prompt

let log_keeper_exn = Keeper_context_runtime.log_keeper_exn
let load_context_from_checkpoint = Keeper_context_runtime.load_context_from_checkpoint
let generate_trace_id = Keeper_context_runtime.generate_trace_id