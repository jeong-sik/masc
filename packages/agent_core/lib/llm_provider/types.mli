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

val tool_result_outcome_is_error : tool_result_outcome -> bool

type tool_error =
  { message : string
  ; recoverable : bool
  ; error_class : tool_error_class option
  }


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


(** Exact object-shape check for a manual decoder. [Error] names the missing
    required fields, the fields outside [required @ optional], and the
    duplicated keys, prefixed with [scope]. *)
val exact_object_fields
  :  scope:string
  -> required:string list
  -> ?optional:string list
  -> (string * Yojson.Safe.t) list
  -> (unit, string) result

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

(** Separates enum members when they are written as text instead of carried
    as [enum], as ["one of: a | b"] in a parameter description for a provider
    whose tool schemas cannot carry [enum]. Members are written unquoted, so a
    member containing this character cannot be told apart from two members. *)
val enum_member_separator : char

(** [members] written as text, separated by {!enum_member_separator}. *)
val enum_vocabulary_text : string list -> string

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

(** A media block's source: the carrier and its payload together, so the
    meaning of the payload string is fixed by the constructor. Unsupported
    provider/source combinations must fail closed instead of reinterpreting
    the payload as base64. *)
type media_source =
  | Base64 of string (** Base64-encoded bytes. *)
  | Url of string
  | File_id of string
[@@deriving show]

(** The wire [source.type] value of a source: ["base64"], ["url"] or
    ["file_id"]. *)
val media_source_wire_tag : media_source -> string

(** Read a wire [source.type] value (trimmed, any case). [Some make] names the
    constructor that carries the payload read next to it; [None] for a value
    outside the three carriers. *)
val media_source_of_wire_tag : string -> (string -> media_source) option

(** The payload string of a source, whatever its carrier: base64 bytes, a URL,
    or a file id. For wire codecs that write {!media_source_wire_tag} beside it
    and for byte accounting. *)
val media_source_payload : media_source -> string

(** A carrier without its payload: for a record that keeps which carrier a
    payload arrived in after the payload itself has gone elsewhere (a
    generated media file), and for a diagnostic that names a carrier without
    repeating its payload. *)
type media_source_kind =
  | Base64_kind
  | Url_kind
  | File_id_kind
[@@deriving show]

val media_source_kind_of_source : media_source -> media_source_kind

(** Same strings as {!media_source_wire_tag}. *)
val media_source_kind_to_string : media_source_kind -> string

(** Same reading as {!media_source_of_wire_tag}. *)
val media_source_kind_of_string : string -> media_source_kind option

(** The chunks of one streamed media payload. The first chunk fixes the
    carrier. Adding a chunk copies nothing; {!media_chunks_source} joins them
    once. *)
type media_chunks

val media_chunks_start : media_source -> media_chunks

(** [media_chunks_add chunks chunk] keeps [chunk] after the others when it uses
    the first chunk's carrier; [None] when it uses another. An empty chunk of
    the same carrier keeps the existing accumulator. *)
val media_chunks_add : media_chunks -> media_source -> media_chunks option

(** The carrier the first chunk fixed. *)
val media_chunks_kind : media_chunks -> media_source_kind

(** The payload of every chunk in arrival order, under the first chunk's
    carrier. *)
val media_chunks_source : media_chunks -> media_source

type reasoning_detail =
  { raw : Yojson.Safe.t
  ; text : string option
  }
[@@deriving show]

(** A content block over a media source. The provider instantiates it with
    {!media_source}, which carries payloads; history instantiates it with a
    source that holds bytes by reference. Constructors are shared, so code
    that reads only kinds, positions, text or reasoning is written once for
    both. *)
type 'source content_block_with =
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
      ; content_blocks : 'source content_block_with list option
        (** Structured multi-block result (e.g. text + image). When [Some],
            providers that accept an array tool_result content serialize the
            blocks; [content] stays the canonical string fallback. *)
      }
  | Image of
      { media_type : string
      ; source : 'source
      }
  | Document of
      { media_type : string
      ; source : 'source
      }
  | Audio of
      { media_type : string
      ; source : 'source
      }
[@@deriving show]

type content_block = media_source content_block_with [@@deriving show]

