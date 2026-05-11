(** Declarative cascade configuration types (RFC-0058 v2).

    All type names are prefixed with [cascade_] to avoid collision with
    identically-named types in the main masc_mcp library.  OCaml type
    names are resolved globally across library boundaries via .cmi files;
    (include_subdirs no) only prevents source-file inclusion, not type
    name visibility.  Without prefixes, ppx_deriving-generated code
    references the wrong type when [provider], [transport], [binding],
    [strategy], or [tier] exist in both libraries. *)

type cascade_api_format =
  | Messages_api
  | Chat_completions_api
  | Ollama_api
[@@deriving show, eq]

type cascade_transport =
  | Http of string
  | Cli of string
[@@deriving show, eq]

type cascade_credential =
  | Env of string
  | File of string
  | Inline of string
[@@deriving show, eq]

(** Per-provider liveness class — RFC-0058 §3.2.1 (Phase 5.2).
    Schema only at this phase; the field is parsed and validated but
    not yet consumed. Intended to replace the hardcoded cascade-prefix
    → budget match table in
    [Cascade_attempt_liveness_config.budget_for_label] in a follow-up
    phase. The four classes correspond to existing budget constants in
    [Cascade_attempt_liveness]. *)
type cascade_liveness_class =
  | Cloud_fast
  | Cloud_thinking
  | Local_27b
  | Local_70b_plus
[@@deriving show, eq]

(** Per-provider runtime + behavioral capabilities — RFC-0058 §2.4 +
    Phase 5.1 (capability fields) + §3.2 Phase 5.6 (tool/event support).

    Declarative SSOT for cascade-dispatch quirks that historically lived
    as closed-variant matches in OCaml code. Schema-additive: A.1 ships
    the type + parser; A.3 migrates cascade_transport, Provider_tool_support,
    Cascade_error_classify, and Keeper_usage_trust to read these fields
    instead of matching on provider name. *)
