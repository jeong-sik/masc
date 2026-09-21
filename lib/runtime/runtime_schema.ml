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
  | Gemini_api
  | Vertex_gemini_api
  | Codex_app_server_runtime
  | Antigravity_cli_runtime
  | Claude_code_runtime
[@@deriving show, eq]

(** Which vendor dialect an endpoint speaks. [protocol] names the request
    shape; this names the dialect inside it, and the two do not determine each
    other — [openai-compatible-http] is spoken both by plain OpenAI-compatible
    servers and by GLM, [messages-http] both by Anthropic and by Kimi.

    A provider the AGENT_CORE catalog knows states its dialect there, and
    restating it here is refused at load. The key exists for an endpoint the
    catalog has never seen: the install wizard builds its provider id from a
    hash of the operator's answers, so no catalog row can ever match it.

    Re-exports the AGENT_CORE type so a variant added there breaks this
    compile instead of leaving a stale local mirror. *)
type provider_wire_kind =
  Llm_provider.Provider_config.provider_kind =
  | Anthropic
  | Kimi
  | OpenAI_compat
  | Ollama
  | Gemini
  | Glm
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
  ; argv_prompt_preflight : bool
  ; uses_anthropic_caching : bool
  }
[@@deriving show, eq]

(** [providers.<id>] — connection + behavior. The deleted
    [runtime_provider]'s [log] sub-record is still ignored. [healthcheck.path]
    is retained as provider-owned metadata for install/setup probes; runtime
    startup does not use it for admission. [headers] is retained for
    per-provider HTTP header injection. *)
let connect_timeout_s_key = "connect-timeout-s"
let exact_body_timeout_s_key = "exact-body-timeout-s"

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
      AGENT_CORE owns enforcement and phase=Http_operation attribution.
      On an exact-output lane a target with neither this key nor a body
      budget is rejected at plan admission (Missing_deadline, #36979): the
      wire would otherwise carry no deadline at all. *)
  ; exact_body_timeout_s : float option
    (** Explicit total HTTP request deadline for Exact-output calls through
        this provider, including connection, response headers and the full
        response body. [None] declares no body deadline. This does not replace
        [connect_timeout_s] or ordinary Keeper per-call body deadlines. *)
  ; antigravity_cli : antigravity_cli_options option
    (** Typed [antigravity-cli] process options. Present exactly for providers
        using that protocol; absent for every other transport. *)
  }
[@@deriving show, eq]

(** {1 Layer 2: Model — what it can do} *)

