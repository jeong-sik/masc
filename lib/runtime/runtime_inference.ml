(* Per-runtime sampling temperature. A model may declare a fixed [temperature]
   in runtime.toml ([models.<id>.temperature], read via
   [Runtime.temperature_of_runtime_id]); when set, that value is the request
   temperature for every turn on the model. Otherwise the caller [fallback]
   ([Keeper_config.keeper_unified_temperature], i.e. [MASC_KEEPER_UNIFIED_TEMP])
   stands.

   Completes the previously stubbed per-runtime [resolve_temperature] (the
   [~runtime_id:_] passthrough), symmetric to [resolve_max_tokens]. Required for
   a model that rejects the fleet default value: Kimi K2.7 (kimi-for-coding)
   accepts only temperature = 1.0 and rejects any other at request time
   ("only 1 is allowed for this model"). *)
let resolve_temperature ~runtime_id ~fallback =
  match Runtime.temperature_of_runtime_id runtime_id with
  | Some temperature -> temperature
  | None -> fallback ()

(* Upper bound on a reasoning turn's [max_tokens]. A reasoning model spends part
   of one response on thinking before emitting the answer; both share the single
   [max_tokens] budget. The flat keeper fallback (8192) is too small for that
   combined budget, so thinking alone can exhaust it and the turn truncates
   mid-thinking (stop_reason=max_tokens, content=[thinking]) with no visible
   reply. Live fleet trace (2026-06-30, 111 trajectories): 73
   thinking_only+max_tokens rejections, 60% on runpod_mtp.

   This is a TOTAL-budget bump, not a [thinking.budget_tokens]-style sub-budget
   reservation: the answer is not carved out of a thinking allotment, the whole
   turn simply gets more room. 32768 = 4x the 8192 keeper fallback, enough for
   the observed thinking lengths plus an answer, while bounding a runaway
   reasoning loop well below provider ceilings (e.g. deepseek 384000).

   This constant is ONLY an upper bound applied on top of a model's declared
   OAS ceiling; it is never the request value on its own (see [resolve_max_tokens]). *)
let reasoning_turn_max_tokens = 32_768

(* A reasoning runtime sizes its turn from the model's own declared output
   ceiling (OAS capability catalog [max_output_tokens], the value SSOT, read via
   [Runtime.max_output_tokens_of_runtime_id]), bounded above by
   [reasoning_turn_max_tokens]. A model whose declared ceiling is below the bound
   keeps its smaller ceiling so the request never exceeds what the provider
   accepts (the OAS backend would otherwise clamp and warn).

   When the catalog projects NO ceiling for the runtime, fall back to the
   caller's flat budget rather than inventing [reasoning_turn_max_tokens] as the
   request value: with no provider ceiling known, requesting 32768 could exceed
   what the provider accepts and turn a thinking truncation into a max_tokens
   rejection. The budget increase is gated on an OAS-declared ceiling, so the
   value's source stays the model catalog (SSOT). Non-reasoning runtimes keep the
   caller's flat [fallback] unchanged.

   Completes the previously stubbed per-runtime [resolve_max_tokens] (the
   [~runtime_id:_] passthrough). Raising a specific reasoning model toward the
   bound is a catalog change (declare a higher [max_output_tokens]); the value
   lives in the model catalog, not here. *)
let resolve_max_tokens ~runtime_id ~fallback =
  match Runtime.thinking_support_of_runtime_id runtime_id with
  | Some true ->
    (match Runtime.max_output_tokens_of_runtime_id runtime_id with
     | Some ceiling -> min ceiling reasoning_turn_max_tokens
     | None -> fallback ())
  | Some false | None -> fallback ()

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

    [thinking_budget] carries the per-model [max-thinking-budget] ceiling
    (RFC-0271 §4.2). It is not a bypass of the keeper's adaptive budget: the
    adaptive step ([Keeper_agent_prompt_metrics.adaptive_thinking_budget]) seeds
    from this value and may lower it (e.g. to 1500 on a tool-error retry), so the
    ceiling is the adaptive UPPER bound. The SDK converts the resulting budget to
    a bounded reasoning effort ([Reasoning_effort.of_budget]) for
    reasoning-effort/thinking-object models. [None] — every runtime today, since
    no [max-thinking-budget] is configured — preserves the prior wire exactly. *)
let seed_of_thinking_support
      ?(preserve_thinking = None)
      ?(thinking_budget = None)
      (thinking_support : bool option)
  : seed
  =
  { thinking_budget; thinking_enabled = thinking_support; preserve_thinking }
;;

let for_runtime ~name =
  seed_of_thinking_support
    ~preserve_thinking:(Runtime.preserve_thinking_of_runtime_id name)
    ~thinking_budget:(Runtime.max_thinking_budget_of_runtime_id name)
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