type tool_output =
  { content : string
  ; content_blocks : content_block list option
    (** Model-visible structured content. [None] denotes text-only output. *)
  ; _meta : Yojson.Safe.t option
    (** Optional structured metadata forwarded to the MCP [tool_result._meta]
        field. [None] omits the field on the wire. *)
  }

type tool_result = (tool_output, tool_error) result

(** Lower an authoritative outcome to the hook/event-facing tool result. *)
val tool_result_of_outcome :
  ?content_blocks:content_block list -> content:string -> tool_result_outcome -> tool_result


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

(** Host-owned attribution of a User input. AGENT_CORE owns only the key: the
    payload is the host's typed speaker encoded as JSON, which AGENT_CORE
    stores and checkpoints but never reads, never serializes to a provider, and
    never lets change request shape. A host stamps it when it creates the
    message and does not add or remove it afterwards. *)
module Input_speaker : sig
  type classification =
    | Absent
    | Present of Yojson.Safe.t
    | Duplicate

  val key : string
  val entry : Yojson.Safe.t -> string * Yojson.Safe.t
  val classify : metadata -> classification

  (** [metadata] with every input-speaker entry removed. *)
  val without : metadata -> metadata
end

(** Checkpoint-only conversation metadata owned by AGENT_CORE. The run boundary is
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
      message for providers that require a single user-role span. A single
      {!Input_speaker} entry does not affect the answer. *)
  val is_mergeable_followup : metadata -> bool
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

  val to_yojson : t -> Yojson.Safe.t
  val of_yojson : Yojson.Safe.t -> (t, string) result
  (** Exact non-secret persistence codec, shared by message stamps and
      session checkpoints. Duplicate keys at any depth are rejected. The
      endpoint is represented only by its hash. *)

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

(** Creation-prefix identity stamped beside a stored reasoning artifact: the
    wire the producing request actually sent, hashed so replay can prove the
    current prefix is byte-identical before returning a signed block to an
    endpoint that verifies the binding. [request_digest] covers the fields
    the API's own prefix check covers — the system prompt, the tools, and
    every transmitted message before this one; [message_digest] covers this
    message's own wire bytes, so an in-message edit fails closed too. A
    separate entry from {!Reasoning_source.t} so previously stored artifacts
    keep parsing: they carry no digest and fail closed on binding wires. *)
module Reasoning_prefix : sig
  type t =
    { request_digest : string
    ; message_digest : string
    }
  [@@deriving show]

  type classification =
    | Absent
    | Present of t
    | Invalid
    | Duplicate
  [@@deriving show]

  val entry : t -> string * Yojson.Safe.t
  val metadata : t -> metadata
  val classify : metadata -> classification
end

(** Canonical source identity, independent of the provider's wire role.
    [Conversation] is an ordinary caller/model/tool transcript message; only
    its [User] role opens a caller-input boundary. The remaining origins are
    SDK control messages, never a new human query. Current context is pinned;
    historical context is retained replay history. *)
type message_origin =
  | Conversation
  | System_context
  | Historical_system_context
  | Recovery_instruction
  | Tool_result_followup
  | Agent_instruction
[@@deriving show]

val message_origin_to_string : message_origin -> string
val message_origin_of_string : string -> message_origin option

(** A message over a media source; see {!content_block_with}. *)
type 'source message_with =
  { role : role
  ; origin : message_origin
  ; content : 'source content_block_with list
  ; name : string option
  ; tool_call_id : string option
  ; metadata : metadata
  }
[@@deriving show]

type message = media_source message_with [@@deriving show]

(** Messages as hash-table keys.

    [equal] is [Stdlib.compare left right = 0]. It raises on functional or
    abstract values; [message] holds neither, and a field of such a type would
    have to change this module. [0.0] and [-0.0] inside a raw JSON payload
    ([ToolUse.input], [ToolResult.json], [reasoning_detail.raw], [metadata])
    compare equal while encoding one byte apart, so a table that must return
    the exact bytes of its key pairs [hash] with physical equality instead.

    [hash] reads the role, [name], [tool_call_id], and each content block's
    strings through a bounded sample (length, bytes at a fixed stride, last
    byte). Its cost grows with the number of blocks, not with their size.
    Both [equal left right] and [left == right] imply
    [hash left = hash right]. *)
