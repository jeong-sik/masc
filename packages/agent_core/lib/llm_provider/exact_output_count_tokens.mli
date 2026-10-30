(** Private exact-output CountTokens adapter.

    This module is a Dune [private_module]. Only the Exact_output Single Surface
    may freeze or dispatch these artifacts. *)

type completion_request_measurement = private
  { input_count : Input_token_count.count
  ; output_token_receipt : Types.output_token_receipt
  }

type completion_request_error =
  | Input_count_failed of Input_token_count.error
  | Output_token_resolution_failed of Types.required_output_token_error
  | Invalid_completion_request of string

type measurement_transport_stage =
  | Measurement_before_dispatch
  | Measurement_dispatch_started
  | Measurement_response_received of int

type 'callback_error completion_request_dispatch_error =
  | Completion_request_failed of completion_request_error * measurement_transport_stage
  | Before_dispatch_failed of 'callback_error

type 'callback_error measurement_dispatch_intent

val create_measurement_dispatch_intent
  :  commit_fence:(unit -> (unit, 'callback_error) result)
  -> mark_dispatch_started:(unit -> unit)
  -> 'callback_error measurement_dispatch_intent

type exact_completion_measurement_request
type exact_completion_artifact

val supports_completion_request_measurement : Provider_config.t -> bool

val freeze_exact_completion_artifact
  :  anthropic_thinking_control:Capabilities.anthropic_thinking_control option
  -> Llm_transport.completion_request
  -> (exact_completion_artifact, completion_request_error) result

val exact_completion_generation_body : exact_completion_artifact -> string

val exact_completion_measurement_request
  :  exact_completion_artifact
  -> exact_completion_measurement_request

val measure_exact_completion_request
  :  ?clock:_ Eio.Time.clock
  -> net:[ `Generic | `Unix ] Eio.Net.ty Eio.Resource.t
  -> dispatch_intent:'callback_error measurement_dispatch_intent
  -> exact_completion_measurement_request
  -> ( completion_request_measurement
       , 'callback_error completion_request_dispatch_error )
       result

module For_testing : sig
  val generation_serializer_invocation_count : unit -> int
end
