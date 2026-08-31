(** Structured agent-core error types.

    Replaces [(_, string) result] with [(_, t) result] across agent core.
    Provides human-readable [to_string] for stable error messages
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
  | ToolRoundLimitExceeded of
      { rounds : int
      ; limit : int
      }
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

type credential_carrier =
  | InlineCredential
  | FileCredential

type config_error =
  | MissingEnvVar of { var_name : string }
  | UnsupportedProvider of { detail : string }
  | CredentialUnavailable of
      { provider_id : string
      ; carrier : credential_carrier
      }
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

(** Open extension point for host-typed internal payloads (RFC-0371 B12).
    agent-core never constructs or inspects extensions: a host extends
    this type with its own constructor, carries its typed error through
    {!Internal_carried}, and downcasts by matching its constructor back
    out — instead of rendering the error into the {!Internal} message
    string and re-parsing it in the same process. A carrier is process-local:
    serialization and persistence boundaries store [message], and a value
    rehydrated from those bytes has no carrier to downcast. *)
type carrier = ..

type t =
  | Api of api_error
  | Provider of provider_error
  | Agent of agent_error
  | Mcp of mcp_error
  | Config of config_error
  | Serialization of serialization_error
  | Io of io_error
  | Orchestration of orchestration_error
  | Internal of string
  | Internal_carried of
      { message : string
      ; carrier : carrier
      }

(** Non-identifying top-level category derived from a [t].
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

(** Project an agent-core error to its top-level category. *)
val category : t -> category

(** Canonical observation label for a top-level category. *)
val category_label : category -> string

(** Human-readable error message. *)
val to_string : t -> string

(** Whether the error is transient and the operation can be retried. *)
val is_retryable : t -> bool

val of_raised_exn : exn -> t
(** Classify an exception that escaped a call. An Eio timeout — bare, or wrapped
    in [Cancel.Cancelled] when the expiry cancelled a surrounding fiber —
    becomes [Api (Timeout _)]; everything else keeps the [Internal] wording it
    had. Reporting a timeout as [Internal] contradicted this module's own rule
    that [Internal] is for unreachable invariant failures, and left an operator
    unable to tell a bug from a call that ran out of time.

    This decides what an observer is told. It does not decide whether the
    exception propagates: callers re-raise the original, so a cancellation is
    never absorbed. *)
