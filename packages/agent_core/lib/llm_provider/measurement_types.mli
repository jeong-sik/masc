type measurement_transport_stage =
  | Measurement_before_dispatch
  | Measurement_dispatch_started
  | Measurement_response_received of int

type completion_request_measurement =
  { input_count : Input_token_count.count
  ; output_token_receipt : Types.output_token_receipt
  }

type completion_request_error =
  | Input_count_failed of Input_token_count.error
  | Output_token_resolution_failed of Types.required_output_token_error
  | Invalid_completion_request of string

val supports_admission_measurement : Provider_config.t -> bool
val supports_exact_artifact_measurement : Provider_config.t -> bool
