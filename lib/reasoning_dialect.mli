(** Reasoning_dialect — OAS reasoning control library (P3-1).

    Maps a provider configuration to a provider/model-specific reasoning
    dialect, a continuation boundary policy, and a replay policy.  This is
    the registry-style layer called by caller sites that need to know
    whether and how reasoning traces should be produced, persisted, and
    replayed. *)

type provider_kind = Llm_provider.Provider_config.provider_kind

(** Provider/model reasoning dialect. *)
type dialect =
  | No_reasoning
  | Openai_o1 of { reasoning_effort : string }
  | Anthropic_extended of { budget_tokens : int option }
  | Kimi_thinking of { budget_tokens : int option }
  | Generic_thinking of { budget_tokens : int option }

(** Whether reasoning traces may be replayed into later contexts. *)
type replay_policy =
  | Include
  | Exclude
  | Summarize

(** When a reasoning pass should hand control back to the caller. *)
type continuation_boundary =
  | Stop_at_tool_call
  | Stop_at_turn_end
  | No_boundary

(** Resolved reasoning control for a provider configuration. *)
type t =
  { dialect : dialect
  ; provider : provider_kind
  ; model_id : string
  ; supports_reasoning : bool
  ; continuation_boundary : continuation_boundary
  ; replay_policy : replay_policy
  }

val of_provider_config : Llm_provider.Provider_config.t -> t
(** Resolve the reasoning dialect and policies from a provider config.
    Pure: no IO, no side effects. *)
