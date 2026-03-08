(** Centralized error types for llm-mcp

    This module provides structured error types to replace string-based errors.
    Benefits:
    - Compile-time exhaustiveness checking
    - Rich error context (not just messages)
    - Better debugging and logging
    - Type-safe error handling

    @since 0.3.0
*)

(** {1 Domain-Specific Errors} *)

(** LLM Provider errors *)
type llm_error =
  | GeminiError of gemini_error
  | ClaudeError of claude_error
  | CodexError of codex_error
  | OllamaError of ollama_error
[@@deriving yojson]

and gemini_error =
  | GeminiFunctionCallSync   (** "number of function response parts" - recoverable *)
  | GeminiContextTooLong     (** Context exceeds limit *)
  | GeminiRateLimit          (** API rate limit *)
  | GeminiAuth               (** Invalid API key *)
  | GeminiUnknown of string  (** Unclassified error *)
[@@deriving yojson]

and claude_error =
  | ClaudeContextTooLong
  | ClaudeRateLimit
  | ClaudeAuth
  | ClaudeTimeout
  | ClaudeUnknown of string
[@@deriving yojson]

and codex_error =
  | CodexRateLimit
  | CodexAuth
  | CodexSandboxViolation
  | CodexTimeout
  | CodexUnknown of string
[@@deriving yojson]

and ollama_error =
  | OllamaNotRunning
  | OllamaModelNotFound of string
  | OllamaTimeout
  | OllamaUnknown of string
[@@deriving yojson]

(** Chain execution errors *)
type chain_error =
  | ChainParseError of string       (** Invalid chain DSL *)
  | ChainCompileError of string     (** Compilation failed *)
  | ChainExecutionError of string   (** Runtime execution error *)
  | ChainTimeoutError of int        (** Timeout in milliseconds *)
  | ChainCycleDetected              (** Cycle in DAG *)
  | ChainNodeNotFound of string     (** Missing node ID *)
  | ChainValidationError of string  (** Schema validation failed *)
[@@deriving yojson]

(** MCP protocol errors *)
type mcp_error =
  | McpParseError of string         (** Invalid JSON-RPC *)
  | McpMethodNotFound of string     (** Unknown method *)
  | McpInvalidParams of string      (** Invalid parameters *)
  | McpAuthError of string          (** Authentication failed *)
  | McpInternalError of string      (** Internal server error *)
[@@deriving yojson]

(** Process/CLI errors *)
type process_error =
  | ProcessTimeout of int           (** Timeout in seconds *)
  | ProcessExitCode of int * string (** Non-zero exit code + stderr *)
  | ProcessSpawnError of string     (** Failed to spawn process *)
  | ProcessKilled                   (** Process was killed *)
[@@deriving yojson]

(** IO/Network errors *)
type io_error =
  | NetworkError of string
  | FileNotFound of string
  | PermissionDenied of string
  | JsonParseError of string
  | EncodingError of string
[@@deriving yojson]

(** {1 Unified Error Type} *)

(** Top-level error type combining all domains *)
type t =
  | Llm of llm_error
  | Chain of chain_error
  | Mcp of mcp_error
  | Process of process_error
  | Io of io_error
  | Internal of string              (** Unexpected internal error *)
[@@deriving yojson]

(** {1 Error Utilities} *)

(** Check if an error is recoverable (safe to retry) *)
let is_recoverable = function
  | Llm (GeminiError GeminiFunctionCallSync) -> true
  | Llm (GeminiError GeminiRateLimit) -> true
  | Llm (ClaudeError ClaudeRateLimit) -> true
  | Llm (CodexError CodexRateLimit) -> true
  | Llm (OllamaError OllamaTimeout) -> true
  | Process (ProcessTimeout _) -> true
  | Io (NetworkError _) -> true
  | _ -> false

