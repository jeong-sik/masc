open Keeper_types

module Types = Keeper_social_model_types

let active_model_of_meta (meta : keeper_meta) =
  match Types.model_id_of_string meta.social_model with
  | Some model_id -> model_id
  | None -> Types.default_model_id

let apply_to_result ~(meta : keeper_meta)
    ~(observation : Keeper_world_observation.world_observation)
    (result : Keeper_agent_run.run_result) =
  match active_model_of_meta meta with
  | Types.Bdi_speech_v1 ->
      Keeper_social_model_bdi_speech_v1.apply_to_result ~meta ~observation
        result

let derive_failure_state ~(meta : keeper_meta)
    ~(observation : Keeper_world_observation.world_observation)
    ~(reason : string) =
  match active_model_of_meta meta with
  | Types.Bdi_speech_v1 ->
      Keeper_social_model_bdi_speech_v1.derive_failure_state ~meta
        ~observation ~reason
