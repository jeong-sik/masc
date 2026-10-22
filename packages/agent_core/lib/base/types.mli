(** Base types for Agent Core.

    LLM-level types (role, message, content_block, etc.) are re-exported from
    {!Llm_provider.Types}. Agent-specific types remain local.

    @stability Stable
    @since 0.93.1 *)

(* ================================================================ *)
(* Re-export all LLM provider types                                  *)
(* ================================================================ *)
include module type of struct
  include Llm_provider.Types
end

(* ================================================================ *)
(* AGENT_CORE-specific additions                                            *)
(* ================================================================ *)

val tool_choice_of_json : Yojson.Safe.t -> (tool_choice, Error.t) result
val response_format_of_json : Yojson.Safe.t -> (response_format, Error.t) result

(* ================================================================ *)
(* Agent-specific types                                              *)
(* ================================================================ *)

(** Exact provider model identifier. AGENT_CORE performs no implicit alias expansion
    or ambient default selection. *)
type model = string [@@deriving yojson, show]

(** Project an exact model identifier to its wire representation. *)
val model_to_string : model -> string

(** Agent configuration *)
type agent_config =
  { name : string
  ; model : model
  ; system_prompt : string option
  ; max_tokens : int option
  ; temperature : float option
  ; top_p : float option
  ; top_k : int option
  ; min_p : float option
  ; enable_thinking : bool option
  ; preserve_thinking : bool option
  ; response_format : response_format
  ; reasoning_effort : Llm_provider.Reasoning_effort.t option
  ; tool_choice : tool_choice option
  ; disable_parallel_tool_use : bool
  ; cache_system_prompt : bool
  ; cache_extended_ttl : bool
    (** When [true] and [cache_system_prompt = true], sets the Anthropic
      prompt cache TTL to 1 hour instead of the default 5 minutes.
      Write cost is 2x but the cache persists 12x longer — intended
      for long-running agents that go idle 5+ minutes between turns.
      @since 0.151.0 *)
  ; initial_messages : message list
  ; yield_on_tool : bool
  ; max_tool_rounds : int option
    (** Release provider capacity before tool execution. @since 0.100.0 *)
  }
[@@deriving show]

(** Build the non-model defaults around an exact caller-selected model.
    There is deliberately no ambient or compile-time model fallback. *)
val default_config : model:model -> agent_config

type pricing_gap =
  | Usage_not_reported
  | Model_identity_unavailable
  | Pricing_unavailable of string
[@@deriving show]

(** Subtotals over processed provider responses, not all dispatched attempts.
    Per-response usage stays in {!Llm_provider.Types.api_usage}.
    [missing_usage_responses] counts responses with no usage payload. Those
    responses advance [api_calls] without adding fabricated zero measurements.
    A zero missing count establishes payload coverage only: the legacy integer
    per-response counters still cannot establish per-field reporting provenance.
    [pricing_gap] retains the first cost gap; inspect the independent missing
    count too, since later absent payloads can coexist with a pricing gap.
    Amounts are telemetry subtotals, not complete bills or execution gates. *)
type usage_stats =
  { total_input_tokens : int
  ; total_output_tokens : int
  ; total_cache_creation_input_tokens : int
  ; total_cache_read_input_tokens : int
  ; api_calls : int
  ; missing_usage_responses : int
  ; estimated_cost_usd : float
  ; pricing_gap : pricing_gap option
  }
[@@deriving show]

val empty_usage : usage_stats
val add_usage : usage_stats -> api_usage -> usage_stats
val add_missing_usage : usage_stats -> usage_stats
(** Record one processed response with no usage payload, preserving all known
    subtotals and prior pricing diagnostics. Empty aggregation has zero calls
    and zero missing payloads; one missing response is an incomplete zero. *)

(** Agent state *)
type agent_state =
  { config : agent_config
  ; messages : message list
  ; turn_count : int
  ; usage : usage_stats
  }
[@@deriving show]