module Message_value : sig
  type t = message

  val equal : t -> t -> bool
  val hash : t -> int
end

(** {!Message_value} over any media source: [source_hint] is what a media
    source contributes to the hash, and {!string_hint} is the sampled string
    hash every other field uses. *)
module Message_value_with : sig
  val equal : 'source message_with -> 'source message_with -> bool
  val hash : source_hint:('source -> int) -> 'source message_with -> int
  val string_hint : string -> int
end

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

(** Usage counts carried by a mid-stream event ([MessageDelta]). The wire
    contract is cumulative — a reported value is the latest running total
    for the whole message, never an increment — so accumulators replace the
    fields a delta reports and keep the rest ([None] means the event did not
    report that counter). Field semantics match {!api_usage}: [input_tokens]
    is the inclusive prompt total, normalized by the producing parser.
    Declared before {!api_usage} so the shared field labels keep resolving
    unqualified to [api_usage] (the later definition wins). *)
type delta_usage =
  { input_tokens : int option
  ; output_tokens : int option
  ; cache_creation_input_tokens : int option
  ; cache_read_input_tokens : int option
  ; cost_usd : float option [@default None]
    (** Optional provider-reported cumulative charge; zero is authoritative. *)
  }
[@@deriving show, yojson]

(** API usage from a single provider response. Accumulated multi-call usage
    belongs in agent-level usage stats.

    [input_tokens] is the canonical inclusive prompt total: it counts every
    prompt token the provider processed for the request, including the
    [cache_creation_input_tokens] and [cache_read_input_tokens] components.
    Consumers subtract the cache components to price the regular remainder
    (see [Pricing.estimate_cost]) and divide by the context window for
    occupancy. Wire formats that already report an inclusive prompt total
    (OpenAI [prompt_tokens], Gemini [promptTokenCount], GLM) map verbatim;
    the Anthropic Messages wire reports exclusive input and is normalized at
    its parse boundary ([Backend_anthropic.usage_of_wire_counts]). A parser
    that copies an exclusive wire count into [input_tokens] is a defect. *)
type api_usage =
  { input_tokens : int
  ; output_tokens : int
  ; cache_creation_input_tokens : int
  ; cache_read_input_tokens : int
  ; cost_usd : float option
  }
[@@deriving show, yojson]

(** All-fields-present projection for producers whose terminal usage report
    is a complete {!api_usage} (OpenAI-format final usage chunk). *)
val delta_usage_of_api_usage : api_usage -> delta_usage

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

(** Exact scalar Chat content carrier, bound to canonical content occurrences.
    Only a parser with the declared Think_tags_with_chat_replay contract creates this witness.
    Validation re-splits the original bytes and compares the named occurrences;
    it never reconstructs a carrier from Thinking text. *)
module Inline_content_replay : sig
  type t = { raw_content : string; block_indices : int list }
  [@@deriving show, yojson]
  val metadata_key : string
  val make : content:'source content_block_with list -> raw_content:string -> block_indices:int list -> (t, string) result
  val metadata : t -> string * Yojson.Safe.t
  val of_metadata : content:'source content_block_with list -> (string * Yojson.Safe.t) list -> (t option, string) result
  val remove_metadata : (string * Yojson.Safe.t) list -> (string * Yojson.Safe.t) list
  val retain : original_content:'source content_block_with list -> content:'source content_block_with list -> retained_indices:int list -> t -> (t option, string) result
  val retain_metadata : original_content:'source content_block_with list -> content:'source content_block_with list -> retained_indices:int list -> (string * Yojson.Safe.t) list -> ((string * Yojson.Safe.t) list, string) result
end

(** Payload-free native Responses output-item partition. A message phase
    applies only to its own group, never to the flattened assistant message. *)
module Response_replay : sig
  type phase = Absent | Null | Commentary | Final_answer
  [@@deriving show, yojson]
  type kind = Message of phase | Reasoning | Function_call
  [@@deriving show, yojson]
  type group = { kind : kind; content_count : int }
  [@@deriving show, yojson]
  type t = group list [@@deriving show, yojson]

  val metadata_key : string
  val phase_of_fields : (string * Yojson.Safe.t) list -> (phase, string) result
  val phase_fields : phase -> (string * Yojson.Safe.t) list
  val partition : content:'source content_block_with list -> t -> ((kind * 'source content_block_with list) list, string) result
  val make : content:'source content_block_with list -> group list -> (t, string) result
  val metadata : t -> string * Yojson.Safe.t
  val of_metadata : content:'source content_block_with list -> (string * Yojson.Safe.t) list -> (t option, string) result
  val retain : original_content:'source content_block_with list -> content:'source content_block_with list -> retained_indices:int list -> t -> (t, string) result
  val retain_metadata : original_content:'source content_block_with list -> content:'source content_block_with list -> retained_indices:int list -> (string * Yojson.Safe.t) list -> ((string * Yojson.Safe.t) list, string) result
