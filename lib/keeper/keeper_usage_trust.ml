(** Shared trust classification for LLM usage telemetry.

    This module is intentionally independent of the unified keeper metrics
    pipeline so both unified turns and OAS after-turn hooks can apply the same
    guard before aggregating tokens, cost, or wall-clock tok/s. *)

type t =
  | Usage_missing
  | Usage_trusted
  | Usage_untrusted of string list

let absurd_token_threshold = 1_000_000

(* #9959: Anthropic prompt caching minimum cacheable input size.

   Anthropic's prompt caching (the [cache_control] field on
   message content blocks) only kicks in when the cached prefix
   contains at least 1024 input tokens for sonnet/opus and 2048
   for haiku.  Below that threshold,
   [cache_creation_input_tokens] and [cache_read_input_tokens]
   legitimately stay at zero.  The conservative minimum (1024)
   avoids false positives on tiny keepalive prompts while still
   catching the #9959 case where 1078/1078 turn rows (every
   claude_code:auto turn over a full day) reported
   cache_creation = cache_read = 0 despite typical keeper system
   prompts running 5K-30K tokens. *)
let anthropic_cache_min_input_tokens = 1024

let provider_kind_uses_anthropic_caching
    (kind : Llm_provider.Provider_config.provider_kind) : bool =
  match kind with
  | Anthropic | Claude_code -> true
  | OpenAI_compat | Ollama | Gemini | Gemini_cli | Kimi | Kimi_cli | Glm
  | Codex_cli | DashScope ->
      false

let model_label_provider_kind label =
  Provider_kind_resolver.kind_of_spec label

let model_uses_anthropic_caching_with_provider_kind ~provider_kind ~(model_used : string)
    ~(resolved_model_id : string) : bool =
  match provider_kind with
  | Some kind -> provider_kind_uses_anthropic_caching kind
  | None ->
      List.exists
        (fun label ->
           match model_label_provider_kind label with
           | Some kind -> provider_kind_uses_anthropic_caching kind
           | None -> false)
        [ model_used; resolved_model_id ]

let model_uses_anthropic_caching ~(model_used : string)
    ~(resolved_model_id : string) : bool =
  model_uses_anthropic_caching_with_provider_kind ~provider_kind:None
    ~model_used ~resolved_model_id

let is_trusted = function
  | Usage_trusted -> true
  | Usage_missing | Usage_untrusted _ -> false

let to_string = function
  | Usage_missing -> "missing"
  | Usage_trusted -> "trusted"
  | Usage_untrusted _ -> "untrusted"

let reasons = function
  | Usage_untrusted reasons -> reasons
  | Usage_missing | Usage_trusted -> []

let json_fields trust =
  [
    ("usage_trust", `String (to_string trust));
    ( "usage_anomaly",
      `Bool
        (match trust with
         | Usage_untrusted _ -> true
         | Usage_missing | Usage_trusted -> false) );
    ( "usage_anomaly_reasons",
      `List (List.map (fun reason -> `String reason) (reasons trust)) );
  ]

let add_reason reason reasons =
  if List.mem reason reasons then reasons else reason :: reasons

let classify_with_provider_kind ~provider_kind ~(usage_reported : bool)
    ~(usage : Oas.Types.api_usage)
    ~(model_used : string)
    ~(resolved_model_id : string)
    ~(context_max : int) : t =
  if not usage_reported then Usage_missing
  else
    let reasons = ref [] in
    let add reason = reasons := add_reason reason !reasons in
    let model_used = String.trim model_used in
    let resolved_model_id = String.trim resolved_model_id in
    let model_missing value = value = "" || String.equal value "unknown" in
    if model_missing model_used && model_missing resolved_model_id then
      add "missing_model_id";
    if usage.input_tokens < 0 then add "negative_input_tokens";
    if usage.output_tokens < 0 then add "negative_output_tokens";
    if usage.cache_creation_input_tokens < 0 then
      add "negative_cache_creation_tokens";
    if usage.cache_read_input_tokens < 0 then add "negative_cache_read_tokens";
    if usage.input_tokens = 0 && usage.output_tokens = 0 then
      add "zero_token_usage_reported";
    if usage.input_tokens > absurd_token_threshold then
      add "input_tokens_gt_1m";
    if usage.output_tokens > absurd_token_threshold then
      add "output_tokens_gt_1m";
    if context_max > 0 && usage.input_tokens > context_max * 2 then
      add "input_tokens_gt_2x_context_max";
    (* #9959 facet 1: Anthropic prompt caching silently disabled.
       claude_code:auto and similar Anthropic-routed models report
       [cache_creation_input_tokens = cache_read_input_tokens = 0]
       across every turn even though keeper system prompts run far
       above the minimum cacheable size.  This costs roughly 90%
       of the input-token bill the cache would otherwise eliminate.
       We classify it as an anomaly per turn whose input passes the
       cache-eligibility threshold; dashboards convert that into a
       per-keeper rate and alert when the rate is sustained
       (one-shot anomalies on tiny prompts are correctly noise). *)
    if
      model_uses_anthropic_caching_with_provider_kind ~provider_kind ~model_used
        ~resolved_model_id
      && usage.input_tokens >= anthropic_cache_min_input_tokens
      && usage.cache_creation_input_tokens = 0
      && usage.cache_read_input_tokens = 0
    then add "anthropic_caching_likely_disabled";
    match List.rev !reasons with
    | [] -> Usage_trusted
    | reasons -> Usage_untrusted reasons

let classify ~(usage_reported : bool)
    ~(usage : Oas.Types.api_usage)
    ~(model_used : string)
    ~(resolved_model_id : string)
    ~(context_max : int) : t =
  classify_with_provider_kind ~provider_kind:None ~usage_reported ~usage
    ~model_used ~resolved_model_id ~context_max
