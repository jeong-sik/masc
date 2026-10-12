(** Unified LLM provider types.

    Single source of truth for message, response, tool, and streaming types.
    Downstream consumers link against this module directly.

    @since 0.42.0 *)

(** {1 Message Types} *)

(** Role in a conversation.
    4-variant superset: System and Tool are required by multi-agent
    coordinators that inject system prompts and relay tool results. *)
type role =
  | System
  | User
  | Assistant
  | Tool
[@@deriving yojson, show]

let role_to_string = function
  | System -> "system"
  | User -> "user"
  | Assistant -> "assistant"
  | Tool -> "tool"
;;

let role_of_string = function
  | "system" -> Some System
  | "user" -> Some User
  | "assistant" -> Some Assistant
  | "tool" -> Some Tool
  | _ -> None
;;

(** {1 Tool Types} *)

(* One schema authority, including its private constructor/decoder boundary.
   This public module adds message/response contracts without duplicating any
   schema types or converter implementations. *)
include Tool_schema_contract

(** Tool execution outcome types. *)

type tool_error_class =
  | Transient
  | Deterministic
  | Unknown
[@@deriving yojson, show]

type tool_failure_kind =
  | Validation_error
  | Recoverable_tool_error
  | Non_retryable_tool_error
  | Reported_tool_error
  | Unattributed_tool_error
[@@deriving yojson, show]

type tool_failure_provenance =
  { failure_kind : tool_failure_kind
  ; error_class : tool_error_class option
  }
[@@deriving show]

type tool_result_outcome =
  | Tool_succeeded
  | Tool_failed of tool_failure_provenance
[@@deriving show]

let tool_failure_kind_is_recoverable = function
  | Validation_error | Recoverable_tool_error -> true
  | Non_retryable_tool_error | Reported_tool_error | Unattributed_tool_error -> false
;;

let tool_result_outcome_is_error = function
  | Tool_succeeded -> false
  | Tool_failed _ -> true
;;

type tool_error =
  { message : string
  ; recoverable : bool
  ; error_class : tool_error_class option
  }


(** Tool choice mode *)
type tool_choice =
  | Auto
  | Any
  | Tool of string
  | None_ (** Disables tool use. Anthropic: {type:none}, Openai: "none" *)
[@@deriving show]

