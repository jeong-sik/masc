(** Typed provider/runtime observations for agent-core errors crossing from AGENT_CORE into
    MASC.

    This module deliberately does not classify keeper tool invocation or task
    workflow rejections. Those are MASC domain outcomes, not provider/runtime
    failures. It also does not decide Keeper lifecycle transitions. *)

(** What a stream was producing when an idle gap ended it. A stall before
    the first output is {!First_token}; the two "awaiting" labels a reader
    holds before then are never a {!Stream_idle}. *)
type stream_production =
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
  | Stream_idle of stream_production
  | Provider_step
  | Cli_stdout_idle
  | Caller_budget
  | Wall_clock
  | Capacity_backpressure
  | Queue
      (** The wait for a provider admission permit ran out of its bound
          before the permit was granted; nothing was sent. *)
  | Unknown_timeout

type timeout_source = Keeper_turn_terminal_code.timeout_source =
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
(** Classify a registry [Provider_runtime_error] from its typed timeout
    observation when present, preserving the API/provider source and phase.
    Without typed evidence, only existing provider timeout wire markers such as
    ["provider_error_timeout:http_operation"] are recognized. [detail] is
    not trusted for classification. *)

val is_provider_timeout_error : Agent_core.Error.t -> bool
