val provider_timeout_guard_sec : float
val min_provider_timeout_budget_sec : float

type provider_timeout_budget = {
  effective_timeout_sec : float;
  adaptive_timeout_sec : float;
  keeper_turn_timeout_sec : float;
  remaining_turn_budget_sec : float;
  estimated_input_tokens : int;
  source : string;
}

val provider_timeout_budget_to_yojson : provider_timeout_budget -> Yojson.Safe.t

val resolve_provider_timeout_budget :
  is_retry:bool ->
  estimated_input_tokens:int ->
  remaining_turn_budget_s:float ->
  provider_timeout_budget
