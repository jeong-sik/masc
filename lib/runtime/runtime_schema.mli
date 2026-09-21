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
  | Gemini_api
  | Vertex_gemini_api
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

(** Which vendor dialect an endpoint speaks. [protocol] names the request
    shape; this names the dialect inside it, and the two do not determine each
    other — [openai-compatible-http] is spoken both by plain OpenAI-compatible
    servers and by GLM, [messages-http] both by Anthropic and by Kimi.

    A provider the AGENT_CORE catalog knows states its dialect there, and
    restating it here is refused at load. The key exists for an endpoint the
    catalog has never seen: the install wizard builds its provider id from a
    hash of the operator's answers, so no catalog row can ever match it. *)
type provider_wire_kind =
  Llm_provider.Provider_config.provider_kind =
  | Anthropic
  | Kimi
  | OpenAI_compat
  | Ollama
  | Gemini
  | Glm
[@@deriving show, eq]

(** {1 Layer 1: Provider} *)

type capabilities =
  { supports_inline_tools : bool
  ; argv_prompt_preflight : bool
  ; uses_anthropic_caching : bool
  }
[@@deriving show, eq]

val connect_timeout_s_key : string
val exact_body_timeout_s_key : string

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
  ; wire_kind : provider_wire_kind option
    (** The dialect this endpoint speaks, for an endpoint the AGENT_CORE
        catalog does not know. [None] means the catalog answers, and a
        provider that has a catalog row is refused if it states this. *)
  ; transport : transport
  ; is_non_interactive : bool
  ; credentials : credential option
  ; capabilities : capabilities option
  ; healthcheck_path : string option
  ; headers : (string * string) list option
  ; connect_timeout_s : float option
    (** Per-provider bound on the phase before the response headers -- the
      connection (DNS, TCP, TLS), the request and the wait for the status
      line -- in seconds. [None] leaves that phase to the keeper's
      first-event budget, which AGENT_CORE applies in front of the headers as
      well as on the stream; a declared value narrows it. Declared on the
      provider, not the model, because it is a transport property.
      agent-core boundary, Agent Core contract I2: MASC declares the budget;
      AGENT_CORE owns enforcement and phase=Http_operation attribution. *)
  ; exact_body_timeout_s : float option
    (** Explicit total HTTP request deadline for Exact-output calls through
        this provider, including connection, response headers and the full
        response body. [None] declares no body deadline. This does not replace
        [connect_timeout_s] or ordinary Keeper per-call body deadlines. *)
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
  | Delta_reasoning_field_and_details of string
  | Template_reasoning_streaming
[@@deriving show, eq]

type model_capabilities =
  { max_output_tokens : int option
  ; supports_tool_choice : bool option
  ; supports_required_tool_choice : bool option
  ; supports_named_tool_choice : bool option
  ; supports_parallel_tool_calls : bool option
  ; thinking_control_format : thinking_control_format
  ; declared_thinking_control_format : thinking_control_format option
      (** Exact TOML presence. [None] preserves an Agent Core catalog value. *)
  ; reasoning_streaming_format : reasoning_streaming_format option
      (** Exact streaming side-channel for this transport binding. *)
  ; supports_image_input : bool option
  ; supports_audio_input : bool option
  ; supports_video_input : bool option
  ; supports_multimodal_inputs : bool option
  ; supports_response_format_json : bool option
  ; supports_structured_output : bool option
  ; supports_system_prompt : bool option
  ; supports_prompt_caching : bool option
  ; supports_top_k : bool option
  ; supports_min_p : bool option
  ; supports_seed : bool option
  ; emits_usage_tokens : bool option
  }
[@@deriving show, eq]

(** Every field [None]: nothing was stated. Used when
    [\[models.<id>.capabilities\]] is absent.

    [None] is not [Some false]. A consumer resolves it to the value its own
    layer holds — the provider wire's preset for the capability fields, and
    [false] for the media fields, which MASC keeps fail-closed
    ([Runtime_agent.apply_runtime_model_input_capabilities]). Before #37435
    these were plain [bool] parsed with a [false] default, so an unwritten key
    was indistinguishable from a written [false]: on a catalogued model the
    whole block had to be dropped to avoid zeroing the catalog, and on an
    uncatalogued one it zeroed the wire preset instead. *)
val model_capabilities_default : model_capabilities

type model_spec =
  { id : string
  ; api_name : string
  ; tools_support : bool
  ; max_context : int option
      (** [models.<id>.max-context] operator override. [None] means the AGENT_CORE
          capability catalog's max-context is the sole source; resolved via
          {!Runtime.resolve_max_context_of_runtime}, never read directly. *)
  ; thinking_support : bool option
        (** Absent inherits provider defaults; Some false explicitly disables thinking. *)
  ; preserve_thinking : bool option
  ; streaming : bool
  ; temperature : float option
  ; top_p : float option
  ; top_k : int option
  ; min_p : float option
  ; reasoning_uncontrolled : bool
        (** [reasoning-uncontrolled] — this lane deliberately sends no thinking
            control and takes the provider's own default. A wire that enables
            reasoning without a control refuses a reasoning-capable row that
            declares neither this nor an effort: the two requests are identical
            and only this says the silence was meant. Default [false]. *)
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

(** Where the keeper starts evicting carried history and where it stops, in
    the provider's tokens of the whole request: prefix, carried atoms and
    tail together, as the provider's [input_tokens] reports it (RFC
    keeper-context-window-in-tokens §10.2, §10.5). Parsed as a pair so the
    invariant [0 < low_water_tokens < high_water_tokens] holds by
    construction; [high_water_tokens <= max-context] is checked once the model
    is resolved ({!Runtime.validate_runtime_context_marks}). *)
type context_marks =
  { high_water_tokens : int  (** Eviction starts when the last measured total passes this. *)
  ; low_water_tokens : int  (** Eviction stops once the projected total is at or below this. *)
  }
[@@deriving show, eq]

type binding =
  { provider_id : string
  ; model_id : string
  ; enabled : bool
    (** Whether this provider x model binding may be materialized. Omitted
        [enabled] in TOML defaults to [true]. *)
  ; is_default : bool
  ; wizard_default : bool
  ; max_concurrent : int option
  ; disable_parallel_tool_use : bool
        (** Request policy for this binding. [true] asks the provider for at
            most one tool call per response; [false] (the default) leaves
            parallel calls permitted by the model's catalog capability.
            This does not change that capability or serialize spawned agents.
            Official-client, native Ollama and Gemini runtimes cannot carry
            this policy and refuse [true]. *)
  ; context_marks : context_marks option
        (** [context-high-water-tokens] and [context-low-water-tokens] on the
            binding table, declared together or not at all. Absent means the
            keeper evicts carried history only when the provider refuses a
            request; with the marks it evicts before that, from the oldest
            measured block, down to the low-water mark. Tokens are this
            model's, which is why the marks live on the binding. *)
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

(** [\[typesafeai\]] -- the TypeSafe AI (System One Jev) lane. The key stays in
    the environment ([TYPESAFEAI_API_KEY]); everything else about the lane is
    here. [lane_enabled] turns the lane off; it cannot turn it on without a
    key. Two gates ask the vendor: [board_attention] (the Board attention
    judgment, {!Keeper_board_attention_exact_flow}, which sends the post and
    the keeper's context) and [absorb_gate] (the librarian absorb gate,
    {!Keeper_librarian_absorb_gate}, which sends memory sentences). Skill applicability review is opt-in too.
    All reach the same endpoint, so one [excluded_keepers] applies to every review: a keeper
    named there is never asked about, whichever gate asks. *)
type typesafeai =
  { lane_enabled : bool
  ; lane_endpoint : string
  ; lane_model : string
  ; board_attention : bool
  ; absorb_gate : bool
  ; skill_applicability : bool
  ; excluded_keepers : string list
  }
[@@deriving show, eq]

val default_typesafeai : typesafeai
(** What an absent [\[typesafeai\]] table means: the lane on when a key is
    set, the vendor's endpoint and latest model, Board attention on, the absorb
    gate off. *)

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
    (** [\[runtime\].media_failover] — the vision read fleet: ordered runtime ids
        the vision tool calls, including the image readings made for a runtime
        that cannot take the image. A keeper turn never dispatches to them; its
        image reroute stays inside its lane. [[]] = no vision fleet. Each id must
        resolve to a configured runtime (rejected at load like
        [\[runtime\].default]). *)
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
  ; lsp_servers : (string * (string * string list)) list
    (** [\[lsp.servers\]] — the command that starts a language's server, by
        the language's wire id: [python = \["pyright-langserver", "--stdio"\]].
        Replaces {!Lsp_process_manager.command_of_language} for that language
        and no other. A key naming no language, or a value that is not a
        non-empty array of strings, is refused at load. *)
  ; typesafeai : typesafeai
    (** [\[typesafeai\]] -- see {!typesafeai}. Absent is {!default_typesafeai}. *)
  ; egress_allowlists : Egress_allowlist.t list
    (** [\[egress.keepers.<name>\]] — what a keeper in the policy lane may
        reach (RFC-0415). A keeper with no entry has an empty allowlist,
        which admits nothing. *)
  }
[@@deriving show, eq]

(** {1 Lookups} *)

val provider_of_id : config -> string -> provider option
val model_of_id : config -> string -> model_spec option

(** Registry lookup by [\[exec.ssh.endpoints.<name>\]] key. *)
val exec_ssh_endpoint : config -> string -> Exec_ssh_endpoint.t option

(** Runtime id derived from a binding: ["provider.model"]. *)
val binding_key : binding -> string