end

type reported_model =
  | Provider_reported_model of string
  | Provider_model_not_reported
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
  ; reported_model : reported_model option [@default None]
    (** Captured by the raw response parser before model fallback. [None]
        means no such capture exists; it never licenses a model inference
        from [api_response.model] or the configured request model. *)
  ; reasoning_source : Reasoning_source.t option
    (** Exact replay provenance stamped by the live inference boundary. *)
  ; reasoning_prefix : Reasoning_prefix.t option
    (** Creation-prefix identity for the response's reasoning, when the wire
        binds signatures to the prefix. [None] on wires without a binding,
        and on responses whose request predates the digest. *)
  ; inline_content_replay : Inline_content_replay.t option
    (** Original Chat content bytes and canonical occurrence binding. *)
  ; response_replay : Response_replay.t option
    (** Native output grouping retained through cache and assistant history. *)
  ; effective_context_window : int option
    (** Context window in tokens the request was sized against, as
        [Provider_config.context_window] reports it for the request config. *)
  ; provider_internal_action_count : int option
    (** Telemetry-only count of provider-native actions that are not surfaced as AGENT_CORE tool calls. *)
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

(** Default/zero inference telemetry value owned by the telemetry type module.
    Callers should record-update this value instead of duplicating every field. *)
val default_inference_telemetry : inference_telemetry

val with_reported_model : model:string -> inference_telemetry option -> inference_telemetry
(** Raw parser boundary only: preserve the observed model or its explicit
    absence before any response normalization. Repatching telemetry must
    retain this fact rather than recapture a fallback-normalized model. *)

type api_response =
  { id : string
  ; model : string
  ; stop_reason : stop_reason
  ; content : content_block list
  ; usage : api_usage option
  ; telemetry : inference_telemetry option
  }
[@@deriving show]

(** Retain admitted response occurrences and remap both replay witnesses.
    Tool admission supplies exact source indices; no structural identity guess. *)
val retain_response_content
  :  retained_indices:int list
  -> content:content_block list
  -> api_response
  -> (api_response, string) result

type assistant_message_error =
  | Reasoning_source_telemetry_missing
  | Reasoning_source_missing
  | Invalid_response_replay of string
[@@deriving show]

(** Whether any block is a reasoning artifact a replay boundary must justify. *)
val content_has_reasoning_artifact : content_block list -> bool

(** Convert a provider response into the Assistant history message callers
    should append. Reasoning-bearing responses require exact replay
    provenance; plain responses remain metadata-free. A carried
    [reasoning_prefix] is stamped alongside the source; its absence is not
    an error here — replay fails closed on binding wires instead. *)
val assistant_message_of_response
  :  api_response
  -> (message, assistant_message_error) result

(** {1 SSE Streaming Types} *)

type content_delta =
  | TextDelta of string
  | TextSnapshot of string
  (** A complete text value at this content-block index. Unlike [TextDelta],
          this explicitly authorizes exact-prefix reconciliation; ordinary
          incremental chunks must remain [TextDelta]. *)
  | ThinkingDelta of string
  | ThinkingSnapshot of string
  (** Complete unsigned plaintext after provider-native channel reconciliation.
      Replaces previous thinking text, including a superseded summary; never
      an incremental fragment or permission to rewrite signed reasoning. *)
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
          does not concatenate it into invalid JSON. *)
  | MediaDelta of
      { media_type : string
      ; source : media_source
      }
  (** A chunk of a streamed media (image/document/audio) content block.
            Carries block-level [media_type] and a [source] whose payload is
            this chunk, so no new {!ContentBlockStart} fields are required.
            Consumers collect chunks with {!media_chunks_add}. *)

