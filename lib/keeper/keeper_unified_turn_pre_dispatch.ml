(* Keeper_unified_turn_pre_dispatch — RFC-0136 PR-3.

   Extracted from keeper_unified_turn.ml (L166-228) during the
   run_keeper_cycle stage decomposition. Owns the runtime-execution builder. *)

open Keeper_types
open Keeper_meta_contract
open Keeper_types_profile
open Keeper_context_runtime

let profile_load_error ~keeper_name error =
  Agent_sdk.Error.Config
    (Agent_sdk.Error.InvalidConfig
       { field = "keeper.profile"
       ; detail =
           Printf.sprintf
             "keeper %s profile is invalid: %s"
             keeper_name
             (Keeper_types_profile.keeper_toml_load_error_to_string error)
       })

let load_profile_defaults ~base_path ~keeper_name =
  Keeper_types_profile.load_keeper_profile_defaults_result_for_base_path
    ~base_path
    keeper_name
  |> Result.map_error (profile_load_error ~keeper_name)

let build_runtime_execution
      ~(meta : keeper_meta)
      ~(runtime_id : string)
  : ( Keeper_turn_runtime_budget.runtime_execution
    , Agent_sdk.Error.sdk_error )
    result
  =
  let runtime_id = String.trim runtime_id in
  if String.equal runtime_id "" then
    Error (Agent_sdk.Error.Internal "runtime_id must be non-empty")
  else
  let log_pre_dispatch_error ~site detail =
    Log.Keeper.error
      "%s: pre_dispatch: %s failed for runtime_id=%s: %s"
      meta.name
      site
      runtime_id
      detail
  in
  match
    Keeper_context_runtime.resolve_max_context_resolution_for_runtime_id
      ~requested_override:meta.max_context_override
      ~runtime_id
  with
  | Error error ->
    let detail =
      Keeper_context_runtime.max_context_resolution_error_to_string error
    in
    log_pre_dispatch_error ~site:"resolve_context_window" detail;
    Error
      (Agent_sdk.Error.Config
         (Agent_sdk.Error.InvalidConfig
            { field = "runtime.context_window"; detail }))
  | Ok max_context_resolution ->
    let max_context =
      Keeper_turn_runtime_budget.resolved_max_context_for_turn
        ~meta
        max_context_resolution
    in
    let temperature =
      Runtime_inference.resolve_temperature
        ~runtime_id
        ~fallback:Keeper_config.keeper_unified_temperature
    in
    Ok
      { Keeper_turn_runtime_budget.runtime_id
      ; max_context_resolution
      ; max_context
      ; temperature
      }
