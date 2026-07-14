(** Self-standing Runtime configuration types (RFC-0206, runtime→Runtime rebirth).

    Provider × Model × Binding declarative schema (RFC-0058 layers 1-3),
    re-homed from the deleted [Runtime_declarative_types] as types owned by
    [lib/runtime/]. Routing layers (aliases/routes/profiles/strategy) are
    intentionally dropped: a Runtime is a single pre-selected binding. *)

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

(** {1 Layer 1: Provider} *)

type capabilities =
  { supports_inline_tools : bool
  ; argv_prompt_preflight : bool
  ; uses_anthropic_caching : bool
  }
[@@deriving show, eq]

val connect_timeout_s_key : string

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

(** {1 Layer 2: Model} *)

(** Re-exported from OAS so thinking-control capability drift is
    compiler-checked. *)
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

(** All-false / [None] defaults, except [emits_usage_tokens = true] (most
    providers report usage; CLI wrappers opt out). Used when
    [\[models.<id>.capabilities\]] is absent. *)
val model_capabilities_default : model_capabilities

type model_spec =
  { id : string
  ; api_name : string
  ; tools_support : bool
  ; max_context : int option
      (** [models.<id>.max-context] operator override. [None] means the OAS
          capability catalog's max-context is the sole source; resolved via
          {!Runtime.resolve_max_context_of_runtime}, never read directly. *)
  ; thinking_support : bool
  ; preserve_thinking : bool option
  ; max_thinking_budget : int option
  ; streaming : bool
  ; temperature : float option
  ; top_p : float option
  ; top_k : int option
  ; min_p : float option
  ; capabilities : model_capabilities option
  ; match_prefixes : string list
  }
[@@deriving show, eq]

(** {1 Layer 3: Binding} *)

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

(** {1 Lanes}

    Ordered failover candidate lists declared in [runtime.lanes.<id>].
    Declarations carry opaque runtime ids; [Runtime] resolves them to
    materialized runtimes at load time. *)

type lane_strategy = Ordered
[@@deriving show, eq]

type lane_decl =
  { id : string
  ; strategy : lane_strategy
  ; candidate_ids : string list
  }
[@@deriving show, eq]

(** {1 Top-level config} *)

type config =
  { providers : provider list
  ; models : model_spec list
  ; bindings : binding list
  ; default_runtime_id : string option
  ; librarian_runtime_id : string option
    (** [\[runtime\].librarian] — runtime id for the memory-os librarian
        (post-turn episode extraction). The librarian now requests
        provider-native structured output at its call sites; this field is the
        routing SSOT and load-time validation only rejects unknown ids. [None] =
        inherit each keeper's runtime. Unknown id rejected at load like
        [\[runtime\].default]; [MASC_KEEPER_MEMORY_OS_LIBRARIAN_RUNTIME_ID]
        overrides. *)
  ; structured_judge_runtime_id : string option
    (** [\[runtime\].structured_judge] — runtime id for provider-native
        structured-output judge calls. When set, the model must declare
        [supports-structured-output]. [None] lets callers use their documented
        migration fallback; schema requests still fail loudly if the resolved
        runtime cannot satisfy them. *)
  ; hitl_summary_runtime_id : string option
    (** [\[runtime\].hitl_summary] — runtime id for HITL approval context
        summaries. When set, it must resolve to a configured runtime. The HITL
        worker decides native structured vs plain JSON mode at call time, so
        load-time validation only rejects unknown ids. [None] keeps the legacy
        structured-judge routing fallback. *)
  ; cross_verifier_runtime_id : string option
    (** [\[runtime\].cross_verifier] — runtime id for the anti-rationalization
        evaluator (cross-model task verification). The evaluator requests JSON
        mode (a structured verdict tool call), so it must run on a model
        declaring [supports-response-format-json]; otherwise it returns empty
        output and the gate approves by liveness. [None] = inherit
        [\[runtime\].default]. Unknown id rejected at load like
        [\[runtime\].default]. *)
  ; keeper_assignments : (string * string) list
    (** [\[runtime.assignments\]] — keeper name → runtime id ["provider.model"].
        Sole SSOT for keeper→runtime assignment (persona⊥{model,runtime}). A
        keeper absent from this table routes to the default runtime; an
        assignment to an unknown id is rejected at load. The id is an opaque
        binding key (only the OAS adapter parses it into provider/model/spec). *)
  ; media_failover : string list
    (** [\[runtime\].media_failover] (RFC-0265) — ordered runtime ids consulted
        when a turn's input modality (image/audio/document) exceeds the assigned
        runtime's declared capabilities; the turn reroutes to the first that
        admits it. [[]] = derive capable runtimes from declared
        [\[models.*.capabilities\]] in declaration order. Each id must resolve to
        a configured runtime (rejected at load like [\[runtime\].default]). *)
  ; lane_decls : lane_decl list
    (** [\[runtime.lanes.<id>\]] — ordered failover candidate lists.
        Declarations are resolved against materialized runtimes at load time;
        an unknown candidate id is rejected like [\[runtime\].default]. *)
  }
[@@deriving show, eq]

(** {1 Lookups} *)

val provider_of_id : config -> string -> provider option
val model_of_id : config -> string -> model_spec option

(** Runtime id derived from a binding: ["provider.model"]. *)
val binding_key : binding -> string
