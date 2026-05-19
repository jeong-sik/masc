(* Keeper_unified_turn_pre_dispatch — RFC-0136 PR-3.

   Extracted from keeper_unified_turn.ml (L166-228) during the
   run_keeper_cycle stage decomposition. Owns the cascade-execution
   builder + unified-max-tokens fallback. *)

open Keeper_types
open Keeper_exec_context

module KCP = Keeper_cascade_profile

let resolve_unified_max_tokens_fallback
      ~(meta_name : string)
      ~(profile_defaults : Keeper_types_profile.keeper_profile_defaults)
      ()
  =
  match
    Keeper_types_profile.unified_max_tokens_override_of_oas_env
      ~keeper_name:meta_name
      profile_defaults.oas_env
  with
  | Some value -> value
  | None -> Keeper_config.keeper_unified_max_tokens ()

let build_cascade_execution
      ~(meta : keeper_meta)
      ~(profile_defaults : Keeper_types_profile.keeper_profile_defaults)
      ~(cascade_name : KCP.runtime_name)
  : ( Keeper_turn_cascade_budget.cascade_execution
    , Agent_sdk.Error.sdk_error )
    result
  =
  let cascade_name_string = KCP.runtime_name_to_string cascade_name in
  let meta_for_cascade = set_cascade_name cascade_name_string meta in
  let model_labels =
    Keeper_coordination.effective_model_labels_for_turn meta_for_cascade
  in
  match ensure_api_keys_for_labels model_labels with
  | Error e -> Error (Agent_sdk.Error.Internal e)
  | Ok () ->
    (match
       Keeper_turn_helpers.ensure_local_discovery_ready model_labels
     with
     | Error e -> Error (Agent_sdk.Error.Internal e)
     | Ok () ->
       let max_context_resolution =
         Keeper_exec_context.resolve_max_context_resolution
           ~requested_override:meta.max_context_override
           model_labels
       in
       let max_context =
         Keeper_turn_cascade_budget.resolved_max_context_for_turn
           ~meta
           model_labels
       in
       let temperature =
         Cascade_inference.resolve_temperature
           ~cascade_name
           ~fallback:Keeper_config.keeper_unified_temperature
       in
       let raw_max_tokens =
         Cascade_inference.resolve_max_tokens
           ~cascade_name
           ~fallback:
             (resolve_unified_max_tokens_fallback
                ~meta_name:meta.name
                ~profile_defaults)
       in
       let max_output_ceiling =
         Cascade_runtime.max_output_tokens_ceiling_of_cascade_name
           cascade_name
       in
       (match
          Cascade_inference.validate_max_tokens_within_ceiling
            ~cascade_name
            ~provider_ceiling:max_output_ceiling
            raw_max_tokens
        with
        | Error err ->
          Error
            (Cascade_error_classify.sdk_error_of_masc_internal_error err)
        | Ok max_tokens ->
          Ok
            { Keeper_turn_cascade_budget.cascade_name
            ; max_context_resolution
            ; max_context
            ; temperature
            ; max_tokens
            }))
