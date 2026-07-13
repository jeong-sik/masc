(** Observation reason helpers for the keeper heartbeat loop. *)

val provider_timeout_observation_reasons : string list

val record_provider_timeout_observation
  :  base_path:string
  -> keeper_name:string
  -> unit

val is_provider_timeout_error : Agent_sdk.Error.sdk_error -> bool
