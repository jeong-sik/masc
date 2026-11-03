(** Observation reason helpers for the keeper heartbeat loop. *)

let is_provider_timeout_error (err : Agent_core.Error.t) =
  Keeper_provider_runtime_boundary.is_provider_timeout_error err
;;
