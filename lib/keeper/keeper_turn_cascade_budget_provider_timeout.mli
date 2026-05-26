val provider_timeout_guard_sec : float
val min_provider_timeout_budget_sec : float
val first_attempt_degraded_retry_reserve_sec : float

type provider_timeout_budget = {
  effective_timeout_sec : float;
  adaptive_timeout_sec : float;
  keeper_turn_timeout_sec : float;
  remaining_turn_budget_sec : float;
  estimated_input_tokens : int;
  max_turns : int;
  source : string;
}

val provider_timeout_budget_to_yojson : provider_timeout_budget -> Yojson.Safe.t

val resolve_bounded_provider_timeout_budget_with_turn_budget :
  allow_wall_clock_retry_budget:bool ->
  is_retry:bool ->
  estimated_input_tokens:int ->
  max_turns:int ->
  remaining_turn_budget_s:float ->
  provider_timeout_budget option

val bounded_provider_timeout_for_turn_budget_with_turn_budget :
  estimated_input_tokens:int ->
  max_turns:int ->
  remaining_turn_budget_s:float ->
  float option

val allow_wall_clock_retry_budget_for_attempt :
  is_retry:bool ->
  degraded_rotation_first_attempt:bool ->
  attempt:int ->
  attempted_cascades:string list ->
  bool

val bounded_provider_timeout_for_turn_budget :
  estimated_input_tokens:int ->
  remaining_turn_budget_s:float ->
  float option

val provider_retry_budget_available_for_turn :
  allow_wall_clock_retry_budget:bool ->
  is_retry:bool ->
  estimated_input_tokens:int ->
  max_turns:int ->
  remaining_turn_budget_s:float ->
  bool
