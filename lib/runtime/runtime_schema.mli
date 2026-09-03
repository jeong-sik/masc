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
  | Codex_app_server_runtime
  | Antigravity_cli_runtime
  | Claude_code_runtime
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

type antigravity_effort =
  | Antigravity_low
  | Antigravity_medium
  | Antigravity_high
[@@deriving show, eq]

type antigravity_cli_options =
  { agent : string option
  ; effort : antigravity_effort option
  ; timeout_s : float
  ; add_dirs : string list
        (** [add-dirs] — extra absolute directories the CLI may read beside
            the keeper base path, each passed as its own [--add-dir]. Empty
            means the base path stays the only workspace root. *)
  }
[@@deriving show, eq]

type provider =
  { id : string
  ; enabled : bool
    (** Whether bindings owned by this provider may be materialized. Omitted
        [enabled] in TOML defaults to [true]. *)
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
    (** Per-provider override for the AGENT_CORE connect + initial-response-headers
      wall-clock timeout (seconds). [None] keeps the AGENT_CORE kind-based default
      (see [Llm_provider.Provider_config.default_connect_timeout_s]). Declared
      on the provider, not the model, because it is a transport property.
      agent-core boundary, Agent Core contract I2: MASC declares the budget; AGENT_CORE owns enforcement
      and phase=Http_operation attribution. *)
  ; antigravity_cli : antigravity_cli_options option
    (** Present exactly when [protocol = "antigravity-cli"]. *)
  }
[@@deriving show, eq]

(** {1 Layer 2: Model} *)

