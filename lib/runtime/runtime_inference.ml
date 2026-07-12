(* Per-runtime sampling temperature. A model may declare a fixed [temperature]
   in runtime.toml ([models.<id>.temperature], read via
   [Runtime.temperature_of_runtime_id]); when set, that value is the request
   temperature at every inference boundary for the model. Otherwise the caller's
   subsystem fallback stands (keeper turn, deterministic compaction, or HITL
   summary policy).

   Completes the previously stubbed per-runtime [resolve_temperature] (the
   [~runtime_id:_] passthrough). Required for
   a model that rejects the fleet default value: Kimi K2.7 (kimi-for-coding)
   accepts only temperature = 1.0 and rejects any other at request time
   ("only 1 is allowed for this model"). *)
let resolve_temperature ~runtime_id ~fallback =
  match Runtime.temperature_of_runtime_id runtime_id with
  | Some temperature -> temperature
  | None -> fallback ()

(* masc#24067 / oas#2517: MASC must not synthesize a request [max_tokens]
   value. The former resolver invented one from either a model capability
   ceiling or a flat fallback. Callers now carry explicit intent as [int
   option], and OAS alone owns model-capability validation plus
   envelope-specific clamp/fallback policy. *)

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
