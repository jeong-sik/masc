(** Typed provider/runtime observations for agent-core errors crossing from AGENT_CORE into
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

type timeout_source =
  | Agent_core_api
  | Agent_core_provider

type provider_timeout =
  { phase : timeout_phase option
  ; source : timeout_source
  }

type t =
  | Provider_timeout of provider_timeout
  | Not_provider_runtime_failure

val classify_core_error : Agent_core.Error.t -> t

val classify_provider_runtime_error_record
  :  ?agent_core_timeout:Keeper_turn_terminal_code.agent_core_timeout
  -> code:string
  -> detail:string
  -> unit
  -> t
(** Classify a persisted [Provider_runtime_error] catch-all record.  This is
    narrower than parsing arbitrary messages: it only recognizes the AGENT_CORE
    provider timeout wire markers such as
    ["provider_error_timeout:http_operation"]. [detail] remains in the
    signature for existing callers, but is not trusted for classification. *)

val is_provider_timeout_error : Agent_core.Error.t -> bool