(** How an OpenAI-compat backend's request body encodes "enable thinking".
    Pinned on the model because the same physical model can be served by
    backends with different thinking-control wire shapes.

    This re-exports the AGENT_CORE capability enum so AGENT_CORE variant changes break MASC
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
[@@deriving show, eq]

type reasoning_streaming_format =
  Llm_provider.Capabilities.reasoning_streaming_format =
  | Default_reasoning_streaming
  | No_reasoning_streaming
  | Delta_reasoning_field of string
  | Delta_reasoning_field_and_details of string
  | Template_reasoning_streaming
[@@deriving show, eq]

(** Per-model capabilities, mirroring AGENT_CORE [Llm_provider.Capabilities] for the
    fields callers branch on. Fields already present on {!model_spec}
    ([tools_support]/[thinking_support]/[max_context]/[streaming]) are not
    duplicated here, to avoid two-SSOT drift. *)
type model_capabilities =
  { max_output_tokens : int option
  ; supports_tool_choice : bool option
  ; supports_required_tool_choice : bool option
  ; supports_named_tool_choice : bool option
  ; supports_parallel_tool_calls : bool option
  ; thinking_control_format : thinking_control_format
  ; declared_thinking_control_format : thinking_control_format option
  ; reasoning_streaming_format : reasoning_streaming_format option
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

let model_capabilities_default =
  { max_output_tokens = None
  ; supports_tool_choice = None
  ; supports_required_tool_choice = None
  ; supports_named_tool_choice = None
  ; supports_parallel_tool_calls = None
  ; thinking_control_format = No_thinking_control
  ; declared_thinking_control_format = None
  ; reasoning_streaming_format = None
  ; supports_image_input = None
  ; supports_audio_input = None
  ; supports_video_input = None
  ; supports_multimodal_inputs = None
  ; supports_response_format_json = None
  ; supports_structured_output = None
  ; supports_system_prompt = None
  ; supports_prompt_caching = None
  ; supports_top_k = None
  ; supports_min_p = None
  ; supports_seed = None
  ; emits_usage_tokens = None
  }
;;

(** [models.<id>] — capability declaration. A requested model id resolves by
    exact [api_name] equality. RFC-0206 R4 forbids porting the longest-prefix
    matcher until a binding actually requires fuzzy resolution. *)
type model_spec =
  { id : string
  ; api_name : string
  ; tools_support : bool
  ; max_context : int option
      (** [models.<id>.max-context] operator override. [None] means the AGENT_CORE
          capability catalog's max-context is the sole source; resolved via
          {!Runtime.resolve_max_context_of_runtime}, never read directly. *)
  ; thinking_support : bool option
  ; preserve_thinking : bool option
  ; streaming : bool
  ; temperature : float option
    (** [temperature] — per-model sampling temperature for keeper turns. [None]
        keeps the caller fallback ([MASC_KEEPER_UNIFIED_TEMP], then the AGENT_CORE
        [agent_default] profile). [Some t] overrides it for every turn on this
        model. Required for models that reject the default value: e.g. Kimi K2.7
        (kimi-for-coding) accepts only temperature = 1.0 and rejects any other
        value at request time ("only 1 is allowed for this model"). Resolved via
        {!Runtime.temperature_of_runtime_id} → {!Runtime_inference.resolve_temperature},
        symmetric to the [max-output-tokens]/[max_tokens] path. *)
  ; top_p : float option
    (** [top_p] — per-model nucleus sampling probability forwarded through the
        materialized AGENT_CORE [Provider_config]. [None] leaves the caller/AGENT_CORE profile
        unchanged. *)
  ; top_k : int option
    (** [top_k] — per-model top-k sampling cap forwarded through the materialized
        AGENT_CORE [Provider_config]. [None] leaves the caller/AGENT_CORE profile unchanged. *)
  ; min_p : float option
    (** [min_p] — per-model minimum probability sampling value forwarded through
        the materialized AGENT_CORE [Provider_config]. [None] leaves the caller/AGENT_CORE
        profile unchanged. *)
  ; reasoning_uncontrolled : bool
    (** [reasoning-uncontrolled] — this lane sends no thinking control at all
        and takes whatever the provider does on its own. Only a wire that
        enables reasoning without a control needs it said: there, a row that
        declares neither an effort nor this is refused, because silence and a
        deliberate provider default make the same request and nothing else
        tells them apart. Default [false]. *)
  ; reasoning_effort : Llm_provider.Reasoning_effort.t option
       [@equal fun a b -> a = b]
    (* Reasoning_effort.t is a plain variant with no derived [equal];
       structural equality is exactly right for it, and declaring it here
       keeps the comparison inside masc rather than widening the AGENT_CORE
       module's interface for one consumer. *)
    (** [reasoning-effort] — per-model reasoning depth. Official-client
        runtimes take no [enable_thinking]
        ({!Keeper_official_client_host.resolve_reasoning_effort} rejects it
        outright), so this is the only declared control over how much a
        Claude Code / Codex / Antigravity turn reasons. [None] leaves the
        turn at the caller default. Resolved via
        {!Runtime.reasoning_effort_of_runtime_id} →
        {!Runtime_inference.resolve_reasoning_effort}, symmetric to the
        [temperature] path. *)
  ; turn_timeout_s : float option
    (** [turn-timeout-s] — per-model liveness window for one official-client
        turn, in seconds. Codex, Claude, and Antigravity reset it on every
        protocol message, so progressing turns have no wall-clock limit.
        Antigravity also leaves it unarmed while the CLI's last reported step
        is a running tool step, and Codex while the model is waiting on an item
        it started (a command, a file change, an MCP call, a sleep), because
        the CLI may write nothing until that step or item ends;
        [wall-clock-ceiling-s] below is the only bound there.
        [None] keeps the provider value where one exists and the adapter default
        otherwise.
        Resolved via {!Runtime.turn_timeout_s_of_runtime_id} →
        {!Runtime_inference.resolve_turn_timeout_s}. *)
  ; wall_clock_ceiling_s : float option
    (** [wall-clock-ceiling-s] — per-model ceiling on one official-client
        turn's total duration, in seconds. Unlike [turn-timeout-s] it does not
        reset on protocol messages: a turn that keeps emitting still ends when
        the ceiling expires ({!Runtime_wall_clock}). [None] keeps the runtime
        default ceiling; there is deliberately no "0 removes the bound" form —
        the ceiling is the fail-safe against unbounded turns, so the config
        may only tighten it, never delete it.
        Resolved via {!Runtime.wall_clock_ceiling_s_of_runtime_id} →
        {!Runtime_inference.resolve_wall_clock_ceiling_s}. *)
  ; max_prompt_bytes : int option
    (** [max-prompt-bytes] — per-model ceiling on the history an official-client
        start turn seeds its conversation with, in bytes.

        An official-client turn 1 sends the whole projected history; from turn 2
        the client owns the transcript and MASC sends only the goal. So a keeper
        whose history outgrows the model's window cannot fail once — it fails on
        turn 1, never reaches turn 2, and re-sends a larger history next cycle.
        Recovery does not break the loop: a fresh session resets the counter,
        which makes the next turn a start turn again.

        Declared in bytes rather than derived from [max-context] because MASC
        has no tokenizer: converting a token budget would need a
        bytes-per-token constant with nothing to justify it, and a wrong
        constant either truncates silently or overflows silently.

        [None] applies no ceiling, which is the behaviour every deployment has
        today. Resolved via {!Runtime.max_prompt_bytes_of_runtime_id} →
        {!Runtime_inference.resolve_max_prompt_bytes}. *)
  ; capabilities : model_capabilities option
  }
[@@deriving show, eq]

(** {1 Layer 3: Binding — provider × model} *)

(** Where the keeper starts evicting carried history and where it stops, in
    the provider's tokens of the whole request (RFC
    keeper-context-window-in-tokens §10.2, §10.5). *)
type context_marks =
  { high_water_tokens : int
  ; low_water_tokens : int
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
  ; context_marks : context_marks option
  ; max_tokens : int option
    (** Request-side output budget for this binding ([max_tokens] on Chat
        Completions, [max_output_tokens] on Responses, [num_predict] on Ollama).
        Absent keeps the field off the wire so the provider's own default
        decides. masc#24067 removed a resolver that {i invented} this value from
        a capability ceiling or a flat fallback; a value declared here is
        explicit deployment intent, which is what that boundary asks callers to
        carry.

        Measured 2026-08-25 over 1516 turns on
        [ollama_cloud.deepseek-v4-flash:0731]: [output_tokens] was <= 2048 on
        1392 turns and 2048..8192 on 38, then exactly 65536 on 86 -- the
        provider's own cap, reached only by turns that had collapsed into
        single-token repetition. The 8192..65535 band held nothing at all, so a
        budget inside it bounds the collapse without touching healthy work. *)
  ; price_input : float option
  ; price_output : float option
  ; keep_alive : string option
  ; num_ctx : int option
  ; repeat_penalty : float option
    (** Ollama [options.repeat_penalty]. Raises the cost of tokens already in
        the window, which is the documented remedy for R1-style reasoning
        models that restate the same thought until the turn dies. Declared per
        binding because it is an Ollama-only option, like [num_ctx]. *)
  ; repeat_last_n : int option
    (** Ollama [options.repeat_last_n]: how many recent tokens
        [repeat_penalty] looks back over. *)
  ; return_progress : bool option
  }
[@@deriving show, eq]

(** {1 Lanes}

    Lanes are ordered failover candidate lists declared in [runtime.lanes.<id>].
    The declaration carries opaque runtime ids; resolution to materialized
    runtimes happens in [Runtime] so this module stays dependency-free. *)

type lane_decl =
  { id : string
  ; candidate_ids : string list
  }
[@@deriving show, eq]

type exact_output_lane_decl =
  { id : string
  ; slot_ids : string list
  ; cli_slot_ids : string list
  }
[@@deriving show, eq]

(** {1 Top-level config}

    Routes/aliases/profiles/system_targets/strategy from the deleted
    [runtime_config] are dropped (RFC-0206 §5): the single-binding Runtime model
    has no routing layer. *)
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

(* What an absent [typesafeai] table means: the lane on when a key is set,
   the vendor's own endpoint and latest model, Board attention on, the absorb
   gate off (it sends memories out, so the operator turns it on by name),
   nobody excluded. *)
let default_typesafeai =
  { lane_enabled = true
  ; lane_endpoint = "https://api.typesafe.ai/v1/systemone"
  ; lane_model = "jev-latest"
  ; board_attention = true
  ; absorb_gate = false
  ; skill_applicability = false
  ; excluded_keepers = []
  }
;;

type config =
  { providers : provider list
  ; models : model_spec list
  ; bindings : binding list
  ; default_runtime_id : string option
  ; keeper_assignments : (string * string) list
    (** [\[runtime.assignments\]] — keeper name → a declared [\[runtime.lanes\]]
        name or a runtime id ["provider.model"]. A lane name is resolved first,
        so a lane whose name is also a runtime id still wins.
        runtime.toml is the sole SSOT for keeper-to-runtime assignment; keeper
        TOML does not carry a runtime selector. A keeper absent from this table routes to the default
        runtime; an assignment naming neither a lane nor a runtime is rejected at
        load ({!Runtime.load_list}), mirroring [\[runtime\].default] validation. The
        id is an opaque binding key here — only the AGENT_CORE adapter parses it into
        provider/model/spec. *)
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
        [\[runtime.exact_output_lanes.<id>\]]. MASC does not interpret them as
        provider/model runtime bindings. *)
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
        reach (RFC-0415). Beside the endpoint registry rather than in the
        keeper TOML for the same reason: a keeper names a mode, and what
        that mode permits is the operator's to say. A keeper with no entry
        has an empty allowlist, which admits nothing. *)
  }
[@@deriving show, eq]

(** {1 Lookups} *)

let provider_of_id (cfg : config) (id : string) : provider option =
  List.find_opt (fun (p : provider) -> String.equal p.id id) cfg.providers
;;

let model_of_id (cfg : config) (id : string) : model_spec option =
  List.find_opt (fun (m : model_spec) -> String.equal m.id id) cfg.models
;;

let exec_ssh_endpoint (cfg : config) (name : string) : Exec_ssh_endpoint.t option =
  List.find_opt
    (fun (endpoint : Exec_ssh_endpoint.t) -> String.equal endpoint.name name)
    cfg.exec_ssh_endpoints
;;

(** Runtime id derived from a binding: ["provider.model"]. Single source of id
    derivation, shared by {!Runtime.id_of_binding} and any caller indexing
    runtimes by id. *)
let binding_key (b : binding) : string =
  Printf.sprintf "%s.%s" b.provider_id b.model_id
;;
