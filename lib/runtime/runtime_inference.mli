val resolve_reasoning_effort :
  runtime_id:string -> Llm_provider.Reasoning_effort.t option
(** The per-model [reasoning-effort] declared for [runtime_id], or [None]
    when the model leaves it unset. Official-client runtimes have no other
    declared reasoning control. *)

val resolve_turn_timeout_s : runtime_id:string -> float option

(** The per-model [turn-timeout-s] declared for [runtime_id], or [None] when
    the model leaves it unset. Streaming official-client adapters use it as
    their protocol-idle liveness window. *)

val turn_timeout_s_of_declared : default:float -> float option -> float option
(** Apply one declared value: [None] keeps [default]; a non-positive value
    removes the bound ([None]); anything else stands. *)

val resolve_temperature :
  runtime_id:string -> fallback:(unit -> float) -> float
(** Use the runtime.toml model override when present; evaluate [fallback] only
    when that runtime has no temperature override. *)

val for_runtime : name:string -> Runtime_thinking_seed.t
(** The thinking seed of runtime [name]: {!Runtime_thinking_seed.of_model} for a
    [Masc_agent_core] execution, and {!Runtime_thinking_seed.absent} for an
    [Official_client] execution, whose client owns the reasoning control, or an
    id that names no loaded runtime. *)
