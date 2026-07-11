(* Keeper_unified_turn_pre_dispatch — RFC-0136 PR-3.

   Extracted from keeper_unified_turn.ml (L166-228) during the
   run_keeper_cycle stage decomposition. Owns the runtime-execution
   builder + unified-max-tokens fallback. *)

open Keeper_types
open Keeper_meta_contract
open Keeper_types_profile
open Keeper_context_runtime

(* masc#24067 / oas#2517: the keeper lane must not synthesize a request
   [max_tokens] value. The only override source is the explicit per-keeper
   env/profile knob; absent that, [None] — no [max_tokens] field goes on the
   request. *)
let resolve_unified_max_tokens_override
      ~(meta_name : string)
      ~(profile_defaults : Keeper_types_profile.keeper_profile_defaults)
      ()
  : int option
  =
  Keeper_types_profile.unified_max_tokens_override_of_oas_env
    ~keeper_name:meta_name
    profile_defaults.oas_env

let build_runtime_execution
      ~(meta : keeper_meta)
      ~(profile_defaults : Keeper_types_profile.keeper_profile_defaults)
      ~(runtime_id : string)
  : ( Keeper_turn_runtime_budget.runtime_execution
    , Agent_sdk.Error.sdk_error )
    result
  =
  let runtime_id = String.trim runtime_id in
  if String.equal runtime_id "" then
    Error (Agent_sdk.Error.Internal "runtime_id must be non-empty")
  else
  let model_labels =
    Keeper_context_runtime.effective_model_labels_for_turn meta
  in
  let log_pre_dispatch_error ~site detail =
    let model_labels_detail =
      match model_labels with
      | [] -> "none"
      | labels -> String.concat "," labels
    in
    Log.Keeper.error
      "%s: pre_dispatch: %s failed for runtime_id=%s model_labels=[%s]: %s"
      meta.name
      site
      runtime_id
      model_labels_detail
      detail
  in
  match Keeper_types_support.ensure_api_keys_for_labels model_labels with
  | Error e ->
    log_pre_dispatch_error ~site:"ensure_api_keys_for_labels" e;
    Error (Agent_sdk.Error.Internal e)
  | Ok () ->
    (match
       Keeper_turn_helpers.ensure_local_discovery_ready model_labels
     with
     | Error e ->
       log_pre_dispatch_error ~site:"ensure_local_discovery_ready" e;
       Error (Agent_sdk.Error.Internal e)
     | Ok () ->
       let max_context_resolution =
         Keeper_context_runtime.resolve_max_context_resolution_of_meta meta
       in
       let max_context =
         Keeper_turn_runtime_budget.resolved_max_context_for_turn
           ~meta
       in
       let temperature =
         Runtime_inference.resolve_temperature
           ~runtime_id
           ~fallback:Keeper_config.keeper_unified_temperature
       in
       let raw_max_tokens =
         resolve_unified_max_tokens_override
           ~meta_name:meta.name
           ~profile_defaults
           ()
       in
       Ok
         { Keeper_turn_runtime_budget.runtime_id
         ; max_context_resolution
         ; max_context
         ; temperature
         ; max_tokens = raw_max_tokens
         })
