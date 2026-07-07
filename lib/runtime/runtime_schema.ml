(** Self-standing Runtime configuration types (RFC-0206, runtime→Runtime rebirth).

    Provider × Model × Binding declarative schema (RFC-0058 layers 1-3),
    re-homed from the deleted [Runtime_declarative_types] as types owned by
    [lib/runtime/]. The routing layers (RFC-0058 layer 4 aliases, layer 5
    routes/profiles, and the strategy ADT) are intentionally NOT ported: a
    Runtime is a single pre-selected (provider × model) binding, so there is
    no routing indirection to model. *)

(** {1 API format & transport} *)

type api_format =
  | Messages_api
  | Chat_completions_api
  | Ollama_api
[@@deriving show, eq]

type transport =
  | Http of string
  | Cli of string
[@@deriving show, eq]

type credential =
  | Env of string
  | File of string
  | Inline of string
[@@deriving show, eq]

(** {1 Layer 1: Provider — how to connect} *)

(** Per-provider behavioral capabilities (RFC-0058 §2.4). Describes how the
    transport/tool lane must be driven for a provider, independent of model. *)
type capabilities =
  { supports_inline_tools : bool
  ; requires_per_keeper_bridging_for_bound_actor_tools : bool
  ; identity_runtime_mcp_header_keys : string list
  ; argv_prompt_preflight : bool
  ; uses_anthropic_caching : bool
  ; max_turns_per_attempt : int option
  ; tolerates_bound_actor_fallback : bool
  }
[@@deriving show, eq]

(** [providers.<id>] — connection + behavior. The deleted
    [runtime_provider]'s [log] sub-record is still ignored. [healthcheck.path]
    is retained as provider-owned metadata for install/setup probes; runtime
    startup does not use it for admission. [headers] is retained for
    per-provider HTTP header injection. *)
let connect_timeout_s_key = "connect-timeout-s"

type provider =
  { id : string
  ; display_name : string
  ; protocol : string
  ; api_format : api_format
  ; transport : transport
  ; is_non_interactive : bool
  ; credentials : credential option
  ; capabilities : capabilities option
  ; healthcheck_path : string option
  ; headers : (string * string) list option
  ; connect_timeout_s : float option
    (** Per-provider override for the OAS connect + initial-response-headers
      wall-clock timeout (seconds). [None] keeps the OAS kind-based default
      (see [Llm_provider.Provider_config.default_connect_timeout_s]). Declared
      on the provider, not the model, because it is a transport property.
      oas#2163, RFC-OAS-026 I2: MASC declares the budget; OAS owns enforcement
      and phase=Http_operation attribution. *)
  }
[@@deriving show, eq]

(** {1 Layer 2: Model — what it can do} *)

(** How an OpenAI-compat backend's request body encodes "enable thinking".
    Pinned on the model because the same physical model can be served by
    backends with different thinking-control wire shapes.

    This re-exports the OAS capability enum so OAS variant changes break MASC
    compile instead of leaving a stale local mirror. *)
type thinking_control_format =
  Llm_provider.Capabilities.thinking_control_format =
  | No_thinking_control
  | Thinking_object
  | Thinking_object_adaptive
  | Thinking_object_only
  | Chat_template_kwargs
  | Chat_template_token of string
  | Ollama_think
  | Reasoning_effort
  | Enable_thinking
[@@deriving show, eq]

(** Per-model capabilities, mirroring OAS [Llm_provider.Capabilities] for the
    fields callers branch on. Fields already present on {!model_spec}
    ([tools_support]/[thinking_support]/[max_context]/[streaming]) are not
    duplicated here, to avoid two-SSOT drift. *)
type model_capabilities =
  { max_output_tokens : int option
  ; supports_tool_choice : bool
  ; supports_required_tool_choice : bool
  ; supports_named_tool_choice : bool
  ; supports_parallel_tool_calls : bool
  ; supports_extended_thinking : bool
  ; supports_reasoning_budget : bool
  ; thinking_control_format : thinking_control_format
  ; supports_image_input : bool
  ; supports_audio_input : bool
  ; supports_video_input : bool
  ; supports_multimodal_inputs : bool
  ; supports_response_format_json : bool
  ; supports_structured_output : bool
  ; supports_native_streaming : bool
  ; supports_system_prompt : bool
  ; supports_caching : bool
  ; supports_prompt_caching : bool
  ; prompt_cache_alignment : int option
  ; supports_top_k : bool
  ; supports_min_p : bool
  ; supports_seed : bool
  ; supports_seed_with_images : bool
  ; emits_usage_tokens : bool
  ; supports_computer_use : bool
  ; supports_code_execution : bool
  }
