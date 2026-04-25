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

(** Returns [true] when the model identifier indicates an
    Anthropic-routed model (claude_code, anthropic-direct, etc.)
    that would normally exercise prompt caching.  The check is
    case-insensitive and looks for ["claude"] or ["anthropic"]
    anywhere in [model_used] or [resolved_model_id]. *)
val model_uses_anthropic_caching :
  model_used:string -> resolved_model_id:string -> bool

val classify :
  usage_reported:bool ->
  usage:Oas.Types.api_usage ->
  model_used:string ->
  resolved_model_id:string ->
  context_max:int ->
  t

val is_trusted : t -> bool

val to_string : t -> string

val reasons : t -> string list

val json_fields : t -> (string * Yojson.Safe.t) list