(** Re-exported from AGENT_CORE so thinking-control capability drift is
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
[@@deriving show, eq]

type reasoning_streaming_format =
  Llm_provider.Capabilities.reasoning_streaming_format =
  | Default_reasoning_streaming
  | No_reasoning_streaming
  | Delta_reasoning_field of string
  | Template_reasoning_streaming
[@@deriving show, eq]

type model_capabilities =
  { max_output_tokens : int option
  ; supports_tool_choice : bool
  ; supports_required_tool_choice : bool
  ; supports_named_tool_choice : bool
  ; supports_parallel_tool_calls : bool
  ; supports_extended_thinking : bool
  ; supports_reasoning_budget : bool
  ; declared_supports_reasoning_budget : bool option
      (** Exact TOML presence. [None] preserves an Agent Core catalog value. *)
  ; thinking_control_format : thinking_control_format
  ; declared_thinking_control_format : thinking_control_format option
      (** Exact TOML presence. [None] preserves an Agent Core catalog value. *)
  ; reasoning_streaming_format : reasoning_streaming_format option
      (** Exact streaming side-channel for this transport binding. *)
  ; supports_image_input : bool
  ; supports_audio_input : bool
  ; supports_video_input : bool
  ; supports_multimodal_inputs : bool
  ; supports_response_format_json : bool
  ; supports_structured_output : bool
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
      (** [models.<id>.max-context] operator override. [None] means the AGENT_CORE
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
  ; reasoning_effort : Llm_provider.Reasoning_effort.t option
       [@equal fun a b -> a = b]
  ; turn_timeout_s : float option
  ; wall_clock_ceiling_s : float option
        (** [wall-clock-ceiling-s] — per-model ceiling on one official-client
            turn's total duration, in seconds; unlike [turn-timeout-s] it never
            resets, and it can only tighten the runtime default, never remove
            it. *)
  ; max_prompt_bytes : int option
  ; capabilities : model_capabilities option
  }
[@@deriving show, eq]

(** {1 Layer 3: Binding} *)

type binding =
  { provider_id : string
  ; model_id : string
  ; enabled : bool
    (** Whether this provider x model binding may be materialized. Omitted
        [enabled] in TOML defaults to [true]. *)
  ; is_default : bool
  ; wizard_default : bool
  ; max_concurrent : int option
  ; max_request_body_bytes : int option
        (** Serialized request-body ceiling for this binding, in bytes.

            AGENT_CORE validates this knob and [max_concurrent] together in one function
            ([Llm_provider] admission declaration) and enforces this one before
            POST: it serializes the body, measures it, and returns a typed
            [Request_body_too_large] when the declared ceiling is exceeded. That
            rejection is pre-dispatch, so it is failover-eligible.

            Undeclared means the gate passes every size, and the ceiling is then
            discovered only as a gateway 400 after the bytes are already on the
            wire — post-dispatch, where neither retry nor failover applies. *)
  ; max_tokens : int option
        (** Request-side output budget for this binding ([max_tokens] on Chat
            Completions, [max_output_tokens] on Responses, [num_predict] on
            Ollama).

            Absent keeps the field off the wire so the provider's own default
            decides. masc#24067 removed a resolver that {i invented} this value
            from a capability ceiling or a flat fallback; a value declared here
            is explicit deployment intent, which is what that boundary asks
            callers to carry.

            Measured 2026-08-25 over 1516 turns on
            [ollama_cloud.deepseek-v4-flash:0731]: [output_tokens] was <= 2048
            on 1392 turns and 2048..8192 on 38, then exactly 65536 on 86 -- the
            provider's own cap, reached only by turns that had collapsed into
            single-token repetition. The 8192..65535 band held nothing at all,
            so a budget inside it bounds the collapse without touching healthy
            work. *)
  ; price_input : float option
  ; price_output : float option
  ; keep_alive : string option
  ; num_ctx : int option
  ; repeat_penalty : float option
  ; repeat_last_n : int option
  ; return_progress : bool option
  }
[@@deriving show, eq]

(** {1 Lanes}

    Ordered failover candidate lists declared in [runtime.lanes.<id>].
    Declarations carry opaque runtime ids; [Runtime] resolves them to
    materialized runtimes at load time. *)

type lane_decl =
  { id : string
  ; candidate_ids : string list
  }
[@@deriving show, eq]

type exact_output_lane_decl =
  { id : string
  ; slot_ids : string list
  ; cli_slot_ids : string list
        (** [cli_slots] — official-client runtime ids walked as one-shot
            fallbacks AFTER every catalog slot is exhausted
            (RFC cli-runtimes-as-lane-slots). Empty keeps the lane
            HTTP-only. *)
  }
[@@deriving show, eq]

(** {1 Top-level config} *)

type config =
  { providers : provider list
  ; models : model_spec list
  ; bindings : binding list
  ; default_runtime_id : string option
  ; keeper_assignments : (string * string) list
    (** [\[runtime.assignments\]] — keeper name → runtime id ["provider.model"].
        Sole SSOT for keeper-to-runtime assignment. A
        keeper absent from this table routes to the default runtime; an
        assignment to an unknown id is rejected at load. The id is an opaque
        binding key (only the AGENT_CORE adapter parses it into provider/model/spec). *)
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
  ; exact_output_lane_decls : exact_output_lane_decl list
    (** Raw ordered AGENT_CORE target references from
        [\[runtime.exact_output_lanes.<id>\]]. *)
  ; exec_ssh_endpoints : Exec_ssh_endpoint.t list
    (** [\[exec.ssh.endpoints.<name>\]] — SSH remote execution endpoint
        registry (Phase 1 SSH lane, spec §4.2). Keeper TOML [remote_endpoint]
        names resolve against this list at keeper load/dispatch; an unknown
        name is a config-load error. *)
  }
[@@deriving show, eq]

(** {1 Lookups} *)

val provider_of_id : config -> string -> provider option
val model_of_id : config -> string -> model_spec option

(** Registry lookup by [\[exec.ssh.endpoints.<name>\]] key. *)
val exec_ssh_endpoint : config -> string -> Exec_ssh_endpoint.t option

(** Runtime id derived from a binding: ["provider.model"]. *)
val binding_key : binding -> string
