val resolve_temperature :
  runtime_id:string -> fallback:(unit -> float) -> float

val resolve_max_tokens :
  runtime_id:string -> fallback:(unit -> int) -> int

val cap_max_tokens_to_runtime_ceiling :
  runtime_id:string -> source:string -> int -> int

type seed = {
  thinking_budget : int option;
  thinking_enabled : bool option;
  preserve_thinking : bool option;
}

val seed_of_thinking_support
  :  ?preserve_thinking:bool option
  -> ?thinking_budget:int option
  -> bool option
  -> seed
(** Pure: map a model's [thinking-support] capability to the keeper thinking
    seed.  [Some false] is a force-thinking-off signal;
    [Some true] actively enables thinking for that model binding.
    [thinking_budget] carries the per-model [max-thinking-budget] ceiling
    (RFC-0271 §4.2); [None] preserves the prior wire. *)

val for_runtime : name:string -> seed
(** Per-model thinking seed for runtime [name], resolved from the runtime.toml
    [thinking-support], explicit [preserve-thinking], and OAS typed
    preserve-thinking capability of the bound model.  See
    {!seed_of_thinking_support} for the gate semantics. *)

val validate_max_tokens_within_ceiling :
  runtime_id:string ->
  provider_ceiling:int option ->
  int ->
  (int, Keeper_internal_error.masc_internal_error) result
