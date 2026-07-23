(** Typed provider/runtime observations for SDK errors crossing from OAS into
    MASC.

    This module deliberately does not classify keeper tool invocation or task
    workflow rejections. Those are MASC domain outcomes, not provider/runtime
    failures. It also does not decide Keeper lifecycle transitions. *)

type stream_idle_state =
  | Awaiting_first_event
  | Awaiting_first_delta
  | Streaming_answer
  | Streaming_thinking
  | Streaming_tool_call
  | Streaming_heartbeat
  | Streaming_substrate
  | Streaming_done
  | Streaming_unknown

val stream_idle_state_to_label : stream_idle_state -> string
val stream_idle_state_of_label : string -> stream_idle_state option
val stream_idle_state_is_activity : stream_idle_state -> bool

type timeout_phase =
  | First_token
  | Http_operation
  | Non_streaming_body
  | Stream_body
  | Stream_idle of stream_idle_state
  | Provider_step
  | Cli_stdout_idle
  | Caller_budget
  | Wall_clock
  | Capacity_backpressure
  | Unknown_timeout

val timeout_phase_to_label : timeout_phase -> string
val timeout_phase_of_label : string -> timeout_phase option
val timeout_phase_is_streaming_activity : timeout_phase -> bool

type timeout_source =
  | Oas_api
  | Oas_provider

type provider_timeout =
  { phase : timeout_phase option
  ; source : timeout_source
  }

type t =
  | Provider_timeout of provider_timeout
  | Not_provider_runtime_failure

val classify_sdk_error : Agent_sdk.Error.sdk_error -> t

val classify_provider_runtime_error_record
  :  code:string
  -> detail:string
  -> t
(** Classify a persisted [Provider_runtime_error] catch-all record.  This is
    narrower than parsing arbitrary messages: it only recognizes the OAS
    provider timeout wire markers such as
    ["provider_error_timeout:http_operation"]. [detail] remains in the
    signature for existing callers, but is not trusted for classification. *)

val is_provider_timeout : t -> bool
val is_provider_timeout_error : Agent_sdk.Error.sdk_error -> bool
