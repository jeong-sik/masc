(** Shared trust classification for LLM usage telemetry. *)

type t =
  | Usage_missing
  | Usage_trusted
  | Usage_untrusted of string list

(** #9959: Anthropic prompt caching minimum cacheable input.  At
    1024 input tokens, sonnet/opus prompts become eligible for
    [cache_control] caching; below this threshold, a 0 cache
    counter is normal.  Exposed for tests and downstream callers
    that want to use the same threshold. *)
val anthropic_cache_min_input_tokens : int

(** Returns [true] when typed provider evidence indicates an
    Anthropic-routed model (Anthropic API, Claude Code, etc.) that
    would normally exercise prompt caching.

    The [provider_kind] from OAS telemetry is authoritative when supplied.
    Without it, only explicit [provider:model] labels are resolved via
    the provider registry. Bare model ids intentionally stay unknown so
    substring matches such as [openrouter:anthropic/...] cannot produce
    false cache-anomaly trust signals. *)
val model_uses_anthropic_caching :
  model_used:string -> resolved_model_id:string -> bool

val model_uses_anthropic_caching_with_provider_kind :
  provider_kind:Llm_provider.Provider_config.provider_kind option ->
  model_used:string -> resolved_model_id:string -> bool

val classify :
  usage_reported:bool ->
  usage:Agent_sdk.Types.api_usage ->
  model_used:string ->
  resolved_model_id:string ->
  context_max:int ->
  t

val classify_with_provider_kind :
  provider_kind:Llm_provider.Provider_config.provider_kind option ->
  usage_reported:bool ->
  usage:Agent_sdk.Types.api_usage ->
  model_used:string ->
  resolved_model_id:string ->
  context_max:int ->
  t

val is_trusted : t -> bool

val to_string : t -> string

val reasons : t -> string list

val json_fields : t -> (string * Yojson.Safe.t) list
