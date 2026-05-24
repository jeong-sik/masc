(** Keeper_turn_driver_provider_health — Provider health filtering and recording.

    Extracted from [keeper_turn_driver.ml] during godfile decomposition.
    All functions are pure wrappers over [Provider_health] — no closure
    captures from [run_named].

    @since God file decomposition *)

let filter_provider_health_fail_open candidates =
  match Provider_health.active () with
  | None -> candidates
  | Some health ->
    Provider_health.filter_healthy health
      ~provider_id:Cascade_runtime_candidate.health_key
      candidates

let record_provider_health_result candidate ~success ~http_status =
  match Provider_health.active () with
  | None -> ()
  | Some health ->
    Provider_health.record_attempt_result health
      ~provider_id:(Cascade_runtime_candidate.health_key candidate)
      ~success
      ~http_status

let record_provider_health_error candidate = function
  | Provider_error.ServerError { code; _ } ->
    record_provider_health_result candidate ~success:false ~http_status:(Some code)
  | Provider_error.CapacityBackpressure _
  | Provider_error.RateLimit _
  | Provider_error.AuthError
  | Provider_error.InvalidRequest _
  | Provider_error.CliWrappedHardQuota _
  | Provider_error.CliWrappedMaxTurns _
  | Provider_error.CliWrappedResumableSession _
  | Provider_error.PermissionDenied _
  | Provider_error.ModelNotFound -> ()
