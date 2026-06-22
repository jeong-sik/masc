open Keeper_types
open Keeper_meta_contract
open Keeper_types_profile

module Types = Keeper_social_model_types

let active_model_of_meta (meta : keeper_meta) =
  match Types.model_id_of_string meta.social_model with
  | Some model_id -> model_id
  | None -> Types.default_model_id

let apply_to_result ?(turn_ref : Ids.Turn_ref.t option) ~(meta : keeper_meta)
    ~(previous_state : Types.social_state option)
    (result : Keeper_agent_run.run_result) =
  match active_model_of_meta meta with
  | Types.Bdi_speech_v1 ->
      Keeper_social_model_bdi_speech_v1.apply_to_result ?turn_ref ~meta
        ~previous_state result

let derive_failure_state ~(meta : keeper_meta)
    ~(observation : Keeper_world_observation.world_observation)
    ~(previous_state : Types.social_state option)
    ~(is_auto_recoverable : bool)
    ~(sdk_error : Agent_sdk.Error.sdk_error option)
    ~(reason : string) =
  match active_model_of_meta meta with
  | Types.Bdi_speech_v1 ->
      Keeper_social_model_bdi_speech_v1.derive_failure_state ~meta
        ~observation ~previous_state ~is_auto_recoverable ~sdk_error ~reason
