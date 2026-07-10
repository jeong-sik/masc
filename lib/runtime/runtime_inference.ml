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

(* A reasoning runtime sizes its turn from the model's own declared output
   ceiling (OAS capability catalog [max_output_tokens], the value SSOT, read via
   [Runtime.max_output_tokens_of_runtime_id]). MASC does not impose a second
   arbitrary ceiling: OAS has already validated the provider/model declaration.

   When the catalog projects no ceiling for the runtime, fall back to the
   caller's explicit value because there is no provider-owned limit to project.
   Non-reasoning runtimes keep the caller's flat [fallback] unchanged.

   Completes the previously stubbed per-runtime [resolve_max_tokens] (the
   [~runtime_id:_] passthrough). The value lives in the OAS model catalog, not
   in a MASC heuristic. *)
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

(** Map OAS's [supports_extended_thinking] capability to the
    keeper thinking seed.

    The keeper turn loop ([Keeper_run_tools_hooks]) consumes [thinking_enabled]
    as an explicit runtime-model policy: [Some false] forces thinking OFF for
    the turn, while [Some true] actively enables thinking for that runtime.
    This keeps a catalog-declared reasoning model enabled even if the legacy
    global default remains false.

    [None] argument means the runtime id is not in the loaded config (unknown
    id, or before [Runtime.init_default]): no per-model signal, leave the
    caller policy unchanged.

    [thinking_budget] stays [None] here: an OAS model capability is not an
    active budget, so wiring it as one would be a category error — the keeper's
    adaptive policy owns the active value. *)
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
