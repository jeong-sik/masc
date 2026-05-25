val fallback_cascade_for_provider_cooldown :
  base_cascade:string ->
  effective_cascade:string ->
  string option

val provider_cooldown_remaining_sec_for_cascade :
  cascade_name:Cascade_name.t -> int option

val provider_capacity_blocked_task_count :
  ?provider_cooldown_remaining_sec:(cascade_name:Cascade_name.t -> int option) ->
  meta:Keeper_types.keeper_meta ->
  claimable_task_count:int ->
  unit ->
  int
