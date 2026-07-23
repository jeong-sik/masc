(** Observation reason helpers for the keeper heartbeat loop. *)

let provider_timeout_observation_reasons =
  [ "provider_runtime_error"; "provider_timeout"; "keeper_turn_retry_backoff" ]
;;

let record_provider_timeout_observation ~base_path ~keeper_name =
  Keeper_registry.record_skip_reasons
    ~base_path
    keeper_name
    ~reasons:provider_timeout_observation_reasons;
  Keeper_registry.touch_last_turn_ts ~base_path keeper_name
;;

let is_provider_timeout_error (err : Agent_sdk.Error.sdk_error) =
  Keeper_provider_runtime_boundary.is_provider_timeout_error err
;;
