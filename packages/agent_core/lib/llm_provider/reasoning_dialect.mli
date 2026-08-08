(** Provider reasoning/thinking dialect semantics.

    {!Capabilities.thinking_control_format} describes the request wire field
    used to toggle thinking. This module keeps the adjacent semantics in one
    typed record: default toggle state, effort aliases, sampling interactions,
    and history replay policy.

    The intent is to keep provider policy in OAS while letting downstream
    agent runtimes decide how to surface or pause around reasoning events.

    @since 0.207.0 *)

type toggle_default =
  | Enabled
  | Disabled
  | Provider_default

type toggle_wire =
  | No_toggle
  | Thinking_object of { includes_reasoning_effort : bool }
  | Thinking_object_adaptive
  | Thinking_object_only
  | Chat_template_kwargs
  | Chat_template_token
  | Ollama_think
  | Reasoning_effort
  | Enable_thinking
  | Anthropic_thinking
  | Gemini_thinking_config

type effort_alias_policy =
  | Preserve_effort
  | Deepseek_high_or_max

type sampling_policy =
  { ignored_always : Capabilities.sampling_parameter list
  ; ignored_when_thinking : Capabilities.sampling_parameter list
  }

(** The reasoning-replay vocabulary is the leaf
    {!Reasoning_replay_contract} one, re-exported here as a type equation
    rather than restated. There is no dialect-level synonym set and therefore
    no dialect-to-contract translation table to keep in sync: a new policy is
    added in exactly one module and every consumer sees the same constructor. *)
type replay_policy = Reasoning_replay_contract.replay_policy =
  | No_replay
  | Tool_call_assistant_messages_all_history
  | Tool_call_assistant_messages_latest_user_turn
  | All_assistant_messages
  | Provider_opaque_state

type streaming_reasoning = Reasoning_replay_contract.streaming_reasoning =
  | No_streaming_reasoning
  | Delta_field of string
  | Delta_reasoning_details
  | Template_parser

type output_wire = Reasoning_replay_contract.output_wire =
  | No_output_control
  | Reasoning_split

type thinking_object_only_control =
  { enabled : bool option
  ; keep_all : bool
  }

(** OpenAI-compatible request envelope selected by the typed HTTP codec. *)
type openai_request_wire =
  | Chat_completions
  | Responses

(** Concrete wire location that satisfied an explicit
    [enable_thinking = Some true] request. *)
type explicit_enable_encoding =
  | Request_control_field
  | Chat_template_system_token

type explicit_enable_receipt =
  | Explicit_enable_not_requested
  | Explicit_enable_encoded of explicit_enable_encoding
  | Explicit_enable_not_encoded

(** Immutable request-control projection. [fields] are the exact JSON members
    for the selected OpenAI-compatible envelope; the receipts are derived in
    the same exhaustive dialect branch, so admission cannot claim an encoding
    that the serializer does not own. *)
type request_control_artifact =
  { fields : (string * Yojson.Safe.t) list
  ; explicit_enable_receipt : explicit_enable_receipt
  }

type request_control_rejection =
  | Thinking_budget_unsupported
  | Reasoning_effort_unsupported
  | Reasoning_effort_value_unsupported of Reasoning_effort.t

val request_control_rejection_to_message : request_control_rejection -> string

type t =
  { toggle_default : toggle_default
  ; toggle_wire : toggle_wire
  ; preserve_wire : Capabilities.preserve_thinking_control_format
  ; effort_alias_policy : effort_alias_policy
  ; sampling_policy : sampling_policy
  ; replay_policy : replay_policy
  ; streaming : streaming_reasoning
  ; output_wire : output_wire
  }

val default : t
val of_capabilities : Capabilities.capabilities -> t

(** Request-local dialect: the capability base, then the [preserve_thinking]
    knob, then the declared clear-thinking replay gate, then the transport
    override. *)
val for_provider_config : Provider_config.t -> t

val replay_contract : t -> Reasoning_replay_contract.t

(** Declared rotation rule for [dialect], derived from its typed wire facts
    only. See {!Reasoning_replay_contract.rotation_policy}. *)
val rotation_policy : t -> Reasoning_replay_contract.rotation_policy

