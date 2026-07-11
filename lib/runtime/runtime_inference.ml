(* Per-runtime sampling temperature. A model may declare a fixed [temperature]
   in runtime.toml ([models.<id>.temperature], read via
   [Runtime.temperature_of_runtime_id]); when set, that value is the request
   temperature at every inference boundary for the model. Otherwise the caller's
   subsystem fallback stands (keeper turn, deterministic compaction, or HITL
   summary policy).

   Completes the previously stubbed per-runtime [resolve_temperature] (the
   [~runtime_id:_] passthrough), symmetric to [resolve_max_tokens]. Required for
   a model that rejects the fleet default value: Kimi K2.7 (kimi-for-coding)
   accepts only temperature = 1.0 and rejects any other at request time
   ("only 1 is allowed for this model"). *)
let resolve_temperature ~runtime_id ~fallback =
  match Runtime.temperature_of_runtime_id runtime_id with
  | Some temperature -> temperature
  | None -> fallback ()

(* A reasoning runtime sizes its turn from the model's own declared output
   ceiling (OAS capability catalog [max_output_tokens], the value SSOT, read via
   [Runtime.max_output_tokens_of_runtime_id]) — the full ceiling, with no
   MASC-side bound on top. A reasoning model spends part of one response on
   thinking before emitting the answer; both share the single [max_tokens]
   budget, so any bound below the model's real ceiling can be exhausted by
   thinking alone and truncates the turn mid-thought (stop_reason=max_tokens,
   content=[thinking], no visible reply). The former 32768 operational clamp
   did exactly that on the live fleet default (glm-5-turbo, declared ceiling
   131072 → requested 32768); budgets are aggregation-only, never a control
   that cuts a conversation.

   When the catalog projects NO ceiling for the runtime, fall back to the
   caller's flat budget rather than inventing a value: with no provider
   ceiling known, a large request could exceed what the provider accepts and
   turn a thinking truncation into a max_tokens rejection. Non-reasoning
   runtimes keep the caller's flat [fallback] unchanged. Raising or bounding a
   specific model is a catalog change (declare [max_output_tokens]); the value
   lives in the model catalog, not here. Provider-side overshoot protection is
   the OAS backend clamp to the per-model catalog cap (clamp + one-shot WARN). *)
let resolve_max_tokens ~runtime_id ~fallback =
  match Runtime.thinking_support_of_runtime_id runtime_id with
  | Some true ->
    (match Runtime.max_output_tokens_of_runtime_id runtime_id with
     | Some ceiling -> ceiling
     | None -> fallback ())
  | Some false | None -> fallback ()

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
