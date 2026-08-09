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
(** Per-model thinking seed for runtime [name]. [Masc_oas] executions resolve
    runtime.toml [thinking-support] and explicit [preserve-thinking].
    [Official_client] executions return an empty seed because their typed
    effort is owned by the client boundary, not the OAS boolean controls.
    Unknown runtimes preserve the existing all-absent result. *)
