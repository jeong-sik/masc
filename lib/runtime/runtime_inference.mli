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
(** Per-model thinking seed for runtime [name], resolved from the runtime.toml
    [thinking-support], explicit [preserve-thinking], and OAS typed
    preserve-thinking capability of the bound model.  See
    {!seed_of_thinking_support} for the gate semantics. *)
