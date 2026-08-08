(** Unified LLM provider types.

    Single source of truth for message, response, tool, and streaming types.
    Downstream consumers link against this module directly.

    @since 0.42.0

    @stability Internal
    @since 0.93.1 *)

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

val role_to_string : role -> string
val role_of_string : string -> role option

(** {1 Tool Types} *)

type param_type =
  | String
  | Integer
  | Number
  | Boolean
  | Array
  | Object
[@@deriving yojson, show]

val param_type_to_string : param_type -> string

(** Tool execution result types. *)
type tool_output =
  { content : string
  ; _meta : Yojson.Safe.t option
    (** Optional structured metadata forwarded to the MCP [tool_result._meta]
        field. [None] omits the field on the wire. *)
  }

type tool_error_class =
  | Transient
  | Deterministic
  | Unknown
[@@deriving yojson, show]

(** Provider-neutral classification of a failed tool execution. The class is
    produced by the execution boundary and survives agent history/checkpoint
    projection; provider wire serializers deliberately omit it. *)
type tool_failure_kind =
  | Validation_error
  | Recoverable_tool_error
  | Non_retryable_tool_error
  | Reported_tool_error
  | Unattributed_tool_error
  (** A persisted failure whose original execution boundary did not record
        provenance. This preserves missing historical evidence without
        relabelling it as provider-reported. *)
[@@deriving yojson, show]

type tool_failure_provenance =
  { failure_kind : tool_failure_kind
  ; error_class : tool_error_class option
  }
[@@deriving show]

(** A tool result has one authoritative outcome. Provider serializers derive
    their wire-level [is_error] flag from this value. *)
type tool_result_outcome =
  | Tool_succeeded
  | Tool_failed of tool_failure_provenance
[@@deriving show]

val tool_failure_kind_is_recoverable : tool_failure_kind -> bool
val tool_result_outcome_is_error : tool_result_outcome -> bool

type tool_error =
  { message : string
  ; recoverable : bool
  ; error_class : tool_error_class option
  }

type tool_result = (tool_output, tool_error) result

(** Lower an authoritative outcome to the hook/event-facing tool result. *)
val tool_result_of_outcome : content:string -> tool_result_outcome -> tool_result

type tool_param =
  { name : string
  ; description : string
  ; param_type : param_type
  ; required : bool
  }
[@@deriving yojson, show]

val param_type_of_string : string -> (param_type, string) result
val tool_param_to_json : tool_param -> Yojson.Safe.t

(** Total exact inverse for the manual JSON encoding. The derived
    {!tool_param_of_yojson} boundary applies the same duplicate/unknown-field
    rejection to its own encoding. A payload that is not an object, or whose
    fields have the wrong JSON shape, is reported as [Error] rather than
    raising [Yojson.Safe.Util.Type_error]. *)
val tool_param_of_json : Yojson.Safe.t -> (tool_param, string) result

val params_to_input_schema : tool_param list -> Yojson.Safe.t

(** Exact JSON shape of a value, used to name what arrived when a decode is
    refused. *)
type json_shape =
  | Json_null
  | Json_bool
  | Json_int
  | Json_intlit
  | Json_float
  | Json_string
  | Json_list
  | Json_object
[@@deriving show, eq]

val json_shape_of_json : Yojson.Safe.t -> json_shape
val json_shape_to_string : json_shape -> string
val json_schema_type_to_param_type_result : string -> (param_type, string) result

(** Derive the parameter view of a JSON Schema. Keeps only the parts a
    {!tool_param} can carry — name, one representable type, description, and
    required — which is why it is a projection of the schema and not a
    substitute for it. Valid properties expressed only through [$ref],
    [anyOf], [oneOf], or an unrepresentable union are omitted from this view;
    they remain unchanged in the authoritative schema. *)
val json_schema_to_params_result : Yojson.Safe.t -> (tool_param list, string) result

(** Why a JSON value was refused as a tool argument schema. *)
type input_schema_error =
  | Input_schema_not_an_object of json_shape
  | Input_schema_duplicate_keys of
      { path : string (** Path of the offending object, rooted at ["input_schema"]. *)
      ; keys : string list (** The repeated keys, sorted and deduplicated. *)
      }
