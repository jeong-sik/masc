let resolve_temperature ~runtime_id:_ ~fallback = fallback ()

let resolve_max_tokens ~runtime_id:_ ~fallback = fallback ()

let cap_max_tokens_to_runtime_ceiling ~runtime_id:_ ~source:_ value = value

type seed = {
  thinking_budget : int option;
  thinking_enabled : bool option;
}

(** Map a model's [thinking-support] capability (runtime.toml SSOT) to the
    keeper thinking seed.

    The keeper turn loop ([Keeper_run_tools_hooks]) consumes [thinking_enabled]
    as a capability gate: [Some false] forces thinking OFF for the turn — a
    model declared [thinking-support = false] (e.g. Qwen lanes kept out of
    thinking mode to avoid token exhaustion) never thinks regardless of the
    [keeper.turn.enable_thinking] policy — while [Some true]/[None] defer to
    that policy.

    [None] argument means the runtime id is not in the loaded config (unknown
    id, or before [Runtime.init_default]): no per-model signal, defer to policy.

    [thinking_budget] stays [None] here: the per-model [max_thinking_budget] is
    a ceiling, not an active budget, so wiring it as the active budget would be
    a category error — the keeper's adaptive budget owns the active value. *)
let seed_of_thinking_support (thinking_support : bool option) : seed =
  { thinking_budget = None; thinking_enabled = thinking_support }
;;

let for_runtime ~name =
  seed_of_thinking_support (Runtime.thinking_support_of_runtime_id name)
;;

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
