let resolve_temperature ~runtime_id:_ ~fallback = fallback ()

let resolve_max_tokens ~runtime_id:_ ~fallback = fallback ()

let cap_max_tokens_to_runtime_ceiling ~runtime_id:_ ~source:_ value = value

type seed = {
  thinking_budget : int option;
  thinking_enabled : bool option;
}

let for_runtime ~name:_ = { thinking_budget = None; thinking_enabled = None }

let validate_max_tokens_within_ceiling ~runtime_id ~provider_ceiling value =
  match provider_ceiling with
  | None -> Ok value
  | Some ceiling when value <= ceiling -> Ok value
  | Some provider_ceiling ->
    Error
      (Keeper_internal_error.Max_tokens_ceiling_violation
         { runtime_id
         ; requested_max_tokens = value
         ; provider_ceiling
         ; reason = "requested max_tokens exceeds provider ceiling"
         })