type cascade_capabilities =
  { (* Tool/event support — #14608 Phase 5.6 prep *)
    supports_inline_tools : bool
  ; supports_runtime_mcp_tools : bool
  ; supports_runtime_tool_events : bool
  ; supports_runtime_mcp_http_headers : bool
  ; (* Dispatch axes — A.1 Phase 5.1 caller cutover prep *)
    requires_per_keeper_bridging_for_bound_actor_tools : bool
    (** A.3 will route [Cascade_transport.resolve_tool_lane_for_oas_tools]
          through this flag instead of matching on [Codex_cli]. *)
  ; identity_runtime_mcp_header_keys : string list
    (** Header keys honored by the runtime's auth surface even when
          [supports_runtime_mcp_http_headers] is false. A.3 will have
          [Provider_tool_support] read this list for Codex CLI. *)
  ; argv_prompt_preflight : bool
    (** Runtime needs prompt length / argv-byte preflight before
          invocation to avoid silent OS-level argv overflow. *)
  ; uses_anthropic_caching : bool
    (** Runtime sends Anthropic-style prompt caching usage fields. *)
  ; max_turns_per_attempt : int option
    (** Optional per-attempt cap on [max_turns]. Parser rejects
          non-positive values (warn + None). *)
  ; tolerates_bound_actor_fallback : bool
    (** Catalog-level static-validation flag: when [true], this provider
          is intended to be a viable fallback target if the operator's
          catalog also lists an adapter that requires per-keeper bridging
          (e.g. Codex CLI).

          **Current data flow (parsed-only).** This PR adds the schema and
          parser path so cascade.toml can declare the value, but
          [Cascade_catalog_validator.codex_with_bound_actor_only_issue]
          still reads
          [Provider_adapter.tolerates_bound_actor_fallback_for_kind],
          which is hard-coded to per-adapter literals in
          [Provider_adapter] (introduced in #14642). Editing this value
          in cascade.toml has no runtime effect on the catalog warning
          until the caller cutover lands.

          The cutover is a follow-up that routes
          [Provider_adapter.adapter_of_provider_config] through
          [tool_policy_of_cascade_capabilities] (see #14659) so the
          cascade-decl value becomes the SSOT. This field is shipped now
          so the schema is stable before that cutover. *)
  }
[@@deriving show, eq]

let cascade_capabilities_default =
  { supports_inline_tools = false
  ; supports_runtime_mcp_tools = false
  ; supports_runtime_tool_events = false
  ; supports_runtime_mcp_http_headers = false
  ; requires_per_keeper_bridging_for_bound_actor_tools = false
  ; identity_runtime_mcp_header_keys = []
  ; argv_prompt_preflight = false
  ; uses_anthropic_caching = false
  ; max_turns_per_attempt = None
  ; tolerates_bound_actor_fallback = false
  }
;;

type cascade_provider =
  { id : string
  ; display_name : string
  ; api_format : cascade_api_format
  ; transport : cascade_transport
  ; is_non_interactive : bool
  ; credentials : cascade_credential option
  ; liveness_class : cascade_liveness_class option
  ; capabilities : cascade_capabilities option
  ; headers : (string * string) list option
  }
[@@deriving show, eq]

(** Wire-format for controlling thinking/reasoning on OpenAI-compat backends.
    Mirrors OAS [Llm_provider.Capabilities.thinking_control_format].

    Recorded per-model because the same physical model can be served by
    backends with different thinking-control wire shapes (e.g., qwen3
    via llama-server vs via DeepSeek's API), so the model entry pins
    which shape the backend expects. *)
type cascade_thinking_control_format =
  | No_thinking_control
  | Thinking_object (** DeepSeek-style: {"thinking":{"type":"enabled"}} *)
  | Chat_template_kwargs
  (** llama-server style: {"chat_template_kwargs":{"enable_thinking":bool}} *)
[@@deriving show, eq]

(** Per-model capabilities — RFC-0058 Model axis M1 + M1b (Phase 5.3 prep).

    Mirrors the dispatch-critical subset of OAS [Llm_provider.Capabilities.capabilities]
    so the cascade.toml [\[models.<id>.capabilities\]] sub-table becomes
    the SSOT for per-model feature flags. Currently OAS derives these
    via [for_model_id_static] substring match on the upstream *API model
    identifier* — e.g. [starts_with "claude-opus-4"], [starts_with
    "gpt-5"]. That input is the api-name (cascade_model_spec.api_name /
    Provider_config.model_id), not the cascade [\[models.<id>\]] key.
    M2 replaces that derivation with a cascade.toml lookup keyed on the
    cascade [<id>] (the cascade key) so OAS no longer needs to "know
    model names". *)

type cascade_model_capabilities =
  { max_output_tokens : int option
    (** Hard cap on output tokens. None when unknown / model-default. *)
  ; (* Tool use *)
    supports_parallel_tool_calls : bool
    (** Multiple [tool_use] blocks in one assistant response. *)
  ; supports_tool_choice : bool
    (** Server-side [tool_choice] forcing. Most CLI-wrappers do not
          honour it. *)
  ; (* Thinking / reasoning *)
    supports_extended_thinking : bool
    (** [budget_tokens] / [reasoning_effort] knob. Distinct from
          {!cascade_model_spec.thinking_support} which is the on/off
          gate; this is the budgeted-depth control. *)
  ; supports_reasoning_budget : bool (** Per-request reasoning depth control accepted. *)
  ; thinking_control_format : cascade_thinking_control_format
    (** Wire shape for thinking control on OpenAI-compat backends.
          [No_thinking_control] is the safe default (no reasoning
          surface). *)
  ; (* Multimodal *)
    supports_image_input : bool (** Vision input via base64 / URL image blocks. *)
  ; supports_audio_input : bool
  ; supports_video_input : bool
  ; supports_multimodal_inputs : bool
    (** Any non-text input. Distinct from the per-modality flags above:
          true when at least one of image/audio/video is true. Declarative
          surface keeps both so validators can detect the discrepancy. *)
  ; (* Output format *)
    supports_response_format_json : bool
    (** [response_format = json_object] / JSON mode. *)
  ; supports_structured_output : bool
    (** JSON-schema strict mode (100% conforming output). *)
  ; (* Protocol *)
    supports_native_streaming : bool
    (** Server-Sent Events streaming on the wire protocol. Distinct
          from {!cascade_model_spec.streaming} which advertises the
          model's declared streaming support — this field tracks the
          provider-protocol-level capability used for runtime dispatch
          decisions. *)
  ; supports_caching : bool
    (** Provider supports any form of response caching (Anthropic
          prompt caching, OpenAI prompt caching, GLM cache). *)
  ; supports_prompt_caching : bool
    (** Anthropic-style explicit prompt cache_control blocks. *)
  ; prompt_cache_alignment : int option
    (** Token-boundary alignment for prompt cache breakpoints (Anthropic
          requires multiples of 1024 in some tiers). *)
  ; (* Sampling parameters *)
    supports_top_k : bool
  ; supports_min_p : bool
  ; supports_seed : bool (** Deterministic seed for reproducible sampling. *)
  ; (* Usage reporting *)
    emits_usage_tokens : bool
    (** True when the provider's standard response carries
          [input_tokens]/[output_tokens] (direct APIs like Anthropic,
          OpenAI, Gemini, Kimi-API, GLM, Ollama). False for CLI-class
          wrappers that strip usage before returning (codex_cli,
          gemini_cli, kimi_cli). Default-true matches OAS. *)
  ; (* Advanced modalities *)
    supports_computer_use : bool
  }
[@@deriving show, eq]

let cascade_model_capabilities_default =
  { max_output_tokens = None
  ; supports_parallel_tool_calls = false
  ; supports_tool_choice = false
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
  ; supports_caching = false
  ; supports_prompt_caching = false
  ; prompt_cache_alignment = None
  ; supports_top_k = false
  ; supports_min_p = false
  ; supports_seed = false
  ; emits_usage_tokens =
      true
      (* stricter default: most providers report usage; CLI wrappers explicitly opt out *)
  ; supports_computer_use = false
  }
;;

type cascade_model_spec =
  { id : string
  ; api_name : string
  ; tools_support : bool
  ; max_context : int
  ; thinking_support : bool
  ; max_thinking_budget : int option
  ; streaming : bool
  ; capabilities : cascade_model_capabilities option
    (** M1 schema-additive (Phase 5.3 Model axis prep). [None] when
          the [\[models.<id>.capabilities\]] sub-table is absent —
          callers treat as defaults (see
          {!cascade_model_capabilities_default}). *)
  ; match_prefixes : string list
    (** Prefixes for matching against requested model_id strings.
          Empty list = the spec matches a single specific model_id given
          by [api_name].

          M2 OAS cutover replaces the substring if/elsif tree in
          {!Llm_provider.Capabilities.for_model_id_static} with a
          longest-prefix-first scan over cascade.toml [\[models.*\]]
          entries — given a request for [model_id], find the spec whose
          [match_prefixes] contain the longest string [p] such that
          [model_id] starts with [p].

          Single-spec example: [\[models.sonnet\]] with [api-name =
          "claude-sonnet-4-6"] and [match-prefixes = []] matches only
          [claude-sonnet-4-6]. Family example: [\[models.sonnet-family\]]
          with [match-prefixes = ["claude-sonnet-4"]] matches every
          [claude-sonnet-4-*] release.

          Longest-prefix-first resolves precedence without an explicit
          priority field: [match-prefixes = ["glm-5-turbo"]] beats
          [match-prefixes = ["glm-5"]] because the former is longer.
          Mirrors the implicit ordering of OAS's if/elsif tree
          ([starts_with "glm-5-turbo"] checked before [starts_with
          "glm-5"]). *)
  }
[@@deriving show, eq]

type cascade_binding =
  { provider_id : string
  ; model_id : string
  ; is_default : bool
  ; max_concurrent : int
  ; price_input : float option
  ; price_output : float option
  ; keep_alive : string option
  ; num_ctx : int option
  }
[@@deriving show, eq]

type cascade_alias =
  { provider_id : string
  ; model_id : string
  ; name : string
  ; max_input : int option
  ; max_output : int option
  ; temperature : float option
  ; thinking_enabled : bool option
  ; thinking_budget : int option
  }
[@@deriving show, eq]

type cascade_strategy =
  | Failover
  | Capacity_aware
  | Weighted_random
  | Circuit_breaker_cycling
  | Priority_tier
  | Sticky
  | Round_robin
[@@deriving show, eq]

type cascade_cycle_policy =
  { max_cycles : int
  ; backoff_base_ms : int
  ; backoff_cap_ms : int
  }
[@@deriving show, eq]

type cascade_scoring_params =
  { latency_baseline_ms : float
  ; rate_limit_recency_window_s : float
  ; rate_limit_decay_base : float
  ; rate_limit_skip_after : int
  ; server_error_recency_window_s : float
  ; server_error_decay_base : float
  ; server_error_skip_after : int
  }
[@@deriving show, eq]

type cascade_tier =
  { name : string
  ; members : string list
  ; strategy : cascade_strategy
  ; max_concurrent : int option
  ; cycle_policy : cascade_cycle_policy option
  ; sticky_ttl_ms : int option
  ; scoring_params : cascade_scoring_params option
  }
[@@deriving show, eq]

type cascade_tier_group =
  { name : string
  ; tiers : string list
  ; strategy : cascade_strategy
  ; fallback : bool
  }
[@@deriving show, eq]

type cascade_route =
  { name : string
  ; target : string
  }
[@@deriving show, eq]

type cascade_config =
  { providers : cascade_provider list
  ; models : cascade_model_spec list
  ; bindings : cascade_binding list
  ; aliases : cascade_alias list
  ; tiers : cascade_tier list
  ; tier_groups : cascade_tier_group list
  ; routes : cascade_route list
  ; system_targets : cascade_route list
  }
[@@deriving show, eq]

(** {1 Lookup helpers} *)

let provider_of_id (cfg : cascade_config) (id : string) : cascade_provider option =
  List.find_opt (fun (p : cascade_provider) -> p.id = id) cfg.providers
;;

let capabilities_for_provider_id (cfg : cascade_config) (id : string)
  : cascade_capabilities option
  =
  match provider_of_id cfg id with
  | Some p -> p.capabilities
  | None -> None
;;

let model_of_id (cfg : cascade_config) (id : string) : cascade_model_spec option =
  List.find_opt (fun (m : cascade_model_spec) -> m.id = id) cfg.models
;;

let model_capabilities_for_id (cfg : cascade_config) (id : string)
  : cascade_model_capabilities option
  =
  Option.bind (model_of_id cfg id) (fun (m : cascade_model_spec) -> m.capabilities)
;;

let model_spec_for_api_name (cfg : cascade_config) (model_id : string)
  : cascade_model_spec option
  =
  (* Longest-prefix-first scan over [models.*] entries.
     - Exact api_name match wins outright (longest possible match).
     - Otherwise the spec whose match_prefixes contains the longest
       string p with String.starts_with model_id p wins.
     - Ties on length resolve to the first-declared entry (List.fold_left
       keeps the earlier-seen winner unless a strictly-longer match arrives).
     - Returns None if no entry matches. *)
  let starts_with ~prefix s =
    let plen = String.length prefix in
    String.length s >= plen && String.sub s 0 plen = prefix
  in
  let best_match =
    List.fold_left
      (fun acc (m : cascade_model_spec) ->
         (* Exact api_name match: synthetic prefix of full length. *)
         let exact_candidate =
           if m.api_name = model_id then Some (String.length model_id, m) else None
         in
         let prefix_candidates =
           List.filter_map
             (fun p ->
                if starts_with ~prefix:p model_id then Some (String.length p, m) else None)
             m.match_prefixes
         in
         let candidates =
           match exact_candidate with
           | Some c -> c :: prefix_candidates
           | None -> prefix_candidates
         in
         List.fold_left
           (fun acc' (len, spec) ->
              match acc' with
              | None -> Some (len, spec)
              | Some (best_len, _) when len > best_len -> Some (len, spec)
              | Some _ -> acc')
           acc
           candidates)
      None
      cfg.models
  in
  Option.map snd best_match
;;

let model_capabilities_for_api_name (cfg : cascade_config) (model_id : string)
  : cascade_model_capabilities option
  =
  Option.bind (model_spec_for_api_name cfg model_id) (fun (m : cascade_model_spec) ->
    m.capabilities)
;;

let binding_of_key (cfg : cascade_config) (provider_id : string) (model_id : string)
  : cascade_binding option
  =
  List.find_opt
    (fun (b : cascade_binding) -> b.provider_id = provider_id && b.model_id = model_id)
    cfg.bindings
;;

let alias_of_key
      (cfg : cascade_config)
      (provider_id : string)
      (model_id : string)
      (name : string)
  : cascade_alias option
  =
  List.find_opt
    (fun (a : cascade_alias) ->
       a.provider_id = provider_id && a.model_id = model_id && a.name = name)
    cfg.aliases
;;

let binding_key (b : cascade_binding) : string =
  Printf.sprintf "%s.%s" b.provider_id b.model_id
;;

let alias_key (a : cascade_alias) : string =
  Printf.sprintf "%s.%s.%s" a.provider_id a.model_id a.name
;;