let tool_choice_to_json = function
  | Auto -> `Assoc [ "type", `String "auto" ]
  | Any -> `Assoc [ "type", `String "any" ]
  | Tool name -> `Assoc [ "type", `String "tool"; "name", `String name ]
  | None_ -> `Assoc [ "type", `String "none" ]
;;

type response_format =
  | Off
  | JsonMode
  | JsonSchema of Yojson.Safe.t
[@@deriving show]

let response_format_to_json = function
  | Off -> `Assoc [ "type", `String "off" ]
  | JsonMode -> `Assoc [ "type", `String "json_mode" ]
  | JsonSchema schema -> `Assoc [ "type", `String "json_schema"; "schema", schema ]
;;

(** {1 Content Types} *)

(** Closed set of supported media source carriers. *)
type media_source_kind =
  | Base64
  | Url
  | File_id
[@@deriving show]

let media_source_kind_to_string = function
  | Base64 -> "base64"
  | Url -> "url"
  | File_id -> "file_id"
;;

let media_source_kind_of_string raw =
  match String.lowercase_ascii (String.trim raw) with
  | "base64" -> Some Base64
  | "url" -> Some Url
  | "file_id" -> Some File_id
  | _ -> None
;;

type reasoning_detail =
  { raw : Yojson.Safe.t
  ; text : string option
  }
[@@deriving show]

(** Content block types -- inline records for clarity *)
type content_block =
  | Text of string
  | Thinking of
      { content : string
      ; signature : string option
        (** [Some s]: Anthropic cryptographic signature, replayed byte-exact on
            tool turns (never sanitized or re-encoded). Only the Anthropic wire
            parse populates it; every other backend constructs [None].

            [None] says this block carries no signature, not that the provider
            has none. Gemini signs too, and its [thoughtSignature] rides in a
            {!RedactedThinking} carrier instead — see
            [Backend_gemini.gemini_thought_signature_carrier] — which is why
            {!Reasoning_dialect} gives Gemini a replay policy that keeps signed
            parts attached to their exact response part. Reading [None] here as
            "Gemini is signature-less" contradicts that policy and is the
            misreading this paragraph exists to prevent.

            Replaces the former [thinking_type : string], which conflated this
            signature with a free-form provider label ("reasoning" /
            "thinking" / "reasoning_summary") that no consumer read. *)
      }
  | ReasoningDetails of
      { reasoning_content : string option
      ; details : reasoning_detail list
      }
  | RedactedThinking of string
  | ToolUse of
      { id : string
      ; name : string
      ; input : Yojson.Safe.t
      }
  | ToolResult of
      { tool_use_id : string
      ; content : string
      ; outcome : tool_result_outcome
      ; json : Yojson.Safe.t option
        (** Parsed JSON payload when available. Consumers
                        should prefer [json] over [content] for structured access.
                        [content] remains the canonical string for API serialization. *)
      ; content_blocks : content_block list option
        (** Structured multi-block result (e.g. text + image). When [Some],
                        providers that accept an array tool_result content serialize
                        the blocks; [content] stays the canonical string fallback. *)
      }
  | Image of
      { media_type : string
      ; data : string
      ; source_type : media_source_kind
      }
  | Document of
      { media_type : string
      ; data : string
      ; source_type : media_source_kind
      }
  | Audio of
      { media_type : string
      ; data : string
      ; source_type : media_source_kind
      }
[@@deriving show]

type tool_output =
  { content : string
  ; content_blocks : content_block list option
    (** Model-visible structured content. [None] denotes text-only output. *)
  ; _meta : Yojson.Safe.t option
    (** Optional structured metadata forwarded to the MCP [tool_result._meta]
        field. [None] omits the field on the wire. *)
  }

type tool_result = (tool_output, tool_error) result

let tool_result_of_outcome ?content_blocks ~content = function
  | Tool_succeeded -> Ok { content; content_blocks; _meta = None }
  | Tool_failed { failure_kind; error_class } ->
    Error
      { message = content
      ; recoverable = tool_failure_kind_is_recoverable failure_kind
      ; error_class
      }
;;


let reasoning_details_text
      ~(reasoning_content : string option)
      ~(details : reasoning_detail list)
  : string
  =
  let details_text =
    details
    |> List.filter_map (fun (detail : reasoning_detail) -> detail.text)
    |> String.concat ""
  in
  match reasoning_content with
  | Some content -> if content = "" then details_text else content
  | None -> details_text
;;

(** Message metadata: extensible typed key-value pairs attached to a message.
    Keys are caller-defined strings; values are JSON payloads. *)
type metadata = (string * Yojson.Safe.t) list [@@deriving show]

(* Host-owned attribution of a User input: who said it, as the host that
   created the message knows it. AGENT_CORE owns only the key. The payload is
   the host's typed value encoded as JSON; AGENT_CORE never reads it, never
   sends it to a provider, and does not let it change request shape (see
   [Conversation_metadata.is_mergeable_followup]). *)
module Input_speaker = struct
  type classification =
    | Absent
    | Present of Yojson.Safe.t
    | Duplicate

  let key = "agent_core.input_speaker.v1"
  let entry payload = key, payload

  let classify metadata =
    match
      List.filter_map
        (fun (field_key, value) ->
           if String.equal field_key key then Some value else None)
        metadata
    with
    | [] -> Absent
    | [ payload ] -> Present payload
    | _ :: _ :: _ -> Duplicate
  ;;

  let without metadata =
    List.filter (fun (field_key, _) -> not (String.equal field_key key)) metadata
  ;;
end

module Conversation_metadata = struct
  type run_boundary =
    | Absent
    | Present
    | Invalid
    | Duplicate

  let run_boundary_key = "agent_core.agent_run_boundary.v1"
  let run_boundary_entry = run_boundary_key, `Bool true
  let run_boundary = [ run_boundary_entry ]

  let classify_run_boundary metadata =
    let values =
      List.filter_map
        (fun (key, value) ->
           if String.equal key run_boundary_key then Some value else None)
        metadata
    in
    match values with
    | [] -> Absent
    | [ `Bool true ] -> Present
    | [ _ ] -> Invalid
    | _ -> Duplicate
  ;;

  (* The input speaker is attribution the provider never sees, so it alone
     must not keep a follow-up out of the tool-result span. *)
  let is_mergeable_followup metadata =
    match Input_speaker.classify metadata with
    | Input_speaker.Duplicate -> false
    | Input_speaker.Absent | Input_speaker.Present _ ->
      (match Input_speaker.without metadata with
       | [] -> true
       | rest -> classify_run_boundary rest = Present && List.length rest = 1)
  ;;
end

module Extra_system_context_provenance = struct
  type classification =
    | Absent
    | Present
    | Invalid
    | Duplicate

  let key = "agent_core.extra_system_context.v1"
  let entry = key, `Bool true
  let metadata = [ entry ]

  let classify metadata =
    let values =
      List.filter_map
        (fun (field_key, value) ->
           if String.equal field_key key then Some value else None)
        metadata
    in
    match values with
    | [] -> Absent
    | [ `Bool true ] -> Present
    | [ _ ] -> Invalid
    | _ -> Duplicate
  ;;
end

(** Exact producer binding for stored reasoning artifacts. *)
module Reasoning_source = struct
  type provider_instance = Provider_instance_id of string [@@deriving show]

  type t =
    { provider_kind : Provider_kind.t
    ; provider_instance : provider_instance
    ; canonical_model_id : string
    ; replay_contract : Reasoning_replay_contract.t
    }
  [@@deriving show]

  type classification =
    | Absent
    | Present of t
    | Invalid
    | Duplicate
  [@@deriving show]

  let key = "agent_core.reasoning_source.v2"
  let sha256_hex_length = 64

  let provider_instance_id_is_canonical value =
    String.length value = sha256_hex_length
    && String.for_all
         (function
           | '0' .. '9' | 'a' .. 'f' -> true
           | _ -> false)
         value
  ;;

  let provider_instance ~base_url ~request_path =
    let canonical value = Uri.of_string value |> Uri.canonicalize |> Uri.to_string in
    let material = canonical base_url ^ "\000" ^ canonical request_path in
    Provider_instance_id Digestif.SHA256.(to_hex (digest_string material))
  ;;

  let create ~provider_kind ~provider_instance ~canonical_model_id ~replay_contract =
    if String.trim canonical_model_id = ""
    then Error "canonical_model_id must not be blank"
    else Ok { provider_kind; provider_instance; canonical_model_id; replay_contract }
  ;;

  let equal left right =
    left.provider_kind = right.provider_kind
    && left.provider_instance = right.provider_instance
    && String.equal left.canonical_model_id right.canonical_model_id
    && Reasoning_replay_contract.equal left.replay_contract right.replay_contract
  ;;

  (* Everything except the concrete endpoint: same provider kind, same
     canonical request model, same typed replay contract. This is the widest
     difference a self-contained reasoning text can survive, because none of
     those three dimensions changed — only the base URL / request path the
     bytes travelled over. *)
  let same_contract_and_model stored target =
    stored.provider_kind = target.provider_kind
    && String.equal stored.canonical_model_id target.canonical_model_id
    && Reasoning_replay_contract.equal stored.replay_contract target.replay_contract
  ;;

  let rotation_admits
        ~(rotation_policy : Reasoning_replay_contract.rotation_policy)
        ~stored
        ~target
    =
    match rotation_policy with
    | Require_identical_source -> equal stored target
    | Allow_endpoint_rotation -> same_contract_and_model stored target
  ;;

  let to_json source =
    let (Provider_instance_id provider_instance_id) = source.provider_instance in
    `Assoc
      [ "provider_kind", `String (Provider_kind.to_string source.provider_kind)
      ; "provider_instance_id", `String provider_instance_id
      ; "canonical_model_id", `String source.canonical_model_id
      ; "replay_contract", Reasoning_replay_contract.to_yojson source.replay_contract
      ]
  ;;

  let values_for key fields =
    List.filter_map
      (fun (field_key, value) -> if String.equal field_key key then Some value else None)
      fields
  ;;

  let of_json = function
    | `Assoc fields ->
      (match
         ( values_for "provider_kind" fields
         , values_for "provider_instance_id" fields
         , values_for "canonical_model_id" fields
         , values_for "replay_contract" fields )
       with
       | ( [ `String provider_raw ]
         , [ `String provider_instance_id ]
         , [ `String canonical_model_id ]
         , [ replay_contract_json ] )
         when List.length fields = 4
              && provider_instance_id_is_canonical provider_instance_id ->
         (match Provider_kind.of_string provider_raw with
          | Some provider_kind
            when String.equal provider_raw (Provider_kind.to_string provider_kind) ->
            (match Reasoning_replay_contract.of_yojson replay_contract_json with
             | Error _ -> None
             | Ok replay_contract ->
               (match
                  create
                    ~provider_kind
                    ~provider_instance:(Provider_instance_id provider_instance_id)
                    ~canonical_model_id
                    ~replay_contract
                with
                | Ok source -> Some source
                | Error _ -> None))
          | Some _ | None -> None)
       | _ -> None)
    | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _ -> None
  ;;

  let entry source = key, to_json source
  let metadata source = [ entry source ]
  let to_yojson = to_json

  let of_yojson json =
    match of_json json with
    | Some source -> Ok source
    | None -> Error "Reasoning_source: invalid JSON"
  ;;

  let classify metadata =
    let values = values_for key metadata in
    match values with
    | [] -> Absent
    | [ value ] ->
      (match of_json value with
       | Some source -> Present source
       | None -> Invalid)
    | _ -> Duplicate
  ;;

  let add source metadata =
    match classify metadata with
    | Absent -> Ok (entry source :: metadata)
    | Present existing when equal existing source -> Ok metadata
    | Present _ -> Error "conflicting reasoning source"
    | Invalid -> Error "malformed reasoning source"
    | Duplicate -> Error "duplicate reasoning source"
  ;;
end

(** A single message in the conversation.
    [name] identifies the speaker (e.g. tool result source).
    [tool_call_id] links a tool result back to its tool_use request. *)
type message =
  { role : role
  ; content : content_block list
  ; name : string option [@default None]
  ; tool_call_id : string option [@default None]
  ; metadata : metadata [@default []]
  }
[@@deriving show]

module Message_value = struct
  type t = message

  let equal (left : t) (right : t) = Stdlib.compare left right = 0
  let mix accumulator value = ((accumulator * 65599) lxor value) land max_int

  (* A string contributes its length, bytes at a fixed stride of
     [length / string_hint_samples] (fewer than [2 * string_hint_samples] of
     them), and its last byte, so the hash stays independent of tool-result body
     size. [Hashtbl.hash] would hash every byte of the first strings it reaches.
     A string shorter than [2 * string_hint_samples] contributes every byte: ids
     such as [call_00000123] share their length and most of their bytes. *)
  let string_hint_samples = 32

  let string_hint value =
    let length = String.length value in
    if length = 0
    then 0
    else (
      let step = max 1 (length / string_hint_samples) in
      let rec sample accumulator index =
        if index >= length
        then accumulator
        else
          sample
            (mix accumulator (Char.code (String.unsafe_get value index)))
            (index + step)
      in
      mix (sample length 0) (Char.code (String.unsafe_get value (length - 1))))
  ;;

  let optional_string_hint = function
    | None -> 0
    | Some value -> string_hint value
  ;;

  let role_hint : role -> int = function
    | System -> 1
    | User -> 2
    | Assistant -> 3
    | Tool -> 4
  ;;

  (* The content blocks carry the distinguishing bytes. [name] and
     [tool_call_id] are [None] on every message of a live 13,871-message
     checkpoint (2026-09-15), so without the blocks the hash takes one value per
     role and a lookup walks that role's whole history. *)
  let block_hint : content_block -> int = function
    | Text text -> mix 1 (string_hint text)
    | Thinking { content; signature } ->
      mix (mix 2 (string_hint content)) (optional_string_hint signature)
    | ReasoningDetails { reasoning_content; details } ->
      mix (mix 3 (optional_string_hint reasoning_content)) (List.length details)
    | RedactedThinking data -> mix 4 (string_hint data)
    | ToolUse { id; name; _ } -> mix (mix 5 (string_hint id)) (string_hint name)
    | ToolResult { tool_use_id; content; _ } ->
      mix (mix 6 (string_hint tool_use_id)) (string_hint content)
    | Image { data; _ } -> mix 7 (string_hint data)
    | Document { data; _ } -> mix 8 (string_hint data)
    | Audio { data; _ } -> mix 9 (string_hint data)
  ;;

  let hash (message : t) =
    List.fold_left
      (fun accumulator block -> mix accumulator (block_hint block))
      (mix
         (mix (role_hint message.role) (optional_string_hint message.name))
         (optional_string_hint message.tool_call_id))
      message.content
  ;;
end

(** {1 Response Types} *)

(** Stop reason from API.
    2025-2026 extended: Refusal, ContentFilter, RepetitionTruncation,
    PauseTurn, Compaction, ContextWindowExceeded. *)
type stop_reason =
  | EndTurn
  | StopToolUse
  | MaxTokens
  | StopSequence
  | Refusal (** Policy refusal (Anthropic, OpenAI, Gemini SAFETY). *)
  | ContentFilter (** Provider content-policy filter terminated generation. *)
  | RepetitionTruncation (** Provider repetition guard terminated generation. *)
  | PauseTurn (** Anthropic long-running turn pause. *)
  | Compaction (** Anthropic context compaction. *)
  | ContextWindowExceeded (** Anthropic context window exceeded. *)
  | UnmatchedToolCalls
  (** Internal fail-closed response shape: a provider claimed a tool turn
          but no executable tool block was assembled. This is not a provider
          terminal reason and is constructed only after wire reconciliation. *)
  | Unknown of string
[@@deriving show]

let stop_reason_of_string = function
  | "end_turn" -> EndTurn
  | "tool_use" -> StopToolUse
  | "max_tokens" | "length" | "length_limit" -> MaxTokens
  | "stop_sequence" -> StopSequence
  | "refusal" -> Refusal
  | "content_filter" -> ContentFilter
  | "repetition_truncation" -> RepetitionTruncation
  | "pause_turn" -> PauseTurn
  | "compaction" -> Compaction
  | "model_context_window_exceeded"
  | "context_window_exceeded"
  | "context_length_exceeded"
  | "max_context_length"
  | "context_limit_exceeded" -> ContextWindowExceeded
  | "unmatched_tool_calls" -> UnmatchedToolCalls
  | other -> Unknown other
;;

(* Canonical wire serialization of [stop_reason]: the exact inverse of
   [stop_reason_of_string]. [stop_reason_of_string (stop_reason_to_string r) = r]
   holds for every constructor (with the inherent caveat that [Unknown s]
   collapses to its decoded constructor when [s] is itself a known wire token).
   SSOT for stop-reason wire strings — callers must delegate here instead of
   re-spelling the literals, which previously drifted across modules
   (e.g. "tool_use" vs "stop_tool_use"). *)
let stop_reason_to_string = function
  | EndTurn -> "end_turn"
  | StopToolUse -> "tool_use"
  | MaxTokens -> "max_tokens"
  | StopSequence -> "stop_sequence"
  | Refusal -> "refusal"
  | ContentFilter -> "content_filter"
  | RepetitionTruncation -> "repetition_truncation"
  | PauseTurn -> "pause_turn"
  | Compaction -> "compaction"
  | ContextWindowExceeded -> "model_context_window_exceeded"
  | UnmatchedToolCalls -> "unmatched_tool_calls"
  | Unknown s -> s
;;

(* Stable, low-cardinality telemetry label for [stop_reason]. Identical to
   [stop_reason_to_string] except [Unknown _] collapses to the constant
   ["unknown"] so provider-supplied raw strings cannot explode metric-label
   cardinality. Use for Otel/metric labels; use [stop_reason_to_string] for
   wire/round-trip serialization. The explicit constructor list (rather than a
   wildcard) forces a compile error if a new [stop_reason] variant is added. *)
let stop_reason_to_metric_label = function
  | Unknown _ -> "unknown"
  | ( EndTurn
    | StopToolUse
    | MaxTokens
    | StopSequence
    | Refusal
    | ContentFilter
    | RepetitionTruncation
    | PauseTurn
    | Compaction
    | ContextWindowExceeded
    | UnmatchedToolCalls ) as r -> stop_reason_to_string r
;;

(** API usage from a single response *)
(* delta_usage is declared before api_usage on purpose: the two records
   share field labels, and OCaml resolves an unqualified label to the most
   recently defined record — the codebase's pervasive unannotated
   [u.input_tokens] accesses must keep meaning api_usage.
   Both records carry the same five labels, so a delta_usage literal is not
   told apart by its field count: state its type (an annotation, or a
   context that already expects delta_usage) or it is read as api_usage. *)
type delta_usage =
  { input_tokens : int option
  ; output_tokens : int option
  ; cache_creation_input_tokens : int option
  ; cache_read_input_tokens : int option
  ; cost_usd : float option [@default None]
    (** Optional provider-reported cumulative charge; zero is authoritative. *)
  }
[@@deriving show, yojson]

type api_usage =
  { input_tokens : int
  ; output_tokens : int
  ; cache_creation_input_tokens : int
  ; cache_read_input_tokens : int
  ; cost_usd : float option
  }
[@@deriving show, yojson]

let delta_usage_of_api_usage (u : api_usage) : delta_usage =
  { input_tokens = Some u.input_tokens
  ; output_tokens = Some u.output_tokens
  ; cache_creation_input_tokens = Some u.cache_creation_input_tokens
  ; cache_read_input_tokens = Some u.cache_read_input_tokens
  ; cost_usd = u.cost_usd
  }
;;

(** Provider-reported inference timing from a single API call.
    llama-server populates all fields; cloud providers return [None]. *)
type inference_timings =
  { prompt_n : int option
  ; prompt_ms : float option
  ; prompt_per_second : float option
  ; predicted_n : int option
  ; predicted_ms : float option
  ; predicted_per_second : float option
  ; cache_n : int option
  }
[@@deriving show, yojson]

(** The provider wire field that carries one output-token decision.  This is an
    envelope identity, not a provider brand: providers using an
    OpenAI-compatible endpoint share the matching OpenAI envelope. *)
type output_token_envelope = Output_token_wire_internal.envelope =
  | Openai_chat_max_tokens
  | Openai_responses_max_output_tokens
  | Anthropic_messages_max_tokens
  | Gemini_generation_config_max_output_tokens
  | Ollama_options_num_predict

type output_token_policy = Output_token_wire_internal.policy =
  | Omitted
  | Explicit
  | Explicit_clamped
  | Required_catalog_fallback
  | Required_capability_override_fallback

type output_token_ceiling_source = Output_token_wire_internal.ceiling_source =
  | Catalog_model
  | Declared_capability_override
  | Provider_default

let pp_output_token_envelope = Output_token_wire_internal.pp_envelope
let show_output_token_envelope = Output_token_wire_internal.show_envelope
let equal_output_token_envelope = Output_token_wire_internal.equal_envelope
let pp_output_token_policy = Output_token_wire_internal.pp_policy
let show_output_token_policy = Output_token_wire_internal.show_policy
let equal_output_token_policy = Output_token_wire_internal.equal_policy
let pp_output_token_ceiling_source = Output_token_wire_internal.pp_ceiling_source
let show_output_token_ceiling_source = Output_token_wire_internal.show_ceiling_source
let equal_output_token_ceiling_source = Output_token_wire_internal.equal_ceiling_source
let output_token_envelope_to_yojson = Output_token_wire_internal.envelope_to_yojson
let output_token_policy_to_yojson = Output_token_wire_internal.policy_to_yojson
let output_token_policy_of_yojson = Output_token_wire_internal.policy_of_yojson

let output_token_ceiling_source_to_yojson =
  Output_token_wire_internal.ceiling_source_to_yojson
;;

type output_token_ceiling = Output_token_wire_internal.ceiling =
  { value : int
  ; source : output_token_ceiling_source
  }
[@@deriving show, eq]

let output_token_ceiling = Output_token_wire_internal.ceiling

type output_token_receipt = Output_token_wire_internal.receipt

type required_output_token_error = Output_token_wire_internal.required_error =
  | Required_output_token_ceiling_missing
[@@deriving show, eq]

let optional_output_token_receipt = Output_token_wire_internal.optional_receipt
let required_output_token_receipt = Output_token_wire_internal.required_receipt
let output_token_receipt_envelope = Output_token_wire_internal.receipt_envelope
let output_token_receipt_requested = Output_token_wire_internal.receipt_requested
let output_token_receipt_effective = Output_token_wire_internal.receipt_effective
let output_token_receipt_policy = Output_token_wire_internal.receipt_policy
let output_token_receipt_ceiling = Output_token_wire_internal.receipt_ceiling

let output_token_receipt_ceiling_source =
  Output_token_wire_internal.receipt_ceiling_source
;;

let output_token_receipt_to_yojson = Output_token_wire_internal.receipt_to_yojson
let output_token_receipt_of_yojson = Output_token_wire_internal.receipt_of_yojson
let equal_output_token_receipt = Output_token_wire_internal.equal_receipt

(** Per-call inference telemetry.
    Parsed from the raw API response; never computed by downstream. *)
type inference_telemetry =
  { system_fingerprint : string option
  ; timings : inference_timings option
  ; reasoning_tokens : int option
  ; request_latency_ms : int option
  ; peak_memory_gb : float option
  ; provider_kind : Provider_kind.t option
  ; reasoning_effort : string option
  ; canonical_model_id : string option
  ; reasoning_source : Reasoning_source.t option
  ; effective_context_window : int option
  ; provider_internal_action_count : int option
  ; ttfrc_ms : float option
  ; prefill_ms : float option
  }
[@@deriving show, yojson]

let default_inference_telemetry : inference_telemetry =
  { system_fingerprint = None
  ; timings = None
  ; reasoning_tokens = None
  ; request_latency_ms = None
  ; peak_memory_gb = None
  ; provider_kind = None
  ; reasoning_effort = None
  ; canonical_model_id = None
  ; reasoning_source = None
  ; effective_context_window = None
  ; provider_internal_action_count = None
  ; ttfrc_ms = None
  ; prefill_ms = None
  }
;;

(** API response *)
type api_response =
  { id : string
  ; model : string
  ; stop_reason : stop_reason
  ; content : content_block list
  ; usage : api_usage option
  ; telemetry : inference_telemetry option
  }
[@@deriving show]

type assistant_message_error =
  | Reasoning_source_telemetry_missing
  | Reasoning_source_missing
[@@deriving show]

let content_has_reasoning_artifact content =
  List.exists
    (function
      | Thinking _ | ReasoningDetails _ | RedactedThinking _ -> true
      | Text _ | ToolUse _ | ToolResult _ | Image _ | Document _ | Audio _ -> false)
    content
;;

let assistant_message_of_response (response : api_response) =
  let message metadata =
    { role = Assistant
    ; content = response.content
    ; name = None
    ; tool_call_id = None
    ; metadata
    }
  in
  if not (content_has_reasoning_artifact response.content)
  then Ok (message [])
  else (
    match response.telemetry with
    | None -> Error Reasoning_source_telemetry_missing
    | Some { reasoning_source = None; _ } -> Error Reasoning_source_missing
    | Some { reasoning_source = Some source; _ } ->
      Ok (message (Reasoning_source.metadata source)))
;;

(** {1 SSE Streaming Types} *)

type content_delta =
  | TextDelta of string
  | TextSnapshot of string
  (** A complete text value at this content-block index. Unlike [TextDelta],
          this constructor explicitly authorizes exact-prefix reconciliation:
          the canonical stream state emits only the unseen suffix and suppresses
          an equal/older replay. Producers must never label an ordinary
          incremental chunk as a snapshot. *)
  | ThinkingDelta of string
  | ThinkingSignatureDelta of string
  | RedactedThinkingSnapshot of string
  (** Provider-authorized final opaque reasoning carrier replacing an open,
      unsigned thinking block at the same index. This is a one-way transition,
      not permission to replace a content block with another header. *)
  | ReasoningDetailsDelta of
      { reasoning_content : string option
      ; details : reasoning_detail list
      }
  | InputJsonDelta of string
  (** Incremental fragment of a tool-call arguments JSON string. The
          accumulator appends successive fragments to the block buffer. *)
  | InputJsonSnapshot of string
  (** A whole tool-call arguments value serialized in a single delta, used
          by providers that stream [arguments] as a JSON object/array instead of
          string fragments. The accumulator replaces the block buffer rather
          than appending, so a provider that re-emits the same complete value
          does not concatenate it into invalid JSON (e.g.
          [{"limit":10}{"limit":10}]). *)
  | MediaDelta of
      { media_type : string
      ; source_type : media_source_kind
      ; data : string
      }
  (** A chunk of a streamed media (image/document/audio) content block.
            Carries the block-level [media_type] and [source_type] alongside the
            [data] payload so the SSE layer needs no new {!ContentBlockStart}
            fields; the accumulator records the metadata (idempotent across
            chunks) and concatenates [data]. *)

(** How a generation was found to be repeating itself. The two rules read
    different blocks and count different things: a paragraph of an answer
    recurring anywhere in the block, or the tail of a reasoning block being one
    unit written verbatim over and over. *)
type repeating_shape =
  | Repeated_paragraph
  | Repeated_reasoning_cycle

let repeating_shape_to_string = function
  | Repeated_paragraph -> "repeated_paragraph"
  | Repeated_reasoning_cycle -> "repeated_reasoning_cycle"
;;

(* One spelling for both readers of a repeat: the transport's provider
   failure and the Keeper chat bridge's protocol error. *)
let repeating_generation_message ~repeated ~occurrences ~bytes_seen shape =
  let shown =
    if String.length repeated <= 120 then repeated else String.sub repeated 0 120
  in
  match shape with
  | Repeated_paragraph ->
    Printf.sprintf
      "generation repeated one paragraph %d times after %d bytes; ended here rather \
       than at the token ceiling: %S"
      occurrences
      bytes_seen
      shown
  | Repeated_reasoning_cycle ->
    Printf.sprintf
      "reasoning repeated one %d-byte unit %d times verbatim after %d bytes; ended \
       here rather than at the token ceiling: %S"
      (String.length repeated)
      occurrences
      bytes_seen
      shown
;;

(* See types.mli: a 429 or 5xx an OpenAI-compatible provider declared inside a
   response it had already accepted, and only its error object as the body. *)
type provider_status =
  { status : int
  ; error_body : string
  }

type provider_report =
  | Provider_stated
  | Unstated_errored_choice

type sse_event =
  | MessageStart of
      { id : string
      ; model : string
      ; usage : api_usage option
      }
  | ContentBlockStart of
      { index : int
      ; content_type : string
      ; tool_id : string option
      ; tool_name : string option
      }
  | ContentBlockDelta of
      { index : int
      ; delta : content_delta
      }
  | ContentBlockStop of { index : int }
  | MessageDelta of
      { stop_reason : stop_reason option
      ; usage : delta_usage option
      }
  | MessageStop
  | Ping
  | SSEError of
      { message : string
      ; error_type : string option
        (** Provider error-object [type] (e.g. ["rate_limit_exceeded"]),
                the streaming-time discriminator. Lets a mid-stream error
                converge onto the same classification path as an initial HTTP
                error instead of collapsing to [NetworkError {Unknown}].
                [None] when the provider omits it. *)
      ; provider_status : provider_status option
        (** The provider condition declared inside the envelope, since the
                stream's own [200] is already on the wire. [None] when the
                envelope declares none. *)
      ; report : provider_report
        (** Whether an error object arrived at all. A choice that finished
                with [error] and carried none says so here; the fields above
                are then what the reader supplied, not what the provider
                said. *)
      ; raw : string
        (** Original error payload JSON, carried verbatim for diagnostics.
                It is the whole chunk: a declared provider condition is
                classified from [provider_status]'s [error_body], not from
                this payload. *)
      }
  | NDJSONError of
      { message : string
      ; error_type : string option
      ; raw : string
      }
  | SSEParseFailed of
      { raw : string
      ; reason : string
      }
  | NDJSONParseFailed of
      { raw : string
      ; reason : string
      }
  | SSEUnknownEventType of
      { event_type : string
      ; raw : string
      }
  | SSEUnsupportedPart of
      { provider_kind : Provider_kind.t
      ; part : string
      ; raw : string
      }
  | SSEUnsupportedResponse of
      { provider_kind : Provider_kind.t
      ; response : string
      ; raw : string
      }
  | Connected
  | Timeout of string
  | StreamIncomplete of { reason : string }
  | StreamRepeating of
      { repeated : string
      ; occurrences : int
      ; bytes_seen : int
      ; shape : repeating_shape
      }

(** Terminal error captured while accumulating a streaming response.

    The accumulator stores this typed value (not a flattened string). Provider
    envelopes, malformed payloads, unknown events, and incomplete streams are
    preserved as distinct facts at the transport boundary; retry policy is
    decided above AGENT_CORE. This replaces the prior [string] carrier that collapsed
    provider-owned failures into one [NetworkError {Unknown}] bucket. *)
type stream_error =
  | Stream_provider_error of
      { message : string
      ; error_type : string option
      ; provider_status : provider_status option
      ; report : provider_report
      ; raw : string
      }
  | Stream_parse_failed of
      { reason : string
      ; raw : string
      }
  | Stream_ndjson_parse_failed of
      { reason : string
      ; raw : string
      }
  | Stream_incomplete of { reason : string }
  | Stream_repeating of
      { repeated : string
      ; occurrences : int
      ; bytes_seen : int
      ; shape : repeating_shape
      }
      (** The generation started repeating itself and did not stop: a paragraph
          of the answer recurring, or a reasoning block whose tail is one unit
          written verbatim over and over. Neither a transport fault nor a
          malformed payload: the bytes parse, and the provider is answering.
          Ending here rather than at the token ceiling is what makes the
          difference legible, and a repeat is established long before the
          ceiling is reached. [repeated] is the paragraph or the cycle unit. *)
  | Stream_unknown_event of
      { event_type : string
      ; raw : string
      }
  | Stream_unsupported_part of
      { provider_kind : Provider_kind.t
      ; part : string
      ; raw : string
      }
  | Stream_unsupported_response of
      { provider_kind : Provider_kind.t
      ; response : string
      ; raw : string
      }

(** Canonical decision for one provider stream event. The stream state machine
    is the sole producer; effect shells and projections consume this closed
    sum instead of redeclaring their own resolution vocabulary. *)
type stream_event_resolution =
  | Stream_event_accepted of sse_event
  | Stream_event_suppressed
  | Stream_event_rejected of stream_error

(** {1 Convenience Constructors}

    Convenience constructors for consumers that work with flat [string]
    messages and need to convert to [content_block list]. *)

(** Create a message with default [None] for optional fields. *)
let make_message ?name ?tool_call_id ?(metadata = []) ~role content =
  { role; content; name; tool_call_id; metadata }
;;

(** Create a text content block. *)
let text_block text = Text text

(** Create a base64-backed image content block by default. *)
let image_block ?(source_type = Base64) ~media_type ~data () =
  Image { media_type; data; source_type }
;;

(** Create a base64-backed document content block by default. *)
let document_block ?(source_type = Base64) ~media_type ~data () =
  Document { media_type; data; source_type }
;;

(** Create a base64-backed audio content block by default. *)
let audio_block ?(source_type = Base64) ~media_type ~data () =
  Audio { media_type; data; source_type }
;;

(** Create a text-only message. *)
let text_message role text = make_message ~role [ Text text ]

(** Create a user message from arbitrary content blocks. *)
let user_msg_blocks blocks = make_message ~role:User blocks

(** Create a system message. *)
let system_msg text = text_message System text

(** Create a user message. *)
let user_msg text = text_message User text

(** Create an assistant message. *)
let assistant_msg text = text_message Assistant text

(** Try to parse content as JSON, returning None on failure. *)
let try_parse_json (s : string) : Yojson.Safe.t option =
  if String.length s = 0
  then None
  else (
    match Yojson.Safe.from_string s with
    | json -> Some json
    | exception Yojson.Json_error _ -> None)
;;

(** Create a tool result message.
    When [json] is not provided, attempts to parse [content] as JSON
    so downstream consumers can access structured data without re-parsing. *)
let tool_result_msg ~tool_use_id ~content ?(outcome = Tool_succeeded) ?json () =
  let json =
    match json with
    | Some _ -> json
    | None -> try_parse_json content
  in
  make_message
    ~tool_call_id:tool_use_id
    ~role:Tool
    [ ToolResult { tool_use_id; content; outcome; json; content_blocks = None } ]
;;

(** {1 Tool Result Validation}

    Minimal structural validation for tool result payloads.
    P0 Verification Loop will extend this with full JSON Schema checking. *)

type tool_result_validation_error =
  | Expected_object of string (** Expected JSON object, got other type *)
  | Expected_array of string (** Expected JSON array, got other type *)
  | Empty_content of string (** Tool returned empty content *)
  | Json_parse_failed of string (** Content is not valid JSON *)
[@@deriving show]

(** Validate that a ToolResult's payload matches a minimal expected shape.
    Returns [Ok ()] when the result passes, or a descriptive error.
    This is the foundation for P0's full JSON Schema validation loop. *)
let validate_tool_result_shape
      ~expect_object:(expect_obj : bool)
      ~expect_array:(expect_arr : bool)
      (block : content_block)
  : (unit, tool_result_validation_error) result
  =
  match block with
  | ToolResult { content; json; _ } ->
    if String.length (String.trim content) = 0
    then Error (Empty_content "ToolResult content is empty")
    else if expect_obj || expect_arr
    then (
      match json with
      | None ->
        (* content was not parseable as JSON *)
        Error (Json_parse_failed "ToolResult content is not valid JSON")
      | Some json_value ->
        if expect_obj && not expect_arr
        then (
          match json_value with
          | `Assoc _ -> Ok ()
          | _ -> Error (Expected_object "ToolResult JSON is not an object"))
        else if expect_arr && not expect_obj
        then (
          match json_value with
          | `List _ -> Ok ()
          | _ -> Error (Expected_array "ToolResult JSON is not an array"))
        else
          (* Both allowed — any JSON is fine *)
          Ok ())
    else Ok ()
  | _ -> Ok ()
;;

(** Extract text from content blocks, concatenating with newlines.
    Drops Thinking, Image, ToolUse, etc. *)
let text_of_content content =
  content
  |> List.filter_map (function
    | Text s -> Some s
    | ToolResult { content; _ } -> Some content
    | _ -> None)
  |> String.concat "\n"
;;

(** Extract text from a message. *)
let text_of_message (msg : message) = text_of_content msg.content

(** Extract text from an api_response. *)
let text_of_response (resp : api_response) = text_of_content resp.content

(** Extract end-user-visible assistant text from content blocks.
    This is intentionally narrower than [text_of_content]: tool results are
    model-visible execution payloads, and Thinking blocks are provider reasoning
    payloads. Neither belongs in an answer-text projection. *)
let visible_text_of_content content =
  content
  |> List.filter_map (function
    | Text s -> Some s
    | Thinking _
    | ReasoningDetails _
    | RedactedThinking _
    | ToolUse _
    | ToolResult _
    | Image _
    | Document _
    | Audio _ -> None)
  |> String.concat "\n"
;;

(** Extract end-user-visible assistant text from an api_response. *)
let visible_text_of_response (resp : api_response) = visible_text_of_content resp.content

(** {1 Usage Helpers} *)

let zero_api_usage =
  { input_tokens = 0
  ; output_tokens = 0
  ; cache_creation_input_tokens = 0
  ; cache_read_input_tokens = 0
  ; cost_usd = None
  }
;;

let usage_of_response (resp : api_response) = resp.usage
let total_tokens (usage : api_usage) = usage.input_tokens + usage.output_tokens
