(** Declarative cascade configuration types (RFC-0058 v2).

    5-layer TOML schema internal representation:
    Layer 1: [providers.*]     — How to connect
    Layer 2: [models.*]        — What it can do
    Layer 3: [<p>.<m>]         — How much, at what cost
    Layer 4: [<p>.<m>.<a>]     — Per-use overrides
    Layer 5: [tier.*] + [tier-group.*] + [routes] — Routing strategy

    Code knows API formats, not provider brands. See RFC-0058 §2.1.

    All type names are prefixed with [cascade_] to avoid collision with
    identically-named types in the main masc_mcp library. *)


(** {1 API Format & Transport} *)

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


(** {1 Layer 1: Providers} *)

(** Per-provider liveness class — RFC-0058 §3.2.1 (Phase 5.2).
    Schema only at this phase; the field is parsed and validated but
    not yet consumed. Intended to replace the hardcoded cascade-prefix
    → budget match table in
    [Cascade_attempt_liveness_config.budget_for_label] in a follow-up
    phase. *)
type cascade_liveness_class =
  | Cloud_fast
  | Cloud_thinking
  | Local_27b
  | Local_70b_plus
[@@deriving show, eq]

(** Per-provider runtime capabilities — RFC-0058 §3.2 + Phase 5.1 caller
    cutover prerequisite. Reserved as schema-only here: a follow-up phase
    will replace the hardcoded variant match in
    [Llm_provider.Capabilities.{claude_code,gemini_cli,kimi_cli,codex_cli}_capabilities]
    with a cascade.toml lookup. Boolean defaults are [false] — explicit
    declaration in TOML is required for any non-false capability. *)
type cascade_capabilities = {
  supports_inline_tools : bool;
  supports_runtime_mcp_tools : bool;
  supports_runtime_tool_events : bool;
  supports_runtime_mcp_http_headers : bool;
}
[@@deriving show, eq]

type cascade_provider = {
  id : string;
  display_name : string;
  api_format : cascade_api_format;
  transport : cascade_transport;
  is_non_interactive : bool;
  credentials : cascade_credential option;
  liveness_class : cascade_liveness_class option;
  capabilities : cascade_capabilities option;
  (** Reserved (Phase 5.6) — caller cutover in follow-up. *)
  headers : (string * string) list option;
  (** Reserved (Phase 5.6) — additional HTTP headers per provider,
      e.g. [("anthropic-version", "2023-06-01")] for Anthropic HTTP API.
      Sorted by key for deterministic show/eq. Caller cutover in follow-up
      replaces [Cascade_config.headers_with_auth] variant match. *)
}
[@@deriving show, eq]


(** {1 Layer 2: Models} *)

type cascade_model_spec = {
  id : string;
  api_name : string;
  tools_support : bool;
  max_context : int;
  thinking_support : bool;
  max_thinking_budget : int option;
  streaming : bool;
}
[@@deriving show, eq]


(** {1 Layer 3: Bindings (Provider×Model)} *)

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


(** {1 Layer 4: Aliases} *)

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


(** {1 Strategy} *)

type cascade_strategy =
  | Failover
  | Capacity_aware
  | Weighted_random
  | Circuit_breaker_cycling
  | Priority_tier
  | Sticky
  | Round_robin
[@@deriving show, eq]


(** {1 Strategy-specific parameter types} *)

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

(** {1 Layer 5: Tiers, Tier-Groups, Routes} *)

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


(** {1 Top-level Config} *)

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

val provider_of_id : cascade_config -> string -> cascade_provider option

val model_of_id : cascade_config -> string -> cascade_model_spec option

val binding_of_key : cascade_config -> string -> string -> cascade_binding option

val alias_of_key : cascade_config -> string -> string -> string -> cascade_alias option

val binding_key : cascade_binding -> string

val alias_key : cascade_alias -> string
