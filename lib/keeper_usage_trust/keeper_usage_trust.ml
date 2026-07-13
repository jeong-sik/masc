(** Shared trust classification for LLM usage telemetry.

    This module validates provider-reported usage shape without inferring
    provider/model-specific behavior. Concrete runtime identity and capability
    semantics belong to OAS. *)

type t =
  | Usage_missing
  | Usage_trusted
  | Usage_untrusted of string list

let to_string = function
  | Usage_missing -> "missing"
  | Usage_trusted -> "trusted"
  | Usage_untrusted _ -> "untrusted"

let reasons = function
  | Usage_untrusted reasons -> reasons
  | Usage_missing | Usage_trusted -> []

let warns_operator = function
  | Usage_missing | Usage_trusted -> false
  | Usage_untrusted _ -> true

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
    ~(usage : Agent_sdk.Types.api_usage) : t =
  if not usage_reported then Usage_missing
  else
    let reasons = ref [] in
    let add reason = reasons := add_reason reason !reasons in
    if usage.input_tokens < 0 then add "negative_input_tokens";
    if usage.output_tokens < 0 then add "negative_output_tokens";
    if usage.cache_creation_input_tokens < 0 then
      add "negative_cache_creation_tokens";
    if usage.cache_read_input_tokens < 0 then add "negative_cache_read_tokens";
    match List.rev !reasons with
    | [] -> Usage_trusted
    | reasons -> Usage_untrusted reasons