[@@deriving show, eq]

let model_capabilities_default =
  { max_output_tokens = None
  ; supports_tool_choice = false
  ; supports_required_tool_choice = false
  ; supports_named_tool_choice = false
  ; supports_parallel_tool_calls = false
  ; supports_extended_thinking = false
  ; supports_reasoning_budget = false
  ; thinking_control_format = No_thinking_control
  ; supports_image_input = false
  ; supports_audio_input = false
  ; supports_video_input = false
  ; supports_multimodal_inputs = false
  ; supports_response_format_json = false
  ; supports_structured_output = false
  ; supports_native_streaming = false
  ; supports_system_prompt = false
  ; supports_caching = false
  ; supports_prompt_caching = false
  ; prompt_cache_alignment = None
  ; supports_top_k = false
  ; supports_min_p = false
  ; supports_seed = false
  ; supports_seed_with_images = false
  ; (* stricter default: most providers report usage; CLI wrappers opt out *)
    emits_usage_tokens = true
  ; supports_computer_use = false
  ; supports_code_execution = false
  }
;;

(** [models.<id>] — capability declaration. [match_prefixes] empty = match only
    exact [api_name] equality; non-empty = match any requested model id starting
    with one of the prefixes (longest-prefix-first; resolver lives outside the
    schema and is added only if a binding needs fuzzy resolution — RFC-0206 R4). *)
type model_spec =
  { id : string
  ; api_name : string
  ; tools_support : bool
  ; max_context : int
  ; thinking_support : bool
  ; preserve_thinking : bool option
  ; max_thinking_budget : int option
  ; streaming : bool
  ; temperature : float option
    (** [temperature] — per-model sampling temperature for keeper turns. [None]
        keeps the caller fallback ([MASC_KEEPER_UNIFIED_TEMP], then the OAS
        [agent_default] profile). [Some t] overrides it for every turn on this
        model. Required for models that reject the default value: e.g. Kimi K2.7
        (kimi-for-coding) accepts only temperature = 1.0 and rejects any other
        value at request time ("only 1 is allowed for this model"). Resolved via
        {!Runtime.temperature_of_runtime_id} → {!Runtime_inference.resolve_temperature},
        symmetric to the [max-output-tokens]/[max_tokens] path. *)
  ; top_p : float option
    (** [top_p] — per-model nucleus sampling probability forwarded through the
        materialized OAS [Provider_config]. [None] leaves the caller/OAS profile
        unchanged. *)
  ; top_k : int option
    (** [top_k] — per-model top-k sampling cap forwarded through the materialized
        OAS [Provider_config]. [None] leaves the caller/OAS profile unchanged. *)
  ; min_p : float option
    (** [min_p] — per-model minimum probability sampling value forwarded through
        the materialized OAS [Provider_config]. [None] leaves the caller/OAS
        profile unchanged. *)
  ; capabilities : model_capabilities option
  ; match_prefixes : string list
  }
[@@deriving show, eq]

(** {1 Layer 3: Binding — provider × model} *)

type binding =
  { provider_id : string
  ; model_id : string
  ; is_default : bool
  ; wizard_default : bool
  ; max_concurrent : int option
  ; price_input : float option
  ; price_output : float option
  ; keep_alive : string option
  ; num_ctx : int option
  }
[@@deriving show, eq]

(** {1 Pause threshold knobs}

    Typed record mirroring the [\[pause\]] runtime.toml section.  All fields
    are [int] or [float] — primitive thresholds, not reason classifiers, so
    polymorphic variants / closed-sum types are not warranted here. *)
type pause_threshold =
  { turn_fail_streak_threshold : int
  ; recent_restart_window_sec : float
  ; recent_restart_count_threshold : int
  ; tool_failure_count_threshold : int
  ; tool_failure_ratio_threshold : float
  }
[@@deriving show, eq]

(** [Pause_threshold.default] mirrors the legacy hardcoded values in
    [Keeper_behavioral_regime.ml:46-50]. Field names must match — they are
    the runtime.toml SSOT keys. *)
let pause_threshold_default =
  { turn_fail_streak_threshold = 3
  ; recent_restart_window_sec = 300.0
  ; recent_restart_count_threshold = 2
  ; tool_failure_count_threshold = 3
  ; tool_failure_ratio_threshold = 0.7
  }
