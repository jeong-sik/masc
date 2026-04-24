(** Shared trust classification for LLM usage telemetry.

    This module is intentionally independent of the unified keeper metrics
    pipeline so both unified turns and OAS after-turn hooks can apply the same
    guard before aggregating tokens, cost, or wall-clock tok/s. *)

type t =
  | Usage_missing
  | Usage_trusted
  | Usage_untrusted of string list

let absurd_token_threshold = 1_000_000

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
    match List.rev !reasons with
    | [] -> Usage_trusted
    | reasons -> Usage_untrusted reasons