(** Provenance stamped on a response produced by [config]. Derived from the
    stable provider/model/transport shape, so request-local knobs never change
    the identity of an already-produced artifact. *)
val reasoning_source_for_provider_config
  :  Provider_config.t
  -> (Types.Reasoning_source.t, string) result

(** Everything the reasoning-replay path needs for one request, resolved once.

    Provider identity is consulted while building this record and nowhere
    downstream: the projection, the serializer and the request builder read
    [target], [contract] and [rotation] instead of re-deriving a provider kind,
    an endpoint, or a model name. *)
type replay_capability =
  { target : Types.Reasoning_source.t
    (** Provenance this request replays into, and the stamp its own response
        carries. *)
  ; contract : Reasoning_replay_contract.t
    (** Request-local replay/streaming/output contract. *)
  ; rotation : Reasoning_replay_contract.rotation_policy
    (** What a stored artifact from a different source may still do. *)
  }

val replay_capability_for_provider_config
  :  Provider_config.t
  -> (replay_capability, string) result

val with_preserve_thinking : preserve_thinking:bool option -> t -> t
val thinking_enabled : enable_thinking:bool option -> bool

val thinking_object_only_control
  :  t
  -> enable_thinking:bool option
  -> preserve_thinking:bool option
  -> thinking_object_only_control

val chat_template_kwargs_preserve_field
  :  t
  -> preserve_thinking:bool option
  -> bool option

val top_level_preserve_field : t -> preserve_thinking:bool option -> bool option

val ignores_sampling_param
  :  t
  -> enable_thinking:bool option
  -> Capabilities.sampling_parameter
  -> bool

(** Canonical OpenAI-compatible thinking-control request artifact for a dialect.

    This is the single source of truth for both request-body fields and typed
    admission receipts. The low-level [Provider_config]-based builder, the
    high-level Agent API builder, the Responses builder, and Complete preflight
    all consume projections of this artifact. [clear_thinking_object] carries
    the resolved [thinking.clear_thinking] member for rows whose
    {!Capabilities.preserve_thinking_control_format} is
    [Thinking_object_clear_thinking]: those rows have no ordinary thinking
    control yet still accept a provider [thinking] object. The caller resolves
    it from that typed capability, never from a provider identity. *)
val request_control_fields
  :  openai_request_wire
  -> t
  -> enable_thinking:bool option
  -> preserve_thinking:bool option
  -> thinking_budget:int option
  -> reasoning_effort:Reasoning_effort.t option
  -> ?clear_thinking_object:bool
  -> unit
  -> (request_control_artifact, request_control_rejection) result

(** Normalize a typed caller effort for a provider dialect. *)
val normalize_effort_value : t -> Reasoning_effort.t -> string option

val sampling_params_ignored_when_thinking : t -> Capabilities.sampling_parameter list

(** [true] when [parameter] is a sampling parameter the wire format ignores
    while thinking is enabled. Thinking defaults on: only an explicit
    [enable_thinking = Some false] keeps the field. Provider-controlled
    always-suppressed parameters such as Kimi fixed sampling are represented by
    the full {!t} policy instead of this format-only helper. Keyed on
    {!Capabilities.thinking_control_format} so the [Provider_config]-based
    request builder ([Backend_openai_request]) drops the same parameters
    consistently; the public path only has the format, not a full {!t}. *)
val sampling_field_ignored_when_thinking
  :  thinking_control_format:Capabilities.thinking_control_format
  -> enable_thinking:bool option
  -> parameter:Capabilities.sampling_parameter
  -> bool

(** Whether an assistant reasoning side-channel should be replayed into a
    subsequent request based on message shape. [assistant_had_tool_call] is
    intentionally explicit: DeepSeek-style thinking requires replay after tool
    calls but can drop reasoning between plain user turns. Position-sensitive
    policies are finalized by {!Reasoning_history_projection} from the typed
    {!replay_contract}; this function reports only shape eligibility. *)
val should_replay_reasoning : t -> assistant_had_tool_call:bool -> bool

val requires_reasoning_replay_on_tool_call : t -> bool
val toggle_wire_to_string : toggle_wire -> string
val replay_policy_to_string : replay_policy -> string
