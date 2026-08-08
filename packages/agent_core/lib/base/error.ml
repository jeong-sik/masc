(** Structured SDK error types — 2-level hierarchy.

    Domain-specific inner types wrap context-rich payloads.
    The top-level [sdk_error] sum type unifies all error domains
    for a single [(_, sdk_error) result] return type across the SDK.

    Design decisions:
    - [api_error] is a type alias for {!Retry.api_error} (no duplication).
    - [Internal] is reserved for unreachable SDK invariant failures.
    - [to_string] produces human-readable messages compatible with v0.8.x. *)

module Retry = Llm_provider.Retry

(** API errors — alias for {!Retry.api_error}. *)
type api_error = Retry.api_error

(** Provider/runtime errors — alias for {!Llm_provider.Error.provider_error}. *)
type provider_error = Llm_provider.Error.provider_error

type input_required =
  { request_id : string
  ; participant_name : string option
  ; question : string
  ; schema : Yojson.Safe.t option
  ; timeout_s : float option
  ; created_at : float
  }

type closed_terminal_effect = Tool_contract.failure_effect_disposition

let proven_post_terminal_effect = Tool_contract.Proven_post_effect
let unknown_terminal_effect = Tool_contract.Effect_outcome_unknown
let terminal_effect_disposition disposition = disposition

(** Agent runtime errors. *)
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

(** MCP client errors. *)
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

(** Configuration errors. *)
type config_error =
  | MissingEnvVar of { var_name : string }
  | UnsupportedProvider of { detail : string }
  | InvalidConfig of
      { field : string
      ; detail : string
      }
  | SensitiveValueInConfig of { detail : string }

(** Serialization / deserialization errors. *)
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

(** File I/O and validation errors. *)
type io_error =
  | FileOpFailed of
      { op : string
      ; path : string
      ; detail : string
      }
  | ValidationFailed of { detail : string }

(** Multi-agent orchestration errors. *)
type orchestration_error =
  | UnknownAgent of { name : string }
  | TaskTimeout of { task_id : string }
  | DiscoveryFailed of
      { url : string
      ; detail : string
      }

(** Top-level SDK error. *)
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

let category : sdk_error -> category = function
  | Api _ -> Api_category
  | Provider _ -> Provider_category
  | Agent _ -> Agent_category
  | Mcp _ -> Mcp_category
  | Config _ -> Config_category
  | Serialization _ -> Serialization_category
  | Io _ -> Io_category
  | Orchestration _ -> Orchestration_category
  | Internal _ -> Internal_category
;;

let category_label : category -> string = function
  | Api_category -> "api"
  | Provider_category -> "provider"
  | Agent_category -> "agent"
  | Mcp_category -> "mcp"
  | Config_category -> "config"
  | Serialization_category -> "serialization"
  | Io_category -> "io"
  | Orchestration_category -> "orchestration"
  | Internal_category -> "internal"
;;

(* ── Human-readable messages ──────────────────────────────────────── *)

