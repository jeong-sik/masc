val fallback_runtime_for_provider_cooldown :
  base_runtime:string ->
  effective_runtime:string ->
  string option

val provider_cooldown_remaining_sec_for_runtime :
  keeper_name:string -> runtime_id:string -> int option

val provider_capacity_blocked_task_count :
  ?provider_cooldown_remaining_sec:(keeper_name:string -> runtime_id:string -> int option) ->
  meta:Keeper_meta_contract.keeper_meta ->
  claimable_task_count:int ->
  unit ->
  int
