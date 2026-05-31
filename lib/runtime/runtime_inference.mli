val resolve_temperature :
  runtime_id:string -> fallback:(unit -> float) -> float

val resolve_max_tokens :
  runtime_id:string -> fallback:(unit -> int) -> int

val cap_max_tokens_to_runtime_ceiling :
  runtime_id:string -> source:string -> int -> int

type seed = {
  thinking_budget : int option;
  thinking_enabled : bool option;
}

val for_runtime : name:string -> seed

val validate_max_tokens_within_ceiling :
  runtime_id:string ->
  provider_ceiling:int option ->
  int ->
  (int, Keeper_internal_error.masc_internal_error) result