(** A provider condition an OpenAI-compatible provider declared for an error it
    reported inside a response it had already accepted with [200]: rate limited
    ([429]) or failing itself ([5xx]). No other status is carried; the reader
    ([Openai_error_envelope]) says why.

    [status] is that HTTP status. [error_body] is the body the failure is
    classified from as a refusal with that status: only the provider's error
    object, serialized as [{"error": <error object>}], so
    [Retry.classify_error] reads its [message] and [retry_after] whether the
    object sat at the top level of the response or on a choice, and nothing
    else the response carried (choice content, tool arguments, usage) becomes
    part of the refusal. *)
type provider_status =
  { status : int
  ; error_body : string
  }

(** Where an error a provider reported inside an accepted response came from.
    - [Provider_stated]: an [error] member arrived and the values beside this
      one are what it said.
    - [Unstated_errored_choice]: the choice finished with [error]
      ({!Stop_reason_wire.is_provider_error_finish}) and no [error] member
      arrived anywhere in the response. The provider ended the generation and
      kept the reason to itself, so there is nothing to read a type or a
      status from. *)
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
  | InlineContentReplay of { raw_content : string; block_indices : int list }
    (** Terminal raw Chat content and native stream block identities. *)
  | ResponsesOutputItems of (Response_replay.kind * int list) list
  (** Terminal native item grouping, referencing canonical stream block indices.
      This carries no text, tool arguments or provider response payload. *)
  | MessageStop
  | Ping
  | SSEError of
      { message : string
      ; error_type : string option
      ; provider_status : provider_status option
      ; report : provider_report
      ; raw : string
      }
  (** A provider-reported error delivered mid-stream. [error_type] is the
            provider's error-object [type] discriminator (e.g.
            ["rate_limit_exceeded"]) and [raw] the original error JSON, so the
            consumer can converge onto the same classification path as an
            initial HTTP error instead of collapsing to [NetworkError {Unknown}].
            [provider_status] is the {!provider_status} the provider declared
            inside the envelope, because the stream's own [200] was already
            sent; [None] when the envelope declares none. [raw] stays the whole
            payload, for diagnostics. *)
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
            type the AGENT_CORE adapter has not yet learned. Emit explicitly so
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
    distinct at the transport boundary; retry policy is decided above AGENT_CORE. *)
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

(** Canonical decision for one provider stream event. *)
type stream_event_resolution =
  | Stream_event_accepted of sse_event
  | Stream_event_suppressed
  | Stream_event_rejected of stream_error

(** {1 Convenience Constructors} *)

(** These build blocks and messages over any media source. *)

val make_message
  :  ?name:string
  -> ?tool_call_id:string
  -> ?origin:message_origin
  -> ?metadata:(string * Yojson.Safe.t) list
  -> role:role
  -> 'source content_block_with list
  -> 'source message_with

val text_block : string -> 'source content_block_with

val image_block : media_type:string -> source:'source -> 'source content_block_with

val document_block : media_type:string -> source:'source -> 'source content_block_with

val audio_block : media_type:string -> source:'source -> 'source content_block_with

val text_message : role -> string -> 'source message_with
val user_msg_blocks : 'source content_block_with list -> 'source message_with
val system_msg : string -> 'source message_with
val user_msg : string -> 'source message_with
val assistant_msg : string -> 'source message_with
val try_parse_json : string -> Yojson.Safe.t option

val tool_result_msg
  :  tool_use_id:string
  -> content:string
  -> ?outcome:tool_result_outcome
  -> ?json:Yojson.Safe.t
  -> unit
  -> 'source message_with

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
  -> 'source content_block_with
  -> (unit, tool_result_validation_error) result

val text_of_content : 'source content_block_with list -> string
val text_of_message : 'source message_with -> string
val text_of_response : api_response -> string

(** End-user-visible assistant text projection.

    Unlike {!text_of_content}, these helpers only include [Text] blocks. They
    intentionally exclude [Thinking], [RedactedThinking], [ToolUse],
    [ToolResult], and media blocks so downstream answer surfaces do not leak
    reasoning or execution payloads. *)
val visible_text_of_content : 'source content_block_with list -> string

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
