let resolve_temperature ~runtime_id:_ ~fallback = fallback ()

let resolve_max_tokens ~runtime_id:_ ~fallback = fallback ()

let cap_max_tokens_to_runtime_ceiling ~runtime_id:_ ~source:_ value = value

type seed = {
  thinking_budget : int option;
  thinking_enabled : bool option;
  preserve_thinking : bool option;
}

(** Map a model's [thinking-support] capability (runtime.toml SSOT) to the
    keeper thinking seed.

    The keeper turn loop ([Keeper_run_tools_hooks]) consumes [thinking_enabled]
    as an explicit runtime-model policy: [Some false] forces thinking OFF for
    the turn, while [Some true] actively enables thinking for that runtime.
    This keeps Qwen3.6 thinking on even if the legacy global default remains
    false.

    [None] argument means the runtime id is not in the loaded config (unknown
    id, or before [Runtime.init_default]): no per-model signal, leave the
    caller policy unchanged.

    [thinking_budget] stays [None] here: the per-model [max_thinking_budget] is
    a ceiling, not an active budget, so wiring it as the active budget would be
    a category error — the keeper's adaptive budget owns the active value. *)
let seed_of_thinking_support ?(preserve_thinking = None) (thinking_support : bool option)
  : seed
  =
  { thinking_budget = None; thinking_enabled = thinking_support; preserve_thinking }
;;

let for_runtime ~name =
  seed_of_thinking_support
    ~preserve_thinking:(Runtime.preserve_thinking_of_runtime_id name)
    (Runtime.thinking_support_of_runtime_id name)
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