[@@deriving show, eq]

val input_schema_error_to_string : input_schema_error -> string

(** Accept a value as a tool argument schema. A provider tool argument schema
    is a JSON object with unique keys, so an explicit [`Null], a scalar, an
    array, or an object Yojson parsed with a repeated key (at any depth) is
    refused instead of being stored. *)
val input_schema_of_json : Yojson.Safe.t -> (Yojson.Safe.t, input_schema_error) result

(** A tool definition. [private]: the two views of the arguments must agree, and
    the only values that satisfy that are the ones {!tool_schema_of_params} and
    {!tool_schema_of_input_schema} build. *)
type tool_schema = private
  { name : string
  ; description : string
  ; parameters : tool_param list
  ; strict : bool option
    (** Per-function JSON Schema strict validation. [Some true] opts the tool
        into strict mode (OpenAI, DeepSeek Beta, Kimi, MiMo); [None] omits the
        field so providers apply their default. *)
  ; input_schema : Yojson.Safe.t option
    (** Authoritative wire form emitted to providers verbatim when [Some]; when
        [None] the wire form is derived from [parameters] by
        {!params_to_input_schema}. [parameters] is the derived view used for
        validation and introspection, so [Some schema] always satisfies
        [parameters = json_schema_to_params_result schema].

        {!params_to_input_schema} keeps only type, description and required,
        so a caller-supplied schema carrying [minimum], [maximum], [default],
        [enum] or nested properties reaches the model only through this
        field. *)
  }
[@@deriving yojson, show]

(** Build a schema from the parameter view. [input_schema] is [None], so the
    wire form is derived by {!params_to_input_schema}. *)
val tool_schema_of_params
  :  ?strict:bool
  -> name:string
  -> description:string
  -> parameters:tool_param list
  -> unit
  -> tool_schema

(** Build a schema from one authoritative JSON Schema — the only way
    [input_schema] is ever [Some]. [parameters] is derived from [~input_schema]
    here, so the two cannot disagree. Properties that cannot be represented by
    the deliberately lossy {!tool_param} view (for example [$ref], [anyOf], or
    multi-type unions) remain only in the authoritative schema instead of
    making the tool unusable. Fails when the value is not a tool argument
    schema ({!input_schema_of_json}), explicitly describes non-object tool
    arguments, or contains a malformed projectable field. *)
val tool_schema_of_input_schema
  :  ?strict:bool
  -> name:string
  -> description:string
  -> input_schema:Yojson.Safe.t
  -> unit
  -> (tool_schema, string) result

val tool_schema_to_json : tool_schema -> Yojson.Safe.t

(** Inverse of {!tool_schema_to_json}, and total: malformed input is reported
    as [Error] rather than raising. Absence of an authoritative schema is
    encoded by omitting the ["input_schema"] key, so an omitted key decodes to
    [None] and a present one must be a tool argument schema
    ({!input_schema_of_json}). A payload whose ["parameters"] array disagrees
    with the projection of its ["input_schema"] is refused, because no value of
    this type could have carried that pair. Top-level and parameter objects must
    contain exactly their declared fields with no duplicate keys. The derived
    {!tool_schema_of_yojson} boundary enforces the same rule for its own
    encoding. A schema written by {!tool_schema_to_json} therefore round-trips
    unchanged. *)
val tool_schema_of_json : Yojson.Safe.t -> (tool_schema, string) result

val result_all : ('a, 'e) result list -> ('a list, 'e) result

type tool_choice =
  | Auto
  | Any
  | Tool of string
  | None_
[@@deriving show]

val tool_choice_to_json : tool_choice -> Yojson.Safe.t

type response_format =
  | Off
  | JsonMode
  | JsonSchema of Yojson.Safe.t
[@@deriving show]

val response_format_to_json : response_format -> Yojson.Safe.t

(** {1 Content Types} *)

(** Closed set of supported media source carriers. Unsupported provider/source
    combinations must fail closed instead of reinterpreting [data] as base64. *)
type media_source_kind =
  | Base64
  | Url
  | File_id
[@@deriving show]

val media_source_kind_to_string : media_source_kind -> string
val media_source_kind_of_string : string -> media_source_kind option

type reasoning_detail =
  { raw : Yojson.Safe.t
  ; text : string option
  }
[@@deriving show]

type content_block =
  | Text of string
  | Thinking of
      { content : string
      ; signature : string option
        (** [Some s]: Anthropic cryptographic signature, replayed byte-exact on
            tool turns. [None]: provider reasoning without a verification
            signature (OpenAI-compatible / Gemini / GLM / Ollama). *)
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
      ; json : Yojson.Safe.t option (** Structured payload when parseable. *)
      ; content_blocks : content_block list option
        (** Structured multi-block result (e.g. text + image). When [Some],
            providers that accept an array tool_result content serialize the
            blocks; [content] stays the canonical string fallback. *)
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

(** [reasoning_details_text ~reasoning_content ~details] projects provider
    reasoning details to their textual reasoning channel. Non-empty
    [reasoning_content] wins; otherwise the function concatenates
    [details[].text] in order and ignores raw-only detail payloads. It never
    serializes [raw] as a fallback. *)
val reasoning_details_text
  :  reasoning_content:string option
  -> details:reasoning_detail list
  -> string

(** Message metadata: extensible typed key-value pairs attached to a message. *)
type metadata = (string * Yojson.Safe.t) list [@@deriving show]

(** Checkpoint-only conversation metadata owned by OAS. The run boundary is
    deliberately absent from provider payloads; it lets crash recovery avoid
    correlating tool failures across distinct external user runs. *)
module Conversation_metadata : sig
  type run_boundary =
    | Absent
    | Present
    | Invalid
    | Duplicate

  val run_boundary_entry : string * Yojson.Safe.t
  val run_boundary : metadata
  val classify_run_boundary : metadata -> run_boundary

  (** Whether a follow-up User message may be folded into the preceding Tool
      message for providers that require a single user-role span. *)
  val is_mergeable_followup : metadata -> bool
end

(** Exact provenance for the synthetic User message created from
    [Hooks.extra_system_context]. Consumers can remove or attribute that carrier
    by typed identity instead of assuming a list position or matching text. *)
module Extra_system_context_provenance : sig
  type classification =
    | Absent
    | Present
    | Invalid
    | Duplicate

  val metadata : metadata
  val classify : metadata -> classification
end

(** Producer binding stamped on stored reasoning artifacts: provider kind,
    concrete endpoint instance, canonical request model, and typed replay
    contract. Whether a difference in any of those dimensions still admits
    replay is decided by the target dialect's declared
    {!Reasoning_replay_contract.rotation_policy} through {!rotation_admits} —
    not by a bare equality test at the consuming site. *)
module Reasoning_source : sig
  type provider_instance [@@deriving show]

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

  val provider_instance : base_url:string -> request_path:string -> provider_instance

  val create
    :  provider_kind:Provider_kind.t
    -> provider_instance:provider_instance
    -> canonical_model_id:string
    -> replay_contract:Reasoning_replay_contract.t
    -> (t, string) result

  val equal : t -> t -> bool

  (** [rotation_admits ~rotation_policy ~stored ~target] decides whether a
      stored reasoning artifact may still be replayed when the request now
      targets [target]. The answer comes from the declared
      {!Reasoning_replay_contract.rotation_policy} of the target dialect, never
      from an ad-hoc comparison at the call site. *)
  val rotation_admits
    :  rotation_policy:Reasoning_replay_contract.rotation_policy
    -> stored:t
    -> target:t
    -> bool

  val entry : t -> string * Yojson.Safe.t
  val metadata : t -> metadata
  val add : t -> metadata -> (metadata, string) result
  val classify : metadata -> classification
end

type message =
  { role : role
  ; content : content_block list
  ; name : string option
  ; tool_call_id : string option
  ; metadata : metadata
  }
[@@deriving show]

(** {1 Response Types} *)

type stop_reason =
  | EndTurn
  | StopToolUse
  | MaxTokens
  | StopSequence
  | Refusal
  | ContentFilter
  | RepetitionTruncation
  | PauseTurn
  | Compaction
  | ContextWindowExceeded
  | UnmatchedToolCalls
  | Unknown of string
[@@deriving show]

val stop_reason_of_string : string -> stop_reason

(** Canonical wire serialization — the exact inverse of {!stop_reason_of_string}.
    SSOT for stop-reason wire strings; consumers must delegate here rather than
    re-spell the literals. *)
val stop_reason_to_string : stop_reason -> string

(** Stable, low-cardinality telemetry label. Identical to
    {!stop_reason_to_string} except [Unknown _] collapses to ["unknown"]. *)
val stop_reason_to_metric_label : stop_reason -> string

(** API usage from a single provider response. Accumulated multi-call usage
    belongs in agent-level usage stats. *)
type api_usage =
  { input_tokens : int
  ; output_tokens : int
  ; cache_creation_input_tokens : int
  ; cache_read_input_tokens : int
  ; cost_usd : float option
  }
[@@deriving show, yojson]

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

type inference_telemetry =
  { system_fingerprint : string option
  ; timings : inference_timings option
  ; reasoning_tokens : int option
  ; request_latency_ms : int option
  ; peak_memory_gb : float option
  ; provider_kind : Provider_kind.t option
    (** Set by the inference pipeline to record which provider produced the
        response. The on-wire JSON form stays the lowercase canonical string
        (["ollama"], ["anthropic"], ["openai_compat"], …) via
        {!Provider_kind.to_yojson}. *)
  ; reasoning_effort : string option
    (** e.g. "none", "low", "medium", "high" — as sent to provider *)
  ; canonical_model_id : string option
    (** Model ID used for the API request after alias resolution (e.g. "glm-4.7") *)
  ; reasoning_source : Reasoning_source.t option
    (** Exact replay provenance stamped by the live inference boundary. *)
  ; effective_context_window : int option
    (** Model's context window in tokens, from capabilities *)
  ; provider_internal_action_count : int option
    (** Telemetry-only count of provider-native actions that are not surfaced as OAS tool calls. *)
  ; ttfrc_ms : float option
    (** Time-to-first-response-chunk in milliseconds (wall-clock). *)
  ; prefill_ms : float option (** Prompt evaluation (prefill) duration in milliseconds. *)
  }
[@@deriving show, yojson]

type output_token_envelope =
  | Openai_chat_max_tokens
  | Openai_responses_max_output_tokens
  | Anthropic_messages_max_tokens
  | Gemini_generation_config_max_output_tokens
  | Ollama_options_num_predict
[@@deriving show, eq]

val output_token_envelope_to_yojson : output_token_envelope -> Yojson.Safe.t

val output_token_envelope_of_yojson
  :  Yojson.Safe.t
  -> (output_token_envelope, string) result

type output_token_policy =
  | Omitted
  | Explicit
  | Explicit_clamped
  | Required_catalog_fallback
  | Required_capability_override_fallback
[@@deriving show, eq]

val output_token_policy_to_yojson : output_token_policy -> Yojson.Safe.t
val output_token_policy_of_yojson : Yojson.Safe.t -> (output_token_policy, string) result

(** Typed provenance of the validation ceiling consulted for the receipt.
    [Provider_default] is the provider-config fallback used only when neither a
    capability override nor a model-catalog entry resolves.  Required request
    envelopes do not inject that validation fallback as a request value. *)
type output_token_ceiling_source =
  | Catalog_model
  | Declared_capability_override
  | Provider_default
[@@deriving show, eq]

val output_token_ceiling_source_to_yojson : output_token_ceiling_source -> Yojson.Safe.t

val output_token_ceiling_source_of_yojson
  :  Yojson.Safe.t
  -> (output_token_ceiling_source, string) result

type output_token_ceiling = private
  { value : int
  ; source : output_token_ceiling_source
  }

val output_token_ceiling
  :  value:int
  -> source:output_token_ceiling_source
  -> output_token_ceiling

(** An invariant-checked observation of one output-token decision.  Exact
    payload/receipt provenance is established only by the opaque request
    artifact returned by a backend; a receipt value by itself is a read
    projection, not proof that a particular payload was built or sent. *)
type output_token_receipt

type required_output_token_error = Required_output_token_ceiling_missing
[@@deriving show, eq]

val optional_output_token_receipt
  :  envelope:output_token_envelope
  -> requested:int option
  -> ceiling:output_token_ceiling option
  -> output_token_receipt

val required_output_token_receipt
  :  output_token_receipt
  -> (output_token_receipt, required_output_token_error) result

val output_token_receipt_envelope : output_token_receipt -> output_token_envelope
val output_token_receipt_requested : output_token_receipt -> int option
val output_token_receipt_effective : output_token_receipt -> int option
val output_token_receipt_policy : output_token_receipt -> output_token_policy
val output_token_receipt_ceiling : output_token_receipt -> int option

val output_token_receipt_ceiling_source
  :  output_token_receipt
  -> output_token_ceiling_source option

val output_token_receipt_to_yojson : output_token_receipt -> Yojson.Safe.t

val output_token_receipt_of_yojson
  :  Yojson.Safe.t
  -> (output_token_receipt, string) result

val equal_output_token_receipt : output_token_receipt -> output_token_receipt -> bool
val pp_output_token_receipt : Format.formatter -> output_token_receipt -> unit
val show_output_token_receipt : output_token_receipt -> string

(** Default/zero inference telemetry value owned by the telemetry type module.
    Callers should record-update this value instead of duplicating every field. *)
val default_inference_telemetry : inference_telemetry

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

(** Convert a provider response into the Assistant history message callers
    should append. Reasoning-bearing responses require exact replay
    provenance; plain responses remain metadata-free. *)
val assistant_message_of_response
  :  api_response
  -> (message, assistant_message_error) result

(** {1 SSE Streaming Types} *)

type content_delta =
  | TextDelta of string
  | ThinkingDelta of string
  | ThinkingSignatureDelta of string
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
          does not concatenate it into invalid JSON. *)
  | MediaDelta of
      { media_type : string
      ; source_type : media_source_kind
      ; data : string
      }
  (** A chunk of a streamed media (image/document/audio) content block.
            Carries block-level [media_type] and [source_type] with the [data]
            payload so no new {!ContentBlockStart} fields are required. *)

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
      ; usage : api_usage option
      }
  | MessageStop
  | Ping
  | SSEError of
      { message : string
      ; error_type : string option
      ; raw : string
      }
  (** A provider-reported error delivered mid-stream. [error_type] is the
            provider's error-object [type] discriminator (e.g.
            ["rate_limit_exceeded"]) and [raw] the original error JSON, so the
            consumer can converge onto the same classification path as an
            initial HTTP error instead of collapsing to [NetworkError {Unknown}]. *)
  | NDJSONError of
      { message : string
      ; error_type : string option
      ; raw : string
      }
  (** A provider-reported error envelope delivered in an NDJSON stream.
      This is deliberately distinct from [SSEError]: the wire format is a
      transport fact and must not be relabelled at the event boundary. *)
  | SSEParseFailed of
      { raw : string
      ; reason : string
      }
  (** A chunk's JSON could not be parsed (Yojson Json_error or
            Type_error). Previously the parser returned [None] and the
            chunk was silently dropped; consumers that then saw
            [MessageStop] would never know the response was incomplete.
            Emit this event so the accumulator can mark the stream as
            corrupted and the caller can route to a different
            provider instead of presenting a phantom completion. *)
  | NDJSONParseFailed of
      { raw : string
      ; reason : string
      }
  (** An NDJSON line could not be parsed. This is separate from
      [SSEParseFailed] because the wire format is a transport fact consumed
      by the HTTP boundary; it must not be relabeled as SSE. *)
  | SSEUnknownEventType of
      { event_type : string
      ; raw : string
      }
  (** The chunk parsed cleanly but [event_type] did not match any
            documented variant. Likely a provider that added a new event
            type the OAS adapter has not yet learned. Emit explicitly so
            the consumer can decide (log + skip vs fail-fast) instead of
            silent data loss. *)
  | SSEUnsupportedPart of
      { provider_kind : Provider_kind.t
      ; part : string
      ; raw : string
      }
  (** The provider emitted a valid content part whose capability is not
      projected by this adapter. This is distinct from malformed payloads and
      unknown SSE event types: callers must surface it as a capability
      mismatch rather than treating it as transport corruption. *)
  | SSEUnsupportedResponse of
      { provider_kind : Provider_kind.t
      ; response : string
      ; raw : string
      }
  (** The provider emitted a valid response-level shape whose capability is not
      projected by this adapter. This is distinct from an unsupported content
      part and from malformed payloads; callers must preserve the response
      boundary when classifying the capability mismatch. *)
  | Connected
  | Timeout of string
  | StreamIncomplete of { reason : string }
  (** The provider signalled the turn was cut off before a natural stop (an
      OpenAI Responses [response.incomplete]). Any in-progress tool call is
      partial, so the accumulator drops tool blocks at finalize rather than
      surfacing a dangling/executable ToolUse. [reason] is the provider's
      incomplete reason (e.g. ["max_output_tokens"], ["content_filter"]). This
      covers incomplete reasons beyond [max_output_tokens], which the
      [stop_reason = MaxTokens] check alone misses. *)

(** Terminal error captured while accumulating a streaming response. The accumulator
    stores this typed value (not a flattened string). Provider-owned error
    envelopes, malformed payloads, unknown events, and incomplete streams stay
    distinct at the transport boundary; retry policy is decided above OAS. *)
type stream_error =
  | Stream_provider_error of
      { message : string
      ; error_type : string option
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
  (** The NDJSON parser failed. This remains distinct from an SSE parse
      failure so the HTTP boundary can preserve the declared wire format. *)
  | Stream_incomplete of { reason : string }
  (** The stream ended without its protocol terminal marker.  This is not a
      malformed payload and must remain distinct at the transport boundary. *)
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

(** {1 Convenience Constructors} *)

val make_message
  :  ?name:string
  -> ?tool_call_id:string
  -> ?metadata:(string * Yojson.Safe.t) list
  -> role:role
  -> content_block list
  -> message

val text_block : string -> content_block

val image_block
  :  ?source_type:media_source_kind
  -> media_type:string
  -> data:string
  -> unit
  -> content_block

val document_block
  :  ?source_type:media_source_kind
  -> media_type:string
  -> data:string
  -> unit
  -> content_block

val audio_block
  :  ?source_type:media_source_kind
  -> media_type:string
  -> data:string
  -> unit
  -> content_block

val text_message : role -> string -> message
val user_msg_blocks : content_block list -> message
val system_msg : string -> message
val user_msg : string -> message
val assistant_msg : string -> message
val try_parse_json : string -> Yojson.Safe.t option

val tool_result_msg
  :  tool_use_id:string
  -> content:string
  -> ?outcome:tool_result_outcome
  -> ?json:Yojson.Safe.t
  -> unit
  -> message

(** {1 Tool Result Validation}

    Minimal structural validation for tool result payloads. *)

type tool_result_validation_error =
  | Expected_object of string
  | Expected_array of string
  | Empty_content of string
  | Json_parse_failed of string

(** Validate that a ToolResult's payload matches a minimal expected shape.
    Returns [Ok ()] when the result passes, or a descriptive error.
    Foundation for P0's full JSON Schema validation loop. *)
val validate_tool_result_shape
  :  expect_object:bool
  -> expect_array:bool
  -> content_block
  -> (unit, tool_result_validation_error) result

val text_of_content : content_block list -> string
val text_of_message : message -> string
val text_of_response : api_response -> string

(** End-user-visible assistant text projection.

    Unlike {!text_of_content}, these helpers only include [Text] blocks. They
    intentionally exclude [Thinking], [RedactedThinking], [ToolUse],
    [ToolResult], and media blocks so downstream answer surfaces do not leak
    reasoning or execution payloads. *)
val visible_text_of_content : content_block list -> string

val visible_text_of_message : message -> string
val visible_text_of_response : api_response -> string

(** {1 Usage Helpers}

    @since 0.78.0 *)

(** Zero-valued usage sentinel for accumulation. *)
val zero_api_usage : api_usage

(** Extract usage from a response, preserving [None] when the provider did not
    report usage. *)
val usage_of_response : api_response -> api_usage option

(** Billable token total: [input_tokens + output_tokens]. Cache tokens are
    excluded — this counts the metered request/response pair, not full context. *)
val total_tokens : api_usage -> int
