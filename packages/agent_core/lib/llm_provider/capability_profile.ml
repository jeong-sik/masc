(** Immutable capability records and provider presets. No catalog lookup,
    configuration, credentials or process-global state is read here. *)

(** Provider capabilities -- per-provider/model feature flags and limits.

    Tracks what a provider/model supports so the agent runtime can make
    correct decisions (e.g., context reduction, tool filtering, thinking
    budget enforcement).

    @since 0.42.0
    @since 0.72.0 — added numeric limits, parallel tool calls, thinking split *)

(** Wire-format for controlling thinking/reasoning on OpenAI-compat backends.
    Different model families use different JSON shapes to enable/disable
    thinking, so the runtime must know which format to emit.

    @since 0.184.0 *)
type thinking_control_format = Capability_vocab.thinking_control_format =
  | No_thinking_control (** No thinking control supported *)
  | Thinking_object (** Top-level [thinking] object plus optional [reasoning_effort]. *)
  | Thinking_object_adaptive
  | Thinking_object_only
  | Chat_template_kwargs
  | Chat_template_token of string
  (** Thinking toggled by a chat-template token (e.g. [<|think|>]) emitted in
          the system turn; the token is carried in the constructor. *)
  | Ollama_think
  | Reasoning_effort
  | Reasoning_effort_default_on
  | Reasoning_enabled
[@@deriving show, eq]

let%test "thinking_control_format derives equal and show" =
  equal_thinking_control_format No_thinking_control No_thinking_control
  && (not (equal_thinking_control_format No_thinking_control Reasoning_effort))
  && String.length (show_thinking_control_format Reasoning_effort) > 0
;;

type preserve_thinking_control_format =
      Capability_vocab.preserve_thinking_control_format =
  | No_preserve_thinking_control
  | Thinking_object_keep_all
  | Chat_template_kwargs_preserve_thinking
  | Always_preserved_thinking
  | Thinking_object_clear_thinking
  (** Provider [thinking] object whose [clear_thinking] member gates prior-turn
      reasoning replay. See {!Capability_vocab.preserve_thinking_control_format}. *)

(** Optional override for the multi-turn reasoning replay policy. Most providers
    inherit the policy implied by [thinking_control_format]; catalog entries set
    this when a model's documented replay contract differs (e.g. Kimi K2 requires
    replaying [reasoning_content] on every turn, so [Force_preserve_always]).

    @since 0.207.16 *)
type uncontrolled_reasoning = Capability_vocab.uncontrolled_reasoning =
  | Provider_default_reasoning
  | Provider_enables_reasoning

type reasoning_replay_override = Capability_vocab.reasoning_replay_override =
  | Default_reasoning_replay
  | Force_no_replay
  | Force_drop_without_tool_preserve_with_tool
  | Force_latest_user_turn_tool_calls
  | Force_initial_system_latest_user_turn_tool_calls
  (** Replay tool-call reasoning only inside the structurally latest user turn. *)
  | Force_preserve_always
  | Force_preserve_responses_text
  | Force_turn_scoped_system_context_preserve_always
  | Force_preserve_with_request_tools

type assistant_tool_content_format = Capability_vocab.assistant_tool_content_format =
  | Assistant_tool_content_null
  | Assistant_tool_content_empty_string

type chat_output_budget_field = Capability_vocab.chat_output_budget_field =
  | Chat_max_tokens
  | Chat_max_completion_tokens

type tool_schema_conformance = Capability_vocab.tool_schema_conformance =
  | Rich_json_schema
  | Conformant_subset_required

type content_inline_reasoning = Capability_vocab.content_inline_reasoning =
  | No_content_inline_reasoning
  | Think_tags
  | Think_tags_with_chat_replay
  | Content_chunks

type reasoning_output_format = Capability_vocab.reasoning_output_format =
  | No_reasoning_output_format
  | Split_reasoning_fields

type reasoning_streaming_format = Capability_vocab.reasoning_streaming_format =
  | Default_reasoning_streaming
  | No_reasoning_streaming
  | Delta_reasoning_field of string
  | Delta_reasoning_field_and_details of string
  | Template_reasoning_streaming

type sampling_parameter = Capability_vocab.sampling_parameter =
  | Temperature
  | Top_p
  | Top_k
  | Min_p
  | Presence_penalty
  | Frequency_penalty
  | Seed

(** Catalog-declared inference task for non-chat models. [None] on every
    chat/completion model; a value is only ever set by an explicit [task]
    field on a model catalog entry — never inferred from the model id. *)
type task = Capability_vocab.task =
  | Transcription
  | Speech
  | Image_generation
  | Video_generation

