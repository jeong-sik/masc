(** Server Flavor Adapter — per-provider request/response shaping.

    Each provider has quirks in how it expects requests and formats
    responses. The adapter system encapsulates these differences so
    the transport layer only sees a uniform interface.

    Flavors are determined by the [cascade_server_flavor] in
    {!Cascade_phonebook_types} (from TOML [providers.<id>.flavor]).
    The adapter is selected at OAS code level, not TOML level. *)

(* ── Imports ─────────────────────────────────────────────────── *)

type cascade_server_flavor = Cascade_phonebook_types.cascade_server_flavor =
  | Llama_cpp
  | Ollama
  | Vllm
  | Openai
  | Deep_seek
  | Zai_glm
  | Qwen

(* ── Error types ─────────────────────────────────────────────── *)

(** Flavor-specific errors that the transport layer may encounter. *)
type flavor_error =
  | Business_error of { code : int; message : string }
      (** Z.AI/GLM business errors: 1301 (system), 1302 (policy), 1303 (quota) *)
  | Content_filter of string
      (** DeepSeek content_filter finish_reason *)
  | Tools_stream_incompatible
      (** Qwen: tools + stream=True not supported *)
  | Reasoning_budget_exceeded
      (** Thinking budget exceeded model limits *)
  | Unknown_finish_reason of string
      (** Unrecognized finish_reason from provider *)
[@@deriving show, eq]

(* ── Thinking control ────────────────────────────────────────── *)

(** How to encode thinking/reasoning parameters in the request.
    Each flavor has a different wire format. *)
type thinking_control =
  | No_thinking
  | Deep_seek_thinking of { enabled : bool }
      (** {"thinking":{"type":"enabled"|"disabled"}} *)
  | Llama_cpp_thinking of { enable : bool; budget : int option }
      (** {"chat_template_kwargs":{"enable_thinking":bool}} + reasoning_budget *)
  | Openai_reasoning_effort of { effort : string }
      (** {"reasoning_effort":"low"|"medium"|"high"} *)
  | Ollama_think of { think : bool }
      (** {"think":true|false} *)
[@@deriving show, eq]

(** Map generic thinking parameters to flavor-specific wire format. *)
let thinking_control_for_flavor
    (flavor : cascade_server_flavor)
    (thinking_requested : bool)
    (budget : int option)
  : thinking_control =
  match flavor with
  | Llama_cpp ->
    Llama_cpp_thinking { enable = thinking_requested; budget }
  | Ollama ->
    Ollama_think { think = thinking_requested }
  | Openai ->
    (match budget with
     | Some _ -> Openai_reasoning_effort { effort = "high" }
     | None -> Openai_reasoning_effort { effort = "medium" })
  | Deep_seek ->
    Deep_seek_thinking { enabled = thinking_requested }
  | Zai_glm ->
    (* Z.AI/GLM has built-in thinking for GLM-5.x, no external control *)
    No_thinking
  | Vllm ->
    No_thinking
  | Qwen ->
    No_thinking

(* ── Finish reason mapping ───────────────────────────────────── *)

(** Canonical finish reasons across all flavors. *)
type finish_reason =
  | Stop
  | Length
  | Tool_calls
  | Content_filter
  | Error
[@@deriving show, eq]

(** Map a flavor-specific finish_reason string to canonical form. *)
let finish_reason_of_string
    (flavor : cascade_server_flavor)
    (raw : string option)
  : finish_reason =
  match raw with
  | None | Some "" | Some "null" -> Stop  (* Qwen returns null during generation *)
  | Some "stop" -> Stop
  | Some "length" -> Length
  | Some "tool_calls" -> Tool_calls
  | Some "content_filter" -> Content_filter
  | Some "insufficient_system_resource" -> Error  (* DeepSeek-specific *)
  | Some other ->
    (match flavor with
     | Ollama ->
       (match other with
        | "load" | "unload" -> Stop  (* Ollama model loading events *)
        | _ -> Error)
     | _ -> Error)

(* ── Stream chunk ────────────────────────────────────────────── *)

(** Parsed chunk from a streaming response. *)
type stream_chunk =
  | Content_delta of string
  | Thinking_delta of string
  | Tool_call of { index : int; id : string; name : string; arguments : string }
  | Finish of finish_reason
  | Usage of { input_tokens : int; output_tokens : int }
  | Done
[@@deriving show, eq]

(* ── Flavor-specific constraints ─────────────────────────────── *)

(** Per-flavor constraints that the transport layer must respect. *)
type flavor_constraints =
  { supports_tools_with_streaming : bool
  ; supports_response_format : bool
  ; supports_parallel_tool_calls : bool
  ; finish_reason_nullable : bool  (* Qwen returns null during generation *)
  ; arguments_as_json_object : bool  (* Ollama returns JSON object, not string *)
  }
[@@deriving show, eq]

(** Get the constraints for a flavor. *)
let constraints_of_flavor = function
  | Llama_cpp ->
    { supports_tools_with_streaming = true
    ; supports_response_format = true
    ; supports_parallel_tool_calls = true
    ; finish_reason_nullable = false
    ; arguments_as_json_object = false
    }
  | Ollama ->
    { supports_tools_with_streaming = true
    ; supports_response_format = true
    ; supports_parallel_tool_calls = true
    ; finish_reason_nullable = false
    ; arguments_as_json_object = true  (* native /api/chat returns JSON object *)
    }
  | Vllm ->
    { supports_tools_with_streaming = true
    ; supports_response_format = true
    ; supports_parallel_tool_calls = true
    ; finish_reason_nullable = false
    ; arguments_as_json_object = false
    }
  | Openai ->
    { supports_tools_with_streaming = true
    ; supports_response_format = true
    ; supports_parallel_tool_calls = true
    ; finish_reason_nullable = false
    ; arguments_as_json_object = false
    }
  | Deep_seek ->
    { supports_tools_with_streaming = true
    ; supports_response_format = true
    ; supports_parallel_tool_calls = true
    ; finish_reason_nullable = false
    ; arguments_as_json_object = false
    }
  | Zai_glm ->
    { supports_tools_with_streaming = true
    ; supports_response_format = true
    ; supports_parallel_tool_calls = true
    ; finish_reason_nullable = false
    ; arguments_as_json_object = false
    }
  | Qwen ->
    { supports_tools_with_streaming = false  (* CRITICAL: tools + stream=True incompatible *)
    ; supports_response_format = false       (* response_format not supported *)
    ; supports_parallel_tool_calls = true
    ; finish_reason_nullable = true          (* returns null during generation *)
    ; arguments_as_json_object = false
    }

(** Whether this flavor can accept tools when streaming is requested.
    When false, the transport must fall back to non-streaming mode. *)
let can_stream_with_tools (flavor : cascade_server_flavor) : bool =
  (constraints_of_flavor flavor).supports_tools_with_streaming
