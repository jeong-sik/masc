val resolve_temperature :
  runtime_id:string -> fallback:(unit -> float) -> float

val resolve_max_tokens :
  runtime_id:string -> fallback:(unit -> int) -> int

type seed = {
  thinking_budget : int option;
  thinking_enabled : bool option;
  preserve_thinking : bool option;
}

val seed_of_thinking_support
  :  ?preserve_thinking:bool option
  -> bool option
  -> seed
(** Pure: map OAS's [supports_extended_thinking] capability to the keeper
    thinking seed. [Some false] is a force-thinking-off signal; [Some true]
    actively enables thinking for that model binding. *)

val for_runtime : name:string -> seed
(** Per-model thinking seed for runtime [name], resolved from OAS's
    [supports_extended_thinking] and preserve capability of the bound model.
    See
    {!seed_of_thinking_support} for the gate semantics. *)
