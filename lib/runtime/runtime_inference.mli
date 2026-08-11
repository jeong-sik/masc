val resolve_reasoning_effort :
  runtime_id:string -> Llm_provider.Reasoning_effort.t option
(** The per-model [reasoning-effort] declared for [runtime_id], or [None]
    when the model leaves it unset. Official-client runtimes have no other
    declared reasoning control. *)

val resolve_turn_timeout_s : runtime_id:string -> float option
(** The per-model [turn-timeout-s] declared for [runtime_id], or [None] when
    the model leaves it unset. Streaming official-client adapters use it as
    their protocol-idle liveness window. *)

val resolve_max_prompt_bytes : runtime_id:string -> int option
(** Per-model ceiling, in bytes, on the history an official-client start turn
    seeds its conversation with. [None] applies no ceiling. *)

val resolve_temperature :
  runtime_id:string -> fallback:(unit -> float) -> float
(** Use the runtime.toml model override when present; evaluate [fallback] only
    when that runtime has no temperature override. *)

type seed = {
  thinking_budget : int option;
  thinking_enabled : bool option;
  preserve_thinking : bool option;
}

val seed_of_thinking_support
  :  ?preserve_thinking:bool option
  -> bool option
  -> seed
(** Pure: map a model's [thinking-support] capability to the keeper thinking
    seed.  [Some false] is a force-thinking-off signal;
    [Some true] actively enables thinking for that model binding. *)

val for_runtime : name:string -> seed
(** Per-model thinking seed for runtime [name]. [Masc_agent_core] executions resolve
    runtime.toml [thinking-support] and explicit [preserve-thinking].
    [Official_client] executions return an empty seed because their typed
    effort is owned by the client boundary, not the AGENT_CORE boolean controls.
    Unknown runtimes preserve the existing all-absent result. *)