(** Get a human-readable error message *)
let to_string = function
  | Llm (GeminiError e) -> (
      match e with
      | GeminiFunctionCallSync -> "Gemini function call sync error (recoverable)"
      | GeminiContextTooLong -> "Gemini context too long"
      | GeminiRateLimit -> "Gemini rate limit exceeded"
      | GeminiAuth -> "Gemini authentication failed"
      | GeminiUnknown msg -> Printf.sprintf "Gemini error: %s" msg)
  | Llm (ClaudeError e) -> (
      match e with
      | ClaudeContextTooLong -> "Claude context too long"
      | ClaudeRateLimit -> "Claude rate limit exceeded"
      | ClaudeAuth -> "Claude authentication failed"
      | ClaudeTimeout -> "Claude request timed out"
      | ClaudeUnknown msg -> Printf.sprintf "Claude error: %s" msg)
  | Llm (CodexError e) -> (
      match e with
      | CodexRateLimit -> "Codex rate limit exceeded"
      | CodexAuth -> "Codex authentication failed"
      | CodexSandboxViolation -> "Codex sandbox policy violated"
      | CodexTimeout -> "Codex request timed out"
      | CodexUnknown msg -> Printf.sprintf "Codex error: %s" msg)
  | Llm (OllamaError e) -> (
      match e with
      | OllamaNotRunning -> "Ollama server not running"
      | OllamaModelNotFound model -> Printf.sprintf "Ollama model not found: %s" model
      | OllamaTimeout -> "Ollama request timed out"
      | OllamaUnknown msg -> Printf.sprintf "Ollama error: %s" msg)
  | Chain e -> (
      match e with
      | ChainParseError msg -> Printf.sprintf "Chain parse error: %s" msg
      | ChainCompileError msg -> Printf.sprintf "Chain compile error: %s" msg
      | ChainExecutionError msg -> Printf.sprintf "Chain execution error: %s" msg
      | ChainTimeoutError ms -> Printf.sprintf "Chain timeout after %dms" ms
      | ChainCycleDetected -> "Chain cycle detected"
      | ChainNodeNotFound id -> Printf.sprintf "Chain node not found: %s" id
      | ChainValidationError msg -> Printf.sprintf "Chain validation error: %s" msg)
  | Mcp e -> (
      match e with
      | McpParseError msg -> Printf.sprintf "MCP parse error: %s" msg
      | McpMethodNotFound method_name -> Printf.sprintf "MCP method not found: %s" method_name
      | McpInvalidParams msg -> Printf.sprintf "MCP invalid params: %s" msg
      | McpAuthError msg -> Printf.sprintf "MCP auth error: %s" msg
      | McpInternalError msg -> Printf.sprintf "MCP internal error: %s" msg)
  | Process e -> (
      match e with
      | ProcessTimeout secs -> Printf.sprintf "Process timeout after %ds" secs
      | ProcessExitCode (code, stderr) -> Printf.sprintf "Process exit code %d: %s" code stderr
      | ProcessSpawnError msg -> Printf.sprintf "Process spawn error: %s" msg
      | ProcessKilled -> "Process was killed")
  | Io e -> (
      match e with
      | NetworkError msg -> Printf.sprintf "Network error: %s" msg
      | FileNotFound path -> Printf.sprintf "File not found: %s" path
      | PermissionDenied path -> Printf.sprintf "Permission denied: %s" path
      | JsonParseError msg -> Printf.sprintf "JSON parse error: %s" msg
      | EncodingError msg -> Printf.sprintf "Encoding error: %s" msg)
  | Internal msg -> Printf.sprintf "Internal error: %s" msg

(** {1 Result Helpers} *)

(** Shorthand for error result type *)
type 'a result = ('a, t) Stdlib.result

(** Create an error result *)
let fail e = Error e

(** Create a success result *)
let ok v = Ok v

(** Map error to string for legacy compatibility *)
let to_string_result = function
  | Ok v -> Ok v
  | Error e -> Error (to_string e)

(** Convert string error to Internal error (for migration) *)
let of_string msg = Internal msg

(** {1 Logging Integration} *)

(** Get error severity level *)
type severity = Debug | Info | Warning | Error | Critical

let severity_of_error = function
  | Llm (GeminiError GeminiFunctionCallSync) -> Warning
  | Llm (GeminiError GeminiRateLimit) -> Warning
  | Llm _ -> Error
  | Chain (ChainParseError _) -> Warning
  | Chain _ -> Error
  | Mcp (McpMethodNotFound _) -> Warning
  | Mcp _ -> Error
  | Process (ProcessTimeout _) -> Warning
  | Process _ -> Error
  | Io _ -> Error
  | Internal _ -> Critical

let string_of_severity = function
  | Debug -> "DEBUG"
  | Info -> "INFO"
  | Warning -> "WARN"
  | Error -> "ERROR"
  | Critical -> "CRITICAL"
