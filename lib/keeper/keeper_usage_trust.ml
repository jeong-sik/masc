(** Shared trust classification for LLM usage telemetry.

    This module is intentionally independent of the unified keeper metrics
    pipeline so both unified turns and OAS after-turn hooks can apply the same
    guard before aggregating tokens, cost, or wall-clock tok/s. *)

type t =
  | Usage_missing
  | Usage_trusted
  | Usage_untrusted of string list

let absurd_token_threshold = 1_000_000

(* #9959: Anthropic prompt caching is enabled by default and reports
   cache hits/creates via [cache_creation_input_tokens] and
   [cache_read_input_tokens].  The production scan (1078 entries
   across 9 keepers / 24h) found these fields at exactly zero on
   100% of [claude_code:*] turns despite [input_tokens] regularly
   exceeding 100k — the threshold beyond which caching pays off and
   should be visible.  Treating this as a usage-trust anomaly gives
   operators one Prometheus counter to alert on instead of having
   to scan JSONL by hand.

   Floor of 10k input tokens: below this, cache may legitimately
   not engage (Anthropic caching has a minimum prompt size), so
   silence is not yet diagnostic.  Above 10k, every observed
   Anthropic turn should report at least some cache traffic over
   the lifetime of the keeper. *)
let anthropic_cache_floor_tokens = 10_000

let model_looks_anthropic ~model_used ~resolved_model_id =
  let probe s =
    let s = String.lowercase_ascii s in
    let has_prefix p =
      String.length s >= String.length p
      && String.sub s 0 (String.length p) = p
    in
    has_prefix "claude" || has_prefix "anthropic"
    || has_prefix "claude_code:" || has_prefix "anthropic:"
  in
  probe model_used || probe resolved_model_id

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

let classify ~(usage_reported : bool)
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
    (* #9959: Anthropic cache silence detector. *)
    if usage.input_tokens > anthropic_cache_floor_tokens
       && usage.cache_creation_input_tokens = 0
       && usage.cache_read_input_tokens = 0
       && model_looks_anthropic ~model_used ~resolved_model_id then
      add "anthropic_cache_silence";
    match List.rev !reasons with
    | [] -> Usage_trusted
    | reasons -> Usage_untrusted reasons
