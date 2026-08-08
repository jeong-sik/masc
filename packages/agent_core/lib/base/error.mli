(** Structured SDK error types.

    Replaces [(_, string) result] with [(_, sdk_error) result] across the SDK.
    Provides human-readable [to_string] for backward-compatible error messages
    and [is_retryable] for automated retry decisions.

    @stability Stable
    @since 0.93.1 *)

module Retry = Llm_provider.Retry

(** {1 Domain error types} *)

(** API errors — same type as {!Retry.api_error}. *)
type api_error = Retry.api_error

(** Provider/runtime errors — same type as {!Llm_provider.Error.provider_error}. *)
type provider_error = Llm_provider.Error.provider_error

type input_required =
  { request_id : string
  ; participant_name : string option
  ; question : string
  ; schema : Yojson.Safe.t option
  ; timeout_s : float option
  ; created_at : float
  }

(** Proof that a terminal error is closed against another provider turn.
    Construction is limited to the two closed canonical dispositions. *)
type closed_terminal_effect

val proven_post_terminal_effect : closed_terminal_effect
val unknown_terminal_effect : closed_terminal_effect

val terminal_effect_disposition
  :  closed_terminal_effect
  -> Tool_contract.failure_effect_disposition

type agent_error =
  | UnrecognizedStopReason of { reason : string }
  | HookExecutionFailed of
      { hook_name : string
      ; stage : string
      ; tool_name : string option
      ; tool_use_id : string option
      ; detail : string
      }
  | TerminalToolEffectFailed of
      { tool_use_id : string
      ; effect_disposition : closed_terminal_effect
      ; detail : string
      }
  | TerminalToolDurabilityFailed of
      { invocation : Tool_contract.Invocation.t
      ; effect_disposition : closed_terminal_effect
      ; detail : string
      }
  | GuardrailViolation of
      { validator : string
      ; reason : string
      }
  | TripwireViolation of
      { tripwire : string
      ; reason : string
      }
  | InputRequired of input_required

type mcp_error =
  | ServerStartFailed of
      { command : string
      ; detail : string
      }
  | InitializeFailed of { detail : string }
  | ToolListFailed of { detail : string }
  | ToolCallFailed of
      { tool_name : string
      ; detail : string
      }
  | HttpTransportFailed of
      { url : string
      ; detail : string
      }

type config_error =
  | MissingEnvVar of { var_name : string }
  | UnsupportedProvider of { detail : string }
  | InvalidConfig of
      { field : string
      ; detail : string
      }
  | SensitiveValueInConfig of { detail : string }

type serialization_error =
  | JsonParseError of { detail : string }
  | VersionMismatch of
      { expected : int
      ; got : int
      }
  | UnknownVariant of
      { type_name : string
      ; value : string
      }

type io_error =
  | FileOpFailed of
      { op : string
      ; path : string
      ; detail : string
      }
  | ValidationFailed of { detail : string }

type orchestration_error =
  | UnknownAgent of { name : string }
  | TaskTimeout of { task_id : string }
  | DiscoveryFailed of
      { url : string
      ; detail : string
      }

(** {1 Top-level error} *)

type sdk_error =
  | Api of api_error
  | Provider of provider_error
  | Agent of agent_error
  | Mcp of mcp_error
  | Config of config_error
  | Serialization of serialization_error
  | Io of io_error
  | Orchestration of orchestration_error
  | Internal of string

(** Non-identifying top-level category derived from an [sdk_error].
    This projection is for observation only; it does not define retry,
    fallback, or scheduling policy. *)
type category =
  | Api_category
  | Provider_category
  | Agent_category
  | Mcp_category
  | Config_category
  | Serialization_category
  | Io_category
  | Orchestration_category
  | Internal_category

(** {1 Operations} *)

(** Project an SDK error to its top-level category. *)
val category : sdk_error -> category

(** Canonical observation label for a top-level category. *)
val category_label : category -> string

(** Human-readable error message. *)
val to_string : sdk_error -> string

(** Whether the error is transient and the operation can be retried. *)
val is_retryable : sdk_error -> bool
