val default_capacity_backpressure_backoff_sec : float

val sdk_error_capacity_backpressure_retry_after_s :
  Agent_sdk.Error.sdk_error -> float option option

type capacity_backpressure_retry_hint =
  | Cbr_explicit of float
  | Cbr_synthetic_default of float

val sdk_error_capacity_backpressure_source :
  Agent_sdk.Error.sdk_error ->
  Cascade_error_classify.capacity_backpressure_source option

val sdk_error_capacity_backpressure_retry_hint :
  Agent_sdk.Error.sdk_error ->
  capacity_backpressure_retry_hint option

val sdk_error_soft_rate_limited :
  Agent_sdk.Error.sdk_error -> float option option