(** Structured-output tier, projected from the two capability booleans below by
    {!structured_output_support}. The request-admission decision reads this typed
    view rather than provider identity. See {!Capability_vocab.structured_output_support}. *)
type structured_output_support = Capability_vocab.structured_output_support =
  | No_structured_output
  | Json_object_only
  | Native_json_schema
[@@deriving show, eq]

type json_schema_dialect = Capability_vocab.json_schema_dialect =
  | Openai_json_schema
  | Json_object_schema

type anthropic_thinking_control =
  | Anthropic_adaptive_default
  | Anthropic_adaptive_disabled_through_high
  | Anthropic_adaptive_between_tools
  | Anthropic_always_adaptive

let anthropic_thinking_control_of_vocab_value = function
  | Capability_vocab.Adaptive_default -> Anthropic_adaptive_default
  | Capability_vocab.Adaptive_disabled_through_high -> Anthropic_adaptive_disabled_through_high
  | Capability_vocab.Adaptive_between_tools -> Anthropic_adaptive_between_tools
  | Capability_vocab.Always_adaptive -> Anthropic_always_adaptive
;;

type capabilities =
  { (* ── Numeric limits ────────────────────────────────── *)
    max_context_tokens : int option (** Model's context window. None = unknown. *)
  ; serving_constraint : Serving_constraint.t option
  ; max_output_tokens : int option (** Model's max output. None = unknown. *)
  ; (* ── Tool use ──────────────────────────────────────── *)
    supports_tools : bool
  ; supports_tool_choice : bool
  ; supports_required_tool_choice : bool
  ; supports_named_tool_choice : bool
  ; supports_parallel_tool_calls : bool
  ; assistant_tool_content_format : assistant_tool_content_format
    (** Wire shape for assistant messages that contain tool calls but no visible
        text. OpenAI-compatible providers disagree here: OpenAI accepts
        [content:null], while GLM's OpenAI-compatible contract keeps
        [content:""]. This is independent from reasoning replay. *)
  ; chat_output_budget_field : chat_output_budget_field
    (** Which Chat Completions field carries the output-token budget: the
        classic [max_tokens] or the reasoning-era [max_completion_tokens]
        OpenAI's gpt-5 family requires. Emission-side field name only; the
        #2517 receipt policy (omit/clamp) is unchanged. *)
  ; tool_schema_conformance : tool_schema_conformance
    (** Whether this model's provider rejects enum/oneOf/anyOf/allOf inside
        function parameter schemas. When conformant-only, the request
        serializer projects tool schemas down to the allowed subset; the
        dispatcher's [[params]] validation remains the authority. *)
  ; (* ── Thinking / reasoning ──────────────────────────── *)
    supports_reasoning : bool (** Any form of reasoning/thinking *)
  ; accepted_reasoning_efforts : Reasoning_effort.t list option
    (** Model/provider-specific subset of canonical reasoning efforts accepted
        by the request wire format. [None] means no subset is declared and the
        dialect vocabulary applies; [Some values] is enforced before request
        serialization. *)
  ; thinking_control_format : thinking_control_format
    (** Wire-format for thinking control on OpenAI-compat backends.
        Determines which JSON shape the backend emits for enable_thinking.
        Only meaningful when [supports_reasoning]
        is true and the request goes through backend_openai.
        @since 0.184.0 *)
  ; preserve_thinking_control_format : preserve_thinking_control_format
    (** Wire-format for preserving historical reasoning between requests.
        This is intentionally separate from [thinking_control_format]: some
        models use [thinking.keep], some have no request toggle but require
        replay, and Qwen-style chat templates use a nested boolean. *)
  ; content_inline_reasoning : content_inline_reasoning
  ; reasoning_output_format : reasoning_output_format
    (** Request-side control for where provider reasoning is returned. Some
        OpenAI-compatible providers require an explicit split switch before
        returning reasoning in side-channel fields instead of embedding it in
        visible [content]. *)
  ; reasoning_streaming_format : reasoning_streaming_format
    (** Optional streaming side-channel override. [Default_reasoning_streaming]
        derives the parser field from [thinking_control_format]; catalog entries
        set a concrete value when the endpoint stream field differs from the
        request-side thinking control shape. *)
  ; uncontrolled_reasoning : uncontrolled_reasoning
  ; reasoning_replay_override : reasoning_replay_override
    (** Optional override for the multi-turn reasoning replay policy. Defaults to
        the policy implied by [thinking_control_format]; catalog entries set this
        when the model's documented replay contract differs (e.g. Kimi K2). *)
  ; (* ── Output format ─────────────────────────────────── *)
    supports_response_format_json : bool (** JSON mode *)
  ; supports_structured_output : bool (** JSON schema 100% guarantee *)
  ; json_schema_dialect : json_schema_dialect
  ; (* ── Input modalities ──────────────────────────────── *)
    supports_multimodal_inputs : bool (** Any non-text input *)
  ; supports_image_input : bool
  ; declared_image_input : bool option
  ; supports_audio_input : bool
  ; supports_video_input : bool
  ; supports_document_input : bool
    (** Whether the row accepts a [Document] block as input.

        Deliberately a sibling of the image/audio/video fields rather than a
        reading of [supports_multimodal_inputs]: document support is not
        implied by image support (a vision row on the OpenAI-compatible Chat
        Completions wire may accept images and have no document part at all),
        and the catch-all cannot express the difference. Serialization consults
        this at admission, so a document that the row cannot carry is reported
        instead of being emitted as some other modality (agent-core boundary). *)
  ; modality_priority : Modality.priority
    (** Block ordering applied to multimodal user messages just before
        serialization. [Visual_first] for Gemma 4 family.
        @since 0.193.0 *)
  ; (* ── Inference task ────────────────────────────────── *)
    task : task option
    (** Inference task declared by the model catalog entry (transcription,
        speech, image/video generation). [None] = no declared task; there is
        no model-id inference fallback. *)
  ; (* ── Protocol ──────────────────────────────────────── *)
    supports_native_streaming : bool
  ; supports_system_prompt : bool
  ; supports_assistant_prefill : bool
  ; supports_prompt_caching : bool
  ; (* ── Sampling parameters ───────────────────────────── *)
    supports_top_k : bool
  ; supports_min_p : bool
  ; supports_seed : bool (** Deterministic seed for reproducible sampling. *)
  ; ignored_sampling_parameters : sampling_parameter list
    (** Request sampling parameters that must not be serialized for this
        provider/model even when a caller supplied them. This is catalog data,
        not a model-id heuristic. *)
  ; (* ── Usage reporting ─────────────────────────────────── *)
    emits_usage_tokens : bool
    (** True when the provider's standard response carries
      [input_tokens]/[output_tokens] (direct APIs like Anthropic,
      OpenAI_compat, Gemini, Kimi, Glm, Ollama).

      Consumers use this to decide whether a text-only turn with no
      usage should be treated as a structurally unreported one
      (not a coverage gap) vs. a real gap. *)
  ; (* ── Model limitations ────────────────────────────────── *)
    supported_models : string list option
  }

let default_capabilities =
  { max_context_tokens = None
  ; serving_constraint = None
  ; max_output_tokens = None
  ; supports_tools = false
  ; supports_tool_choice = false
  ; supports_required_tool_choice = false
  ; supports_named_tool_choice = false
  ; supports_parallel_tool_calls = false
  ; assistant_tool_content_format = Assistant_tool_content_null
  ; chat_output_budget_field = Chat_max_tokens
  ; tool_schema_conformance = Rich_json_schema
  ; supports_reasoning = false
  ; accepted_reasoning_efforts = None
  ; thinking_control_format = No_thinking_control
  ; preserve_thinking_control_format = No_preserve_thinking_control
  ; content_inline_reasoning = No_content_inline_reasoning
  ; reasoning_output_format = No_reasoning_output_format
  ; reasoning_streaming_format = Default_reasoning_streaming
  ; uncontrolled_reasoning = Provider_default_reasoning
  ; reasoning_replay_override = Default_reasoning_replay
  ; supports_response_format_json = false
  ; supports_structured_output = false
  ; json_schema_dialect = Openai_json_schema
  ; supports_multimodal_inputs = false
  ; supports_image_input = false
  ; declared_image_input = None
  ; supports_audio_input = false
  ; supports_video_input = false
  ; supports_document_input = false
  ; modality_priority = Modality.Preserve_input_order
  ; task = None
  ; supports_native_streaming = false
  ; supports_system_prompt = true
  ; supports_assistant_prefill = true
  ; supports_prompt_caching = false
  ; supports_top_k = false
  ; supports_min_p = false
  ; supports_seed = false
  ; ignored_sampling_parameters = []
  ; emits_usage_tokens = true (* stricter default: most providers report usage *)
  ; supported_models = None
  }
;;

(** Structured-output tier a resolved capability record advertises.

    Single typed view the request-admission decision
    ({!Provider_config.validate_output_schema_request}) reads instead of
    branching on provider identity. It is a total projection of the two
    independent, catalog-sourced booleans — [supports_structured_output] (native
    json_schema) and [supports_response_format_json] (json_object mode) — which
    the provider catalog, model catalog, capability manifest, and public view
    already thread. It is deliberately not a stored field: the two booleans stay
    the single source of truth (they are separate, non-interchangeable contracts
    per docs/provider-capabilities-spec.md), so this projection cannot drift.

    A native schema guarantee is the top tier regardless of the JSON-mode flag,
    so both [(structured=true, json=true)] and [(structured=true, json=false)]
    map to [Native_json_schema]. JSON mode without a native schema field is
    [Json_object_only]; neither flag is [No_structured_output]. *)
let structured_output_support (caps : capabilities) : structured_output_support =
  if caps.supports_structured_output
  then Native_json_schema
  else if caps.supports_response_format_json
  then Json_object_only
  else No_structured_output
;;

let with_declared_image_input value capabilities =
  { capabilities with supports_image_input = value; declared_image_input = Some value }
;;

let anthropic_capabilities =
  { default_capabilities with
    max_context_tokens = Some 200_000
  ; (* default; opus/sonnet 4.6 = 1M *)
    max_output_tokens = Some 8_192
  ; (* default; higher for newer models *)
    supports_tools = true
  ; supports_tool_choice = true
  ; supports_required_tool_choice = true
  ; supports_named_tool_choice = true
  ; supports_parallel_tool_calls = true
  ; supports_reasoning = true
  ; supports_structured_output = true
  ; supports_multimodal_inputs = true
  ; (* The Messages API has a first-class [document] content block with its own
       [source] object (docs.anthropic.com/en/docs/build-with-claude/pdf-support);
       {!Api_common.content_block_to_json} emits exactly that shape. *)
    supports_document_input = true
  ; supports_native_streaming = true
  ; supports_prompt_caching = true
  ; (* Anthropic Messages API documents [top_k] as a valid sampling
     parameter ("Only sample from the top K options for each
     subsequent token", docs.anthropic.com/en/api/messages body
     params). [backend_anthropic.build_request] already serializes
     [config.top_k] unconditionally when [Some]; the capability record
     must match so cross-layer consumers (the #831 Api_openai gate,
     the #830 Backend_openai gate, and the capability_filter passes)
     do not silently drop top_k when the caller routes an Anthropic
     config through a capability-checking path. [supports_min_p]
     remains [false] — Anthropic does not accept min_p. *)
    supports_top_k = true
  }
  |> with_declared_image_input true
;;

let kimi_capabilities =
  { default_capabilities with
    max_context_tokens =
      Some 256_000
      (* platform.kimi.ai documents only the default max_tokens (32768); it does
       not state a higher output ceiling. Keep the verified default here. A
       higher ceiling (if any) is deferred to the per-provider capability pass. *)
  ; max_output_tokens = Some 32_768
  ; supports_tools = true
  ; supports_tool_choice = true
  ; (* Kimi's chat API documents [tools] but not [tool_choice] in any request
     schema (platform.kimi.ai/docs/api/chat covers KimiK27Code/K26/K25/MoonshotV1
     request bodies; none expose tool_choice), and tool_choice=required is
     unsupported — developers prompt the model to force a tool instead. Plain
     [auto] passes through the OpenAI-compatible endpoint so [supports_tool_choice]
     stays true, but a forced *named* tool_choice has no faithful wire
     representation. AGENT_CORE therefore treats Kimi like GLM: tools supported, named
     forced tool_choice rejected with a typed [Unsupported_named_tool_choice]
     rather than serialized into a request the model cannot honor. This is the
     conservative declaration-over-probing default (same rationale as the Ollama
     profile); a deployment that verified native named support can still override
     per-entry via the model catalog. Ref checked 2026-06-30:
     platform.kimi.ai/docs/api/chat, platform.kimi.ai/docs/api/tool-use. *)
    supports_required_tool_choice = false
  ; (* Same Kimi contract: named forced tool_choice has no faithful wire
       representation. Keep required/named separated so Auto/None remain valid. *)
    supports_named_tool_choice = false
  ; supports_parallel_tool_calls = true
  ; supports_reasoning = true
  ; thinking_control_format = No_thinking_control
  ; preserve_thinking_control_format = Always_preserved_thinking
  ; reasoning_replay_override =
      Force_preserve_always
      (* Kimi K2 docs (platform.moonshot.ai, checked 2026-06-29): reasoning_content
       must be replayed across turns — hard-required on tool-call turns
       ("otherwise an error will be thrown") and recommended on all turns;
       kimi-k2.7-code keeps Preserved Thinking always-on. The base Kimi profile
       carries [Always_preserved_thinking], and this typed override preserves the
       same replay contract for catalog rows whose per-entry capabilities inherit
       base="kimi" without repeating the policy. *)
  ; supports_response_format_json = true
  ; (* Path-dependent, so keep the builtin declaration false. The platform
       chat-completions API documents response_format json_schema with
       strict=true (MFJS spec) — platform.kimi.ai/docs/api/chat, checked
       2026-07-03 — and the Kimi Code coding-plan gateway honors it on its
       OpenAI-compatible path (measured 10/10 schema compliance at
       api.kimi.com/coding/v1/chat/completions). But this builtin speaks the
       Anthropic-compatible /v1/messages path, which silently ignores
       output_format and returns free text (measured 2026-07-03). A deployment
       that routes Kimi through an OpenAI-compatible provider config can
       override per-entry via the model catalog. Ollama Cloud Kimi rows are
       provider-qualified and declare their own schema support. *)
    supports_structured_output = false
  ; supports_system_prompt = true
  ; supports_native_streaming = true
  ; supports_multimodal_inputs = true
  }
  |> with_declared_image_input true
;;

let openai_compat_chat_capabilities =
  (* [max_context_tokens] and [max_output_tokens] stay [None] (inherited from
     [default_capabilities]): this preset covers arbitrary OpenAI-compatible
     endpoints whose real windows agent core cannot know. A family-level guess
     becomes the limit of every catalog-silent model. For output it is the wire
     [max_tokens] and truncates long thinking; for context a caller that takes
     the smaller of its declared window and this value clamps a 1M-token model
     to the guess. Unknown means unknown — request builders omit the output
     field, context consumers use the caller's declared window or fail with a
     typed unknown-limit error, and per-model rows declare real ceilings. *)
  { default_capabilities with
    supports_tools = true
  ; supports_tool_choice = true
  ; supports_required_tool_choice = true
  ; supports_named_tool_choice = true
  ; supports_parallel_tool_calls = true
  ; supports_response_format_json = true
  ; supports_structured_output = true
  ; supports_multimodal_inputs = true
  ; supports_native_streaming = true
  ; supports_prompt_caching = false
  }
  |> with_declared_image_input true
;;

let openai_compat_chat_extended_capabilities =
  { openai_compat_chat_capabilities with
    supports_reasoning = true
  ; thinking_control_format = Reasoning_effort
  ; supports_top_k = true
  ; supports_min_p = true
  }
;;

(* A router publishes one effort contract for every model it serves: it accepts
   the whole ladder and maps a level the chosen model lacks to the nearest one
   it has, rather than refusing the request
   (https://openrouter.ai/docs/use-cases/reasoning-tokens, checked 2026-09-18).
   That makes the accepted set a property of the router, which is why it can be
   declared here instead of once per model row.

   [None_] is left out although the router accepts it. "The router takes the
   value" and "the model stops thinking" are different claims, and mapping to
   the nearest level turns the first into the second only by luck: a model with
   no off state receives the neighbouring level and reasons on. The cost of
   omitting it is that a caller asking to disable thinking is refused before
   dispatch and takes its other path; the cost of including it would be a reply
   the caller believes is thinking-free. A model whose off behaviour is
   documented or measured declares [None_] on its own catalog row. *)
let openrouter_capabilities =
  { openai_compat_chat_extended_capabilities with
    accepted_reasoning_efforts =
      Some
        [ Reasoning_effort.Minimal
        ; Reasoning_effort.Low
        ; Reasoning_effort.Medium
        ; Reasoning_effort.High
        ; Reasoning_effort.XHigh
        ; Reasoning_effort.Max
        ]
  }
;;

let%test "the router's ladder carries every level it maps, and no off value" =
  match openrouter_capabilities.accepted_reasoning_efforts with
  | None -> false
  | Some accepted ->
    (* The omission is the decision, so it is the assertion: a request asking
       this router to stop thinking is refused here rather than mapped to a
       neighbouring level and returned as a thinking-free reply. *)
    (not (List.mem Reasoning_effort.None_ accepted))
    && List.for_all
         (fun effort -> List.mem effort accepted)
         [ Reasoning_effort.Minimal
         ; Reasoning_effort.Low
         ; Reasoning_effort.Medium
         ; Reasoning_effort.High
         ; Reasoning_effort.XHigh
         ; Reasoning_effort.Max
         ]
;;

let mimo_capabilities =
  { openai_compat_chat_capabilities with
    max_context_tokens = Some 1_000_000
  ; max_output_tokens = Some 128_000
  ; supports_reasoning = true
  ; thinking_control_format = Thinking_object_only
  ; content_inline_reasoning = No_content_inline_reasoning
  ; reasoning_output_format = Split_reasoning_fields
  ; reasoning_streaming_format = Delta_reasoning_field "reasoning_content"
  ; reasoning_replay_override = Force_drop_without_tool_preserve_with_tool
  ; supports_required_tool_choice = false
  ; supports_named_tool_choice = false
  ; supports_response_format_json = true
  ; supports_structured_output = false
  ; supports_multimodal_inputs = false
  ; supports_audio_input = false
  ; supports_video_input = false
  ; supports_document_input = false
  ; supports_native_streaming = true
  }
  |> with_declared_image_input false
;;

(* Ollama OpenAI-compat endpoint behavior on tool_choice is model-dependent
   (docs.ollama.com/capabilities/tool-calling: the parameter is silently
   ignored for some models). Some Qwen3.5 deployments w/ native Jinja
   chat template do honor tool_choice:required in practice.

   Industry context: LiteLLM's model_prices_and_context_window.json
   registry lacks per-Ollama-model tool support flags for the same
   reason (see BerriAI/litellm#14067 — Ollama model metadata surfaces
   no authoritative capability flag, so any static table is a guess).

   Design choice here: declaration-over-probing. The default stays
   conservative (supports_tool_choice = false → contract relaxes to
   Allow_text_or_tool, text-only replies accepted even when the consumer
   asked for a tool). A consumer that has verified its model-side support
   states it on the model's catalog row, or -- for a model no row names --
   in its own runtime capability table. Agent Core does not
   match on [model_id] to guess model-side behavior — the consumer
   (e.g. a config loader that knows it deployed Qwen3.5 w/ the Jinja
   chat template) owns that policy. This is stricter than LiteLLM's
   static-table approach, which requires JSON edits + redeploy to
   flip capability, and avoids the fragile model_id pattern match that
   the Claude Agent SDK sidesteps by being single-provider. *)
(* NVIDIA NIM Nvidia: Llama-based OpenAI-compatible endpoint.
   Thinking uses chat_template_kwargs (same wire format as Ollama's
   llama-server backend). VL variants add image input.
   Ref: build.nvidia.com/nvidia docs, Nvidia model cards. *)
let provider_l_capabilities =
  { openai_compat_chat_extended_capabilities with
    supports_tool_choice = true
  ; supports_reasoning = true
  ; thinking_control_format = Chat_template_kwargs
  ; preserve_thinking_control_format = Chat_template_kwargs_preserve_thinking
  }
;;

let ollama_capabilities =
  { openai_compat_chat_extended_capabilities with
    supports_tool_choice = false
  ; supports_required_tool_choice = false
  ; supports_named_tool_choice = false
  ; supports_seed = true
  ; thinking_control_format = Ollama_think
  }
;;

(* Ollama Cloud is a distinct provider identity (its own base_url + auth).
   Reasoning-only replies still reach the user through the display path
   ([Api_common.text_blocks_to_string] includes [Thinking] blocks); they are no longer
   promoted into assistant answer text, which previously re-injected reasoning on
   replay and caused the CoT loop (#2236).

   IMPORTANT: do not inherit either exact-output capability from local Ollama.
   "Ollama's Cloud currently does not support structured outputs"
   (https://docs.ollama.com/capabilities/structured-outputs, re-read
   2026-09-22), so a schema request has no Cloud contract to run on.

   JSON mode is a second question, not the same one. The same page separates
   the schema-constrained form from plain JSON generation, and the
   OpenAI-compatible surface lists [response_format] among the fields it takes
   (https://docs.ollama.com/api/openai-compatibility). What the docs do not
   say is whether Cloud honours [response_format: json_object] for a given
   model, so this base answers no for both and a row that has been measured
   says otherwise for itself -- ten ollama_cloud rows below do. A reader who
   comes here to make those rows agree with this base should measure first:
   the difference is the only thing standing between the Librarian's JSON
   lane and these models. *)
let ollama_cloud_capabilities =
  { ollama_capabilities with
    supports_response_format_json = false
  ; supports_structured_output = false
  ; reasoning_replay_override =
      Force_latest_user_turn_tool_calls
      (* One contract for both wires of this provider. The native /api/chat
         takes each assistant message's [thinking] back with its tool calls
         (docs.ollama.com/capabilities/tool-calling), and the /v1 wire hands an
         assistant [reasoning] field to that same slot (ollama openai/openai.go
         [FromChatRequest], checked 2026-10-07). Before this the /v1 base fell
         back to no replay, so every row that did not repeat the declaration
         lost its reasoning between tool calls: 12 of the 19 ollama_cloud rows.
         On 2026-10-06 one of them (glm-5.3-flash) thought 13 times in the first
         48 steps of a keeper turn and never again over the next 1,579 tool
         calls. A row whose model needs another contract still declares its
         own. *)
  }
;;

(* The same provider over its other wire. [[providers]] ollama_cloud declares
   identity_kinds = ["ollama", "openai_compat"], and a deployment may point it
   at either; the preset above describes the native /api/chat one it names in
   [kind].

   On the OpenAI-compatible wire the native [think] toggle does not exist, so
   [Ollama_think] encodes nothing and a request carrying no control is not a
   request with thinking off -- Ollama turns reasoning on by itself: "Ollama
   auto-enables thinking for capable models when no reasoning_effort is
   provided" (ollama#14820, docs.ollama.com/api/openai-compatibility).

   The control this wire does have is [reasoning_effort]. The ladder was
   measured against https://ollama.com/v1 on 2026-08-27 with
   deepseek-v4-flash:0731, gemma4:31b, nemotron-3-ultra and kimi-k3:
   none/low/medium/high/max all answered, and minimal/xhigh were refused by
   the endpoint, which names the legal set in its own error -- 'invalid
   reasoning value: ... (must be "high", "medium", "low", "max", or "none")'.

   Structured output stays fail-closed for the same reason as the native
   preset: the Cloud contract has not changed. *)
let ollama_cloud_v1_capabilities =
  { ollama_cloud_capabilities with
    thinking_control_format = Reasoning_effort
    (* The sentence above, as a value the admission can read: this endpoint
       turns reasoning on by itself when the request carries no
       [reasoning_effort], so a model row that declares no effort here runs
       with reasoning on while its operator reads the config as off. Measured
       2026-09-15 against https://ollama.com/v1 with deepseek-v4.1-flash:cloud,
       three runs of one reasoning prompt, median reasoning characters: no
       control 1985, "high" 1996, "medium" 1767, "low" 1671, "none" 0. An
       uncontrolled request sits at the reasoning-on end of that ladder. *)
  ; uncontrolled_reasoning = Provider_enables_reasoning
  ; accepted_reasoning_efforts =
      Some
        [ Reasoning_effort.None_
        ; Reasoning_effort.Low
        ; Reasoning_effort.Medium
        ; Reasoning_effort.High
        ; Reasoning_effort.Max
        ]
  }
;;

let glm_capabilities =
  { default_capabilities with
    max_context_tokens = Some 200_000
  ; (* The ceiling for a GLM id with no row of its own. 40960 is the lowest
     limit a Z.AI endpoint has enforced: glm-5.1 refused anything higher on
     2026-04-12 with "Invalid request: `max_tokens` must be less than or equal
     to `40960`", on glm-coding and glm alike. On 2026-09-22 the glm-coding
     endpoint named [1,131072] for glm-5.1, and the glm-coding rows in
     models.toml carry their own measured ceilings; an id without a row keeps
     this lower bound. *)
    max_output_tokens = Some 40_960
  ; supports_tools = true
  ; (* Z.AI's function-calling docs currently document [tool_choice]
     as default [auto] and "only supports auto". AGENT_CORE therefore treats
     Glm as "tools supported, forced tool_choice unsupported":
     callers may still send tools, but named forced tool_choice requests
     are not serialized because GLM has no faithful representation for
     them. The completion contract must stay relaxed so direct Glm text
     replies do not count as contract violations. Ref checked 2026-04-21:
     https://docs.z.ai/guides/capabilities/function-calling *)
    supports_tool_choice = true
  ; supports_required_tool_choice = false
  ; supports_named_tool_choice = false
  ; assistant_tool_content_format = Assistant_tool_content_empty_string
  ; supports_reasoning = true
  ; supports_response_format_json = true
  ; (* Z.AI's current official docs describe JSON mode via
     response_format={"type":"json_object"} plus prompt/schema-in-text
     guidance, but do not document a native JSON-schema request field
     equivalent to Openai's json_schema response_format. AGENT_CORE therefore
     treats Glm as JSON-mode-only: supports_response_format_json=true
     but supports_structured_output=false. validate_output_schema_request
     rejects JsonSchema response formats for Glm configs to prevent silent
     pass-through of schemas the provider will not enforce.
     Ref: https://docs.z.ai/guides/capabilities/struct-output — checked 2026-04-21. *)
    supports_structured_output = false
  ; supports_native_streaming = true
  ; (* Z.AI's chat-completion API carries the thinking toggle in a top-level
       [thinking] object. [clear_thinking = false] retains reasoning across user
       turns; interleaved tool reasoning remains part of the active exchange.
       Declaring the wire here makes that replay policy typed capability data:
       the dialect resolver reads [preserve_thinking_control_format], not a provider
       identity predicate (Agent Core contract S1.1/S3.1).
       Ref: https://docs.z.ai/api-reference/llm/chat-completion *)
    preserve_thinking_control_format = Thinking_object_clear_thinking
  }
;;

let gemini_capabilities =
  { default_capabilities with
    max_context_tokens = Some 1_000_000
  ; max_output_tokens = Some 65_000
  ; supports_tools = true
  ; supports_tool_choice = true
  ; supports_required_tool_choice = true
  ; supports_parallel_tool_calls = true
  ; supports_reasoning = true
  ; supports_response_format_json = true
  ; supports_structured_output = true
  ; supports_multimodal_inputs = true
  ; supports_audio_input = true
  ; supports_video_input = true
  ; (* [inlineData] carries an arbitrary MIME type plus base64 bytes, so a
       document keeps its own media type on the wire — the Gemini serializer
       does not relabel it. *)
    supports_document_input = true
  ; supports_native_streaming = true
  ; supports_prompt_caching = false
  ; (* Google Gemini's generateContent API documents [topK] as part of
     generationConfig (ai.google.dev/api/generate-content). The
     [backend_gemini.build_request] serializer already emits it at
     lib/llm_provider/backend_gemini.ml:162-164, so the capability
     record must match. Same discrepancy story as anthropic_capabilities
     (#832) — OpenAI-compat consumers that route a Gemini config
     through a capability-checking path were silently dropping top_k.
     [supports_min_p] stays false; Gemini's generationConfig has no
     min_p field. *)
    supports_top_k = true
  }
  |> with_declared_image_input true
;;

let capabilities_of_preset (preset : Capability_preset.t) : capabilities =
  match preset with
  | Anthropic -> anthropic_capabilities
  | Kimi -> kimi_capabilities
  | Openai_chat -> openai_compat_chat_capabilities
  | Ollama -> ollama_capabilities
  | Gemini -> gemini_capabilities
  | Glm -> glm_capabilities
  | Openai_chat_extended -> openai_compat_chat_extended_capabilities
  | Openrouter -> openrouter_capabilities
  | Cohere -> { openai_compat_chat_capabilities with json_schema_dialect = Json_object_schema }
  | Mimo -> mimo_capabilities
  | Ollama_cloud -> ollama_cloud_capabilities
  | Ollama_cloud_v1 -> ollama_cloud_v1_capabilities
  | Nvidia -> provider_l_capabilities
;;

let capabilities_of_kind (kind : Provider_kind.t) : capabilities =
  let preset : Capability_preset.t = match kind with
    | Anthropic -> Anthropic
    | Kimi -> Kimi
    | OpenAI_compat -> Openai_chat
    | Ollama -> Ollama
    | Gemini -> Gemini
    | Glm -> Glm in
  capabilities_of_preset preset
;;

let capabilities_for_provider_label label =
  Option.map capabilities_of_preset (Capability_preset.of_string label)
;;

let%test "capabilities_of_kind aliases the same presets as the label classifier" =
  (* Both label decoding and typed wire baselines resolve through the same
     closed preset, so these native presets share the exact same record. *)
  List.for_all
    (fun (kind, label) ->
       let via_kind = capabilities_of_kind kind in
       match capabilities_for_provider_label label with
       | Some via_label -> via_label == via_kind
       | None -> false)
    [ Provider_kind.Anthropic, "anthropic"
    ; Provider_kind.Kimi, "kimi"
    ; Provider_kind.OpenAI_compat, "openai_compat"
    ; Provider_kind.Ollama, "ollama"
    ; Provider_kind.Gemini, "gemini"
    ; Provider_kind.Glm, "glm"
    ]
;;

let%test "every base_label vocab value resolves to a preset (no false-reject)" =
  (* SSOT drift-guard (Agent Core contract): [Capability_vocab.base_label_values] is what
     the catalog/manifest parsers accept for a [base] field. If a listed value
     did NOT resolve here, the parser would accept a label that then silently
     collapses to [default_capabilities] — reopening the gap this closes. So
     every vocab value must resolve to [Some]. (The reverse — resolver labels not
     in the vocab — is caught loudly at parse time, not silently.) *)
  List.for_all
    (fun label -> Option.is_some (capabilities_for_provider_label label))
    Capability_vocab.base_label_values
;;

let%test "unknown base label resolves to None, not a permissive default" =
  (* The classifier fails closed on unrecognised labels; the parsers turn that
     [None] into a parse Error rather than [default_capabilities]. *)
  List.for_all
    (fun label -> Option.is_none (capabilities_for_provider_label label))
    [ "runpod_mtp"; "vllm"; "typo_label"; "" ]
;;

(** Merge Discovery ctx_size into capabilities. *)
let with_context_size caps ~ctx_size = { caps with max_context_tokens = Some ctx_size }

let sampling_parameter_to_string = Capability_vocab.sampling_parameter_to_string
