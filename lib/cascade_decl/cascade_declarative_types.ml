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
type cascade_capabilities = {
  (* Tool/event support — #14608 Phase 5.6 prep *)
  supports_inline_tools : bool;
  supports_runtime_mcp_tools : bool;
  supports_runtime_tool_events : bool;
  supports_runtime_mcp_http_headers : bool;
  (* Dispatch axes — A.1 Phase 5.1 caller cutover prep *)
  requires_per_keeper_bridging_for_bound_actor_tools : bool;
      (** A.3 will route [Cascade_transport.resolve_tool_lane_for_oas_tools]
          through this flag instead of matching on [Codex_cli]. *)
  identity_runtime_mcp_header_keys : string list;
      (** Header keys honored by the runtime's auth surface even when
          [supports_runtime_mcp_http_headers] is false. A.3 will have
          [Provider_tool_support] read this list for Codex CLI. *)
  argv_prompt_preflight : bool;
      (** Runtime needs prompt length / argv-byte preflight before
          invocation to avoid silent OS-level argv overflow. *)
  uses_anthropic_caching : bool;
      (** Runtime sends Anthropic-style prompt caching usage fields. *)
  max_turns_per_attempt : int option;
      (** Optional per-attempt cap on [max_turns]. Parser rejects
          non-positive values (warn + None). *)
  tolerates_bound_actor_fallback : bool;
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

let cascade_capabilities_default = {
  supports_inline_tools = false;
  supports_runtime_mcp_tools = false;
  supports_runtime_tool_events = false;
  supports_runtime_mcp_http_headers = false;
  requires_per_keeper_bridging_for_bound_actor_tools = false;
  identity_runtime_mcp_header_keys = [];
  argv_prompt_preflight = false;
  uses_anthropic_caching = false;
  max_turns_per_attempt = None;
  tolerates_bound_actor_fallback = false;
}
type cascade_provider = {
  id : string;
  display_name : string;
  api_format : cascade_api_format;
  transport : cascade_transport;
  is_non_interactive : bool;
  credentials : cascade_credential option;
  liveness_class : cascade_liveness_class option;
  capabilities : cascade_capabilities option;
  headers : (string * string) list option;
}
[@@deriving show, eq]

(** Per-model capabilities — RFC-0058 Model axis M1 (Phase 5.3 prep).

    Mirrors the dispatch-critical subset of OAS [Llm_provider.Capabilities.capabilities]
    so the cascade.toml [\[models.<id>.capabilities\]] sub-table becomes
    the SSOT for per-model feature flags. Currently OAS derives these
    via [for_model_id_static] substring match on model_id strings
    ([starts_with "claude-opus-4"], [starts_with "gpt-5"], etc.). M2
    replaces that derivation with a cascade.toml lookup so OAS no longer
    needs to "know model names".

    Schema-additive in M1 (this PR): no callers consume the fields yet.
    M2 caller cutover wires OAS [for_model_id] to read these fields.

    Field selection prioritises fields that OAS callers branch on but
    that cascade_model_spec does not already cover ([tools_support],
    [thinking_support], [max_context], [streaming] live in the parent
    record). *)
type cascade_model_capabilities = {
  max_output_tokens : int option;
      (** Hard cap on output tokens. None when unknown / model-default. *)
  supports_parallel_tool_calls : bool;
      (** Multiple [tool_use] blocks in one assistant response.
          OpenAI / Anthropic recent models do; CLI wrappers usually
          don't. *)
  supports_image_input : bool;
      (** Vision input via base64 / URL image blocks. *)
  supports_native_streaming : bool;
      (** Server-Sent Events streaming on the wire protocol. Distinct
          from {!cascade_model_spec.streaming} which advertises the
          model's declared streaming support — this field tracks the
          provider-protocol-level capability used for runtime dispatch
          decisions. *)
  supports_caching : bool;
      (** Provider supports any form of response caching (Anthropic
          prompt caching, OpenAI prompt caching, GLM cache). *)
  supports_response_format_json : bool;
      (** [response_format = json_object] / JSON mode. *)
}
[@@deriving show, eq]

let cascade_model_capabilities_default = {
  max_output_tokens = None;
  supports_parallel_tool_calls = false;
  supports_image_input = false;
  supports_native_streaming = false;
  supports_caching = false;
  supports_response_format_json = false;
}

type cascade_model_spec = {
  id : string;
  api_name : string;
  tools_support : bool;
  max_context : int;
  thinking_support : bool;
  max_thinking_budget : int option;
  streaming : bool;
  capabilities : cascade_model_capabilities option;
      (** M1 schema-additive (Phase 5.3 Model axis prep). [None] when
          the [\[models.<id>.capabilities\]] sub-table is absent —
          callers treat as defaults (see
          {!cascade_model_capabilities_default}). *)
}
[@@deriving show, eq]

type cascade_binding = {
  provider_id : string;
  model_id : string;
  is_default : bool;
  max_concurrent : int;
  price_input : float option;
  price_output : float option;
  keep_alive : string option;
  num_ctx : int option;
}
[@@deriving show, eq]

type cascade_alias = {
  provider_id : string;
  model_id : string;
  name : string;
  max_input : int option;
  max_output : int option;
  temperature : float option;
  thinking_enabled : bool option;
  thinking_budget : int option;
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

type cascade_cycle_policy = {
  max_cycles : int;
  backoff_base_ms : int;
  backoff_cap_ms : int;
}
[@@deriving show, eq]

type cascade_scoring_params = {
  latency_baseline_ms : float;
  rate_limit_recency_window_s : float;
  rate_limit_decay_base : float;
  rate_limit_skip_after : int;
  server_error_recency_window_s : float;
  server_error_decay_base : float;
  server_error_skip_after : int;
}
[@@deriving show, eq]

type cascade_tier = {
  name : string;
  members : string list;
  strategy : cascade_strategy;
  max_concurrent : int option;
  cycle_policy : cascade_cycle_policy option;
  sticky_ttl_ms : int option;
  scoring_params : cascade_scoring_params option;
}
[@@deriving show, eq]

type cascade_tier_group = {
  name : string;
  tiers : string list;
  strategy : cascade_strategy;
  fallback : bool;
}
[@@deriving show, eq]

type cascade_route = {
  name : string;
  target : string;
}
[@@deriving show, eq]

type cascade_config = {
  providers : cascade_provider list;
  models : cascade_model_spec list;
  bindings : cascade_binding list;
  aliases : cascade_alias list;
  tiers : cascade_tier list;
  tier_groups : cascade_tier_group list;
  routes : cascade_route list;
  system_targets : cascade_route list;
}
[@@deriving show, eq]

(** {1 Lookup helpers} *)

let provider_of_id (cfg : cascade_config) (id : string) :
    cascade_provider option =
  List.find_opt (fun (p : cascade_provider) -> p.id = id) cfg.providers

let capabilities_for_provider_id (cfg : cascade_config) (id : string) :
    cascade_capabilities option =
  match provider_of_id cfg id with
  | Some p -> p.capabilities
  | None -> None

let model_capabilities_for_id (cfg : cascade_config) (id : string) :
    cascade_model_capabilities option =
  match List.find_opt (fun (m : cascade_model_spec) -> m.id = id) cfg.models with
  | Some m -> m.capabilities
  | None -> None

let model_of_id (cfg : cascade_config) (id : string) :
    cascade_model_spec option =
  List.find_opt (fun (m : cascade_model_spec) -> m.id = id) cfg.models

let binding_of_key (cfg : cascade_config)
    (provider_id : string) (model_id : string) : cascade_binding option =
  List.find_opt
    (fun (b : cascade_binding) ->
       b.provider_id = provider_id && b.model_id = model_id)
    cfg.bindings

let alias_of_key (cfg : cascade_config)
    (provider_id : string) (model_id : string) (name : string) :
    cascade_alias option =
  List.find_opt
    (fun (a : cascade_alias) ->
       a.provider_id = provider_id && a.model_id = model_id && a.name = name)
    cfg.aliases

let binding_key (b : cascade_binding) : string =
  Printf.sprintf "%s.%s" b.provider_id b.model_id

let alias_key (a : cascade_alias) : string =
  Printf.sprintf "%s.%s.%s" a.provider_id a.model_id a.name
