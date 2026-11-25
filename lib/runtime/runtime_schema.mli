(** Self-standing Runtime configuration types.

    Provider × Model × Binding declarative schema,
    as types owned by
    [lib/runtime/]. Routing layers (aliases/routes/profiles/strategy) are
    intentionally left out: a Runtime is a single pre-selected binding. *)

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
  | Acp_runtime
[@@deriving show, eq]

type output_schema_channel =
  | Holds_output_schema
  | No_output_schema_channel

val api_format_output_schema_channel : api_format -> output_schema_channel
(** Whether a runtime of this format can be handed a JSON Schema to hold its
    answer to. Every exact-output call hands one over, so a format without
    the channel stands in no exact-output list. The lane writers, the load
    check of [cli_slots] and first-run setup all read this one answer. *)

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
    catalog has never seen: the install wizard's provider id carries a hash
    of the operator's answers, so no catalog row can ever match it. *)
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
val admission_timeout_s_key : string
val admission_priority_run_limit_key : string
val store_key : string
val truncation_key : string
val explicit_context_cache_ttl_s_key : string

(** OpenAI Responses API [truncation] policy re-exported from AGENT_CORE so
    variant changes remain compiler-checked.
    Ref: https://developers.openai.com/api/reference/cli/resources/responses/methods/create *)
type responses_truncation =
  Llm_provider.Provider_config.responses_truncation =
  | Truncation_auto
  | Truncation_disabled
[@@deriving show, eq]

val responses_truncation_to_string : responses_truncation -> string
val responses_truncation_of_string : string -> responses_truncation option

type antigravity_effort =
  | Antigravity_low
  | Antigravity_medium
  | Antigravity_high
  | Antigravity_xhigh
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

type acp_driver = Runtime_acp_client.driver =
  | Antigravity
  | Kimi_code
  | Mistral_vibe
  | Muse_code
[@@deriving show, eq]

type acp_options =
  { driver : acp_driver
  ; args : string list
  ; strip_env : string list
  ; skills_dirs : string list
  ; effort : Llm_provider.Reasoning_effort.t option
  ; mode : string option
  ; contributor_mode : Runtime_acp_client.contributor_mode
        (** [contributor-mode] — [Contributor_off] when the key is absent.
            Valid only for driver [muse_code]. *)
  ; timeout_s : float
  ; admission_timeout_s : float
  }
[@@deriving show, eq]

(** [providers.<id>.usage-read.shape] — which response a provider's usage
    endpoint gives. Each shape has its own decoder in
    {!Runtime_provider_usage_window}; the provider id never selects one. *)
type usage_read_shape =
  | Openrouter_key
  | Zai_quota_limit
  | Kimi_coding_usages
  | Ollama_balance
[@@deriving show, eq]

val all_usage_read_shapes : usage_read_shape list

val usage_read_shape_to_string : usage_read_shape -> string
(** The [shape] value as written in runtime.toml. *)

(** [providers.<id>.usage-read] — a GET endpoint that states the account's
    usage windows without a model call. [url] is an absolute [https://] URL;
    the request authenticates with the provider's own [credentials]. Read for
    the operator projection, and once after the provider answers HTTP 403,
    when a spent window rests the account. *)
type usage_read =
  { shape : usage_read_shape
  ; url : string
  ; refresh_s : float option
    (** [refresh-s] — seconds from the end of one read to the next, after the
        read at server start. [None] reads at server start only. *)
  ; credit_url : string option
    (** [usage-read.credit.url] — OpenRouter's optional auxiliary account
        Credit endpoint. It uses the same credential and refresh period. *)
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
  ; catalog_provider : string option
    (** The AGENT_CORE catalog provider row this provider speaks as when its own
        id names no row, as an account of a catalog provider with its own
        credential does. Catalog lookups read {!catalog_provider_id}; the
        account keeps [id]. [None] means [id] is the only name it has. *)
  ; request_path : string option
    (** Explicit HTTP request surface, relative to the endpoint. None uses the catalog/protocol. *)
  ; transport : transport
  ; is_non_interactive : bool
  ; credentials : credential option
  ; max_context : int option
    (** Provider context default; a binding override takes precedence, then the model default. *)
  ; account_home : string option
    (** Absolute, operator-owned CLI state directory for Claude Code or Codex;
        when omitted they resolve their native account environment. *)
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
  ; admission_priority_run_limit : int option
    (** [admission-priority-run-limit]: how many admission permits in a row
        this provider account may hand to [Priority] requests (the judgment
        lanes) while a [Standard] request waits for one. The same limit bounds
        combined [Priority]/[Standard] grants while [Background] memory work
        waits, so neither Keeper calls nor maintenance can starve. [None]
        keeps one arrival-order queue. Declared on the provider because the
        permits are counted per account. It reaches only the bindings that declare
        [max-concurrent]; a provider where no binding can use it, or an
        official-client provider, is refused at load. *)
  ; antigravity_cli : antigravity_cli_options option
    (** Present exactly when [protocol = "antigravity-cli"]. *)
  ; acp : acp_options option
    (** Present exactly when [protocol = "acp"]. *)
  ; usage_read : usage_read option
    (** [providers.<id>.usage-read]; [None] when not declared. *)
  ; store : bool option
    (** [providers.<id>.store] — OpenAI Responses API server-side persistence
        flag ([false] for stateless ZDR workflows). Valid only on Responses API
        providers; refused on all other protocols. *)
  ; truncation : responses_truncation option
    (** [providers.<id>.truncation] — OpenAI Responses API server-side
        truncation policy (["auto"] | ["disabled"]). Valid only on Responses
        API providers; refused on all other protocols. *)
  ; explicit_context_cache_ttl_s : int option
    (** [providers.<id>.explicit-context-cache-ttl-s] — positive TTL in seconds
        for Gemini/Vertex explicit [cachedContents] resources. Valid only on
        Gemini/Vertex providers; models whose catalog row declares
        [prompt_cache_wire = No_prompt_cache_wire] (such as Gemini 4) stay
        implicit-only. *)
  }
[@@deriving show, eq]

val catalog_provider_key : string
(** ["catalog-provider"], the [\[providers.<id>\]] key that fills
    [catalog_provider]. *)

val catalog_provider_id : provider -> string
(** The id every AGENT_CORE catalog lookup for this provider uses:
    [catalog_provider] when declared, otherwise [id]. Credentials, quota
    scope, runtime ids and rest cells keep [id], so two accounts of one
    catalog row stay apart (RFC account-provider-speaks-as-a-catalog-row
    §3.2). *)

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
  | Reasoning_effort_default_on
  (** Categorical depth with reasoning enabled when effort is omitted.
      Explicit enable is already satisfied; disable still requires an accepted [none]. *)
  | Reasoning_enabled
  (** Boolean [reasoning.enabled] control without categorical depth selection. *)
[@@deriving show, eq]

type reasoning_streaming_format =
  Llm_provider.Capabilities.reasoning_streaming_format =
  | Default_reasoning_streaming
  | No_reasoning_streaming
  | Delta_reasoning_field of string
  | Delta_reasoning_field_and_details of string
  | Template_reasoning_streaming
[@@deriving show, eq]

type anthropic_thinking_control =
  Llm_provider.Capabilities.anthropic_thinking_control =
  | Anthropic_adaptive_default
  | Anthropic_adaptive_disabled_through_high
  | Anthropic_adaptive_between_tools
  | Anthropic_always_adaptive
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
  ; accepted_reasoning_efforts : Llm_provider.Reasoning_effort.t list option
      (** Efforts a categorical reasoning-effort wire accepts from this model,
          as probed against the operator's own endpoint. The dispatch check
          refuses an effort until some layer declares this list; the Agent
          Core catalog carries it for catalogued models, and this field is
          how a runtime block declares it for a model the catalog does not
          know. [None] preserves catalog resolution. *)
  ; anthropic_thinking_control : anthropic_thinking_control option
      (** Deployment-declared Anthropic thinking-control policy, for a binding
          the Agent Core catalog answers no policy for (operator-own pattern).
          [None] preserves catalog resolution. The loader refuses this key
          where the catalog already declares a policy for the binding's model,
          and where the binding's wire is not Anthropic. *)
  ; reasoning_streaming_format : reasoning_streaming_format option
      (** Exact streaming side-channel for this transport binding. *)
  ; supports_image_input : bool option
  ; supports_document_input : bool option
      (** Native document input. [None] withholds document input, as for other
          media declarations. The selected transport must also represent it. *)
  ; supports_audio_input : bool option
  ; supports_video_input : bool option
  ; supports_multimodal_inputs : bool option
  ; supports_response_format_json : bool option
  ; supports_structured_output : bool option
  ; supports_system_prompt : bool option
  ; supports_assistant_prefill : bool option
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
      (** Shared model default, below binding and provider declarations.
          [None] leaves undeclared bindings to the capability catalog. Resolve via
          {!Runtime_instance.resolve_max_context_of_runtime}, never read directly. *)
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
  ; explicit_context_cache_ttl_s : int option
    (** [models.<id>.explicit-context-cache-ttl-s] — positive TTL in seconds for
        Gemini/Vertex explicit [cachedContents] resources, overriding the
        provider setting. Refused on non-Gemini protocols or models that do not
        declare [Gemini_explicit_cached_content] (such as Gemini 4). *)
  ; capabilities : model_capabilities option
  }
[@@deriving show, eq]

val thinking_request : model_spec -> bool option
(** The thinking request a model row asks for: [thinking_support], except
    [None] on a [reasoning_uncontrolled] row, which sends no thinking control
    at all. Every request built from a model row reads this. *)

(** {1 Layer 3: Binding} *)

(** How long the provider keeps the request prefix it caches, declared as a
    binding's [cache-retention]. *)
type cache_retention =
  | Five_minutes  (** ["5m"]: the provider's default lifetime (Anthropic/Kimi/OpenRouter). *)
  | One_hour
      (** ["1h"]: one-hour lifetime (Anthropic/Kimi/OpenRouter); every cache
          write is priced above a five-minute one. *)
  | In_memory
      (** ["in_memory"]: OpenAI Responses API in-memory prompt cache retention. *)
  | Twenty_four_hours
      (** ["24h"]: OpenAI Responses API extended 24-hour prompt cache retention. *)
[@@deriving show, eq]

val cache_retention_to_string : cache_retention -> string
(** The declared spelling: ["5m"], ["1h"], ["in_memory"], or ["24h"]. *)

val cache_retention_of_string : string -> cache_retention option
(** [None] for any other spelling. *)

type binding =
  { provider_id : string
  ; model_id : string
  ; enabled : bool
    (** Whether this provider x model binding may be materialized. Omitted
        [enabled] in TOML defaults to [true]. *)
  ; is_default : bool
  ; wizard_default : bool
  ; max_context : int option
    (** Context override for this provider/model binding, before provider and model defaults. *)
  ; max_concurrent : int option
  ; disable_parallel_tool_use : bool
        (** Request policy for this binding. [true] asks the provider for at
            most one tool call per response; [false] (the default) leaves
            parallel calls permitted by the model's catalog capability.
            This does not change that capability or serialize spawned agents.
            Official-client, native Ollama and Gemini runtimes cannot carry
            this policy and refuse [true]. *)
  ; cache_retention : cache_retention option
        (** Request policy for this binding: the lifetime of every cache
            breakpoint a request writes. Absent keeps the provider's default
            (five minutes on Anthropic). Only a Messages runtime whose catalog
            provider row declares [supports_extended_cache_ttl] carries it;
            any other refuses a declared value at load time. *)
  ; provider_only : string list
        (** Optional upstream provider allowlist ([provider-only], e.g.
            OpenRouter [provider.only] including sub-tags such as
            ["alibaba/us-east-1"]). Empty when omitted. Only a Chat Completions
            binding whose catalog provider row declares
            [supports_provider_routing_filter] carries it; any other refuses a
            non-empty list at load time. *)
  ; provider_ignore : string list
        (** Optional upstream provider denylist ([provider-ignore], e.g.
            OpenRouter [provider.ignore] such as ["amazon-bedrock"]). Empty
            when omitted. Only a Chat Completions binding whose catalog
            provider row declares [supports_provider_routing_filter] carries
            it; any other refuses a non-empty list at load time. *)
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
  ; effort : Llm_provider.Reasoning_effort.t option
    (** Binding-scoped reasoning effort override ([effort = "low" | "medium" | "high" | "xhigh" | "max" | ...]).
        Overrides [model_spec.reasoning_effort] when set, allowing one model
        declaration to serve multiple effort levels without duplicating
        [[models.<m>-<effort>]] triples. *)
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

(** Who owns an exact-output lane. The owner, not a free string, names the
    lane's table under [runtime] and its registry key, so a reader that needs
    either matches on the owner. Every lane today is a built-in standalone
    lane. *)
val exact_output_name_valid : string -> bool
(** An exact output name: [a-z][a-z0-9_]*, as a package manifest declares it. *)

(** A Lane Add-on installation's named exact output: the declaration id that
    owns the persistent volume and a [world.exact_outputs] name. Private, so
    every value has a non-blank declaration id and a valid output name, which
    is what keeps {!exact_lane_key} unambiguous. *)
type addon_lane = private { declaration_id : string; output : string }
[@@deriving show, eq]

val addon_lane : declaration_id:string -> output:string -> (addon_lane, string) result

type exact_lane_owner =
  | Builtin of
      (Standalone_lane.t
      [@printer fun fmt lane -> Format.pp_print_string fmt (Standalone_lane.to_id lane)]
      [@equal Standalone_lane.equal])
  | Addon of addon_lane
[@@deriving show, eq]

val exact_lane_key : exact_lane_owner -> string
(** The key the exact-output registry, its errors and the wires carry:
    {!Standalone_lane.to_id} for a built-in lane, [<declaration_id>/<output>]
    for an add-on lane. *)

val exact_lane_owner_of_key : string -> exact_lane_owner option
(** The owner whose {!exact_lane_key} is the argument. A key no lane has is
    [None]. *)

val exact_lane_table_path : exact_lane_owner -> string list
(** The lane's table in the runtime file, from the root:
    [["runtime"; "exact_output_lanes"; id]] for a built-in lane and
    [["runtime"; "addon_exact_lanes"; declaration_id; output]] for an add-on
    lane. *)

val exact_lane_table_name : exact_lane_owner -> string
(** {!exact_lane_table_path} as a TOML table name: each key rendered by
    {!Toml_line_editor.render_key}, so a declaration id that is not a bare key
    is quoted. *)

type exact_output_lane_decl =
  { owner : exact_lane_owner
  ; enabled : bool
        (** Whether new work may acquire this lane. Omitting [enabled] in TOML
            means true. False preserves its candidates and request settings;
            already acquired immutable run snapshots are unaffected. *)
  ; slot_ids : string list
  ; cli_slot_ids : string list
        (** [cli_slots] — official-client runtime ids walked as one-shot
            fallbacks AFTER every catalog slot is exhausted.
            Empty keeps the lane
            HTTP-only. *)
  ; max_output_tokens : int option
        (** [max_output_tokens] — the output budget the lane's requests
            declare as [max_tokens]. [None] means the declaration named no
            budget: the requests carry no [max_tokens] of their own, so the
            provider's default applies (or, on a wire that requires the
            field, the catalog maximum). The catalog's [max_output_tokens]
            is a validation bound and is never sent in its place. *)
  ; thinking : bool option
        (** [thinking] — [Some flag] sends [enable_thinking = flag] on every
            HTTP slot of the lane. [None] leaves each slot's catalog default
            (the model's [thinking-support]). Every slot of an enabled lane must be
            able to carry the setting; registry publication refuses the lane
            and names the slot otherwise ([Lane_thinking_not_encodable]). *)
  }
[@@deriving show, eq]

(** {1 Top-level config} *)

(** One System One server [\[typesafeai\] destinations] names. *)
type typesafeai_destination =
  { endpoint : string  (** the URL the request is posted to *)
  ; model : string  (** the model id as that server names it *)
  ; api_key_env : string  (** the environment variable holding that server's bearer key *)
  }
[@@deriving show, eq]

(** Which keepers memory recall judges. *)
type memory_recall_scope =
  | All_keepers  (** every keeper that [excluded_keepers] does not name *)
  | Listed_keepers of string * string list  (** only these keepers, at least one *)
[@@deriving show, eq]

(** [\[typesafeai\] memory_recall], with the scope it needs. Switching recall
    on names the keepers it reaches: there is no on without a scope. *)
type memory_recall =
  | Memory_recall_off
  | Memory_recall_on of memory_recall_scope
[@@deriving show, eq]

(** [\[typesafeai\]] -- the TypeSafe AI (System One Jev) lane. Keys stay in
    the environment; each destination names the variable holding its own
    ([api_key_env]). Everything else about the lane is here. [lane_enabled]
    turns the lane off; it cannot turn it on without a key in one of the named
    variables. [destinations] are the System One servers asked in order until
    one answers ({!Typesafeai_client.evaluate}); TypeSafe's own server and
    OpenRouter's [/api/v1/systemone] both speak the protocol. The
    [board_attention] gate asks the vendor (the Board attention judgment,
    {!Keeper_board_attention_exact_flow}, which sends the post and the
    keeper's context). Context
    preservation, Skill applicability, host shared-memory selection and
    memory recall each require independent opt-in. Memory recall also needs
    its scope. All reach the
    same destinations, so one [excluded_keepers] applies to every review: a
    keeper named there is never asked about, whichever gate asks. *)
type typesafeai =
  { lane_enabled : bool
  ; destinations : typesafeai_destination * typesafeai_destination list
  ; board_attention : bool
  ; board_attention_confidence_floor : float
      (** [board_attention_confidence_floor]: Jev's relevant or not-relevant
          answer settles a Board attention candidate when its confidence is at
          least this value (0 to 1); below it the [board_attention_exact] lane
          judges the candidate. *)
  ; context_review : bool
  ; skill_applicability : bool
  ; workspace_memory_selection_enabled : bool
      (** Independent opt-in to send current input/task context and shared-memory
          interpretations/source details for host retrieval. Defaults to false. *)
  ; memory_recall : memory_recall
      (** Opt-in to send a keeper's stored facts and the turn's input for the
          recall judgment. Defaults to off. *)
  ; excluded_keepers : string list
  }
[@@deriving show, eq]

val typesafe_destination : typesafeai_destination
(** TypeSafe's own server, its latest model, and [TYPESAFEAI_API_KEY]. *)

val default_typesafeai : typesafeai
(** What an absent [\[typesafeai\]] table means: the lane on when a key is
    set, {!typesafe_destination} alone, Board attention on with a 0.3
    confidence floor, and memory recall off. *)

type media_reader_adapter = Markitdown_mcp
[@@deriving show, eq]

(** A complete external-reader declaration from one runtime snapshot.
    [revision] names an interpretation revision; it does not authenticate
    executable bytes, dependencies or an account. [command] and [args] name
    the Keeper execution environment and are preserved without host expansion.
    [media_types] contains exact declared MIME strings. Overlapping support
    between distinct IDs is valid; list order does not select a reader.
    Loading a declaration does not grant execution authority or prove support. *)
type media_reader_decl =
  { id : string
  ; revision : string
  ; kind : Media_reading_kind.t
  ; media_types : string list
  ; adapter : media_reader_adapter
  ; command : string
  ; args : string list
  }
[@@deriving show, eq]

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
    (** [\[runtime\].media_failover] — the vision runtimes: ordered runtime ids
        the vision tool calls, including the image readings made for a runtime
        that cannot take the image. A keeper turn never dispatches to them; its
        image reroute stays inside its lane. [[]] = no vision runtimes. Each id must
        resolve to a configured runtime (rejected at load like
        [\[runtime\].default]). *)
  ; media_readers : media_reader_decl list
    (** [\[\[media_readers\]\]] — complete declarations in source order.
        Absence and an explicit empty list both mean no declared readers. *)
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
  ; browser : Browser_configuration.t
    (** Browser backend paths and per-lane activity from the same TOML snapshot. *)
  ; machines : Machine_configuration.t
    (** MSX and DOS activity from the same TOML snapshot. *)
  ; typesafeai : typesafeai
    (** [\[typesafeai\]] -- see {!typesafeai}. Absent is {!default_typesafeai}. *)
  ; egress_allowlists : Egress_allowlist.t list
    (** [\[egress.keepers.<name>\]] — what a keeper in the policy lane may
        reach. A keeper with no entry has an empty allowlist,
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