;;

(** {1 Lanes}

    Lanes are ordered failover candidate lists declared in [runtime.lanes.<id>].
    The declaration carries opaque runtime ids; resolution to materialized
    runtimes happens in [Runtime] so this module stays dependency-free. *)

type lane_strategy = Ordered
[@@deriving show, eq]

type lane_decl =
  { id : string
  ; strategy : lane_strategy
  ; candidate_ids : string list
  }
[@@deriving show, eq]

(** {1 Top-level config}

    Routes/aliases/profiles/system_targets/strategy from the deleted
    [runtime_config] are dropped (RFC-0206 §5): the single-binding Runtime model
    has no routing layer. *)
type config =
  { providers : provider list
  ; models : model_spec list
  ; bindings : binding list
  ; default_runtime_id : string option
  ; librarian_runtime_id : string option
    (** [\[runtime\].librarian] — runtime id ["provider.model"] for the memory-os
        librarian (post-turn episode extraction). The librarian now requests
        provider-native structured output at its call sites; this field is the
        routing SSOT and load-time validation only rejects unknown ids. [None] =
        the librarian inherits each keeper's runtime (legacy). An unknown id is
        rejected at load like [\[runtime\].default]. The
        [MASC_KEEPER_MEMORY_OS_LIBRARIAN_RUNTIME_ID] env var overrides this. *)
  ; structured_judge_runtime_id : string option
    (** [\[runtime\].structured_judge] — runtime id for provider-native
        structured-output judge calls such as dashboard operator/governance
        judges. When set, it must resolve to a model declaring
        [supports-structured-output]. [None] lets callers use their documented
        migration fallback, but no caller may silently discard a schema request. *)
  ; cross_verifier_runtime_id : string option
    (** [\[runtime\].cross_verifier] — runtime id for the anti-rationalization
        evaluator. It requests JSON mode and must run on a model declaring
        [supports-response-format-json]; [None] = inherit
        [\[runtime\].default]. Unknown id rejected at load. *)
  ; keeper_assignments : (string * string) list
    (** [\[runtime.assignments\]] — keeper name → runtime id ["provider.model"].
        runtime.toml is the sole SSOT for keeper→runtime assignment (persona⊥
        {model,runtime}: persona JSON and keeper TOML no longer carry a runtime
        selection). A keeper absent from this table routes to the default
        runtime; an assignment to an unknown id is rejected at load
        ({!Runtime.load_list}), mirroring [\[runtime\].default] validation. The
        id is an opaque binding key here — only the OAS adapter parses it into
        provider/model/spec. *)
  ; media_failover : string list
    (** [\[runtime\].media_failover] (RFC-0265) — ordered runtime ids consulted
        when a turn's input modality (image/audio/document) exceeds the assigned
        runtime's declared capabilities; the turn reroutes to the first that
        admits it. [[]] = derive capable runtimes from declared
        [\[models.*.capabilities\]] in declaration order. Each id must resolve to
        a configured runtime (rejected at load like [\[runtime\].default]). *)
  ; pause_threshold : pause_threshold
    (** [\[pause\]] — typed SSOT for keeper pause / regime threshold knobs
        previously hardcoded in [Keeper_behavioral_regime]. Mirrors the same
        field names + types (int / float) so callers can compare against the
        loaded record without an extra decoder. Missing from runtime.toml →
        [Pause_threshold.default]. Wrong-type value → load-time warn + fallback
        to default (fail-soft: wrong value is not catastrophic at boot).
        Operational callers read this through [Runtime.pause_threshold]. *)
  ; lane_decls : lane_decl list
    (** [\[runtime.lanes.<id>\]] — ordered failover candidate lists.
        Declarations are resolved against materialized runtimes at load time;
        an unknown candidate id is rejected like [\[runtime\].default]. *)
  }
[@@deriving show, eq]

(** {1 Lookups} *)

let provider_of_id (cfg : config) (id : string) : provider option =
  List.find_opt (fun (p : provider) -> String.equal p.id id) cfg.providers
;;

let model_of_id (cfg : config) (id : string) : model_spec option =
  List.find_opt (fun (m : model_spec) -> String.equal m.id id) cfg.models
;;

(** Runtime id derived from a binding: ["provider.model"]. Single source of id
    derivation, shared by {!Runtime.id_of_binding} and any caller indexing
    runtimes by id. *)
let binding_key (b : binding) : string =
  Printf.sprintf "%s.%s" b.provider_id b.model_id
;;