let agent_error_to_string = function
  | UnrecognizedStopReason r ->
    Printf.sprintf "Unrecognized stop_reason from API: %s" r.reason
  | HookExecutionFailed r ->
    Printf.sprintf
      "Hook %s failed at %s%s: %s"
      r.hook_name
      r.stage
      (match r.tool_name, r.tool_use_id with
       | Some tool_name, Some tool_use_id ->
         Printf.sprintf " for tool %s (%s)" tool_name tool_use_id
       | Some tool_name, None -> Printf.sprintf " for tool %s" tool_name
       | None, Some tool_use_id -> Printf.sprintf " for tool use %s" tool_use_id
       | None, None -> "")
      r.detail
  | TerminalToolEffectFailed r ->
    Printf.sprintf
      "Terminal tool use %s failed at %s: %s"
      r.tool_use_id
      (match terminal_effect_disposition r.effect_disposition with
       | Tool_contract.Proven_pre_effect -> "a proven pre-effect boundary"
       | Tool_contract.Proven_post_effect -> "a proven post-effect boundary"
       | Tool_contract.Effect_outcome_unknown -> "an unknown effect boundary")
      r.detail
  | TerminalToolDurabilityFailed r ->
    Printf.sprintf
      "Terminal tool use %s lost durable settlement at %s: %s"
      (Tool_contract.Invocation.tool_use_id r.invocation)
      (match terminal_effect_disposition r.effect_disposition with
       | Tool_contract.Proven_pre_effect -> "a proven pre-effect boundary"
       | Tool_contract.Proven_post_effect -> "a proven post-effect boundary"
       | Tool_contract.Effect_outcome_unknown -> "an unknown effect boundary")
      r.detail
  | GuardrailViolation r ->
    Printf.sprintf "Guardrail violation [%s]: %s" r.validator r.reason
  | TripwireViolation r ->
    Printf.sprintf "Tripwire violation [%s]: %s" r.tripwire r.reason
  | InputRequired r ->
    Printf.sprintf
      "Input required%s: %s (request %s)"
      (match r.participant_name with
       | Some participant -> Printf.sprintf " for %s" participant
       | None -> "")
      r.question
      r.request_id
;;

let mcp_error_to_string = function
  | ServerStartFailed r ->
    Printf.sprintf "Failed to start MCP server '%s': %s" r.command r.detail
  | InitializeFailed r -> Printf.sprintf "MCP initialize failed: %s" r.detail
  | ToolListFailed r -> Printf.sprintf "MCP tools/list failed: %s" r.detail
  | ToolCallFailed r ->
    Printf.sprintf "MCP tools/call '%s' failed: %s" r.tool_name r.detail
  | HttpTransportFailed r ->
    Printf.sprintf "MCP HTTP transport failed for %s: %s" r.url r.detail
;;

let config_error_to_string = function
  | MissingEnvVar r -> Printf.sprintf "Missing env var: %s" r.var_name
  | UnsupportedProvider r -> Printf.sprintf "Unsupported provider: %s" r.detail
  | InvalidConfig r -> Printf.sprintf "Invalid config '%s': %s" r.field r.detail
  | SensitiveValueInConfig r -> Printf.sprintf "Sensitive value in config: %s" r.detail
;;

let serialization_error_to_string = function
  | JsonParseError r -> Printf.sprintf "JSON parse error: %s" r.detail
  | VersionMismatch r ->
    Printf.sprintf "Version mismatch: expected %d, got %d" r.expected r.got
  | UnknownVariant r -> Printf.sprintf "Unknown %s variant: %s" r.type_name r.value
;;

let io_error_to_string = function
  | FileOpFailed r -> Printf.sprintf "File %s failed on %s: %s" r.op r.path r.detail
  | ValidationFailed r -> Printf.sprintf "Validation failed: %s" r.detail
;;

let orchestration_error_to_string = function
  | UnknownAgent r -> Printf.sprintf "Unknown agent: %s" r.name
  | TaskTimeout r -> Printf.sprintf "Task timed out: %s" r.task_id
  | DiscoveryFailed r -> Printf.sprintf "Agent discovery failed for %s: %s" r.url r.detail
;;

let to_string = function
  | Api err -> Retry.error_message err
  | Provider err -> Llm_provider.Error.to_string err
  | Agent err -> agent_error_to_string err
  | Mcp err -> mcp_error_to_string err
  | Config err -> config_error_to_string err
  | Serialization err -> serialization_error_to_string err
  | Io err -> io_error_to_string err
  | Orchestration err -> orchestration_error_to_string err
  | Internal msg -> Printf.sprintf "Internal error: %s" msg
;;

(* ── Retryability ─────────────────────────────────────────────────── *)

let is_retryable = function
  | Api err -> Retry.is_retryable err
  | Provider err -> Llm_provider.Error.is_retryable err
  | Mcp (InitializeFailed _ | ToolListFailed _ | ToolCallFailed _ | HttpTransportFailed _)
    -> true
  | Mcp _ -> false
  | Agent _ | Config _ | Serialization _ | Io _ | Orchestration _ | Internal _ -> false
;;
