(** Reasoning_dialect — OAS reasoning control library (P3-1). *)

open Llm_provider.Provider_config

type provider_kind = Llm_provider.Provider_config.provider_kind

type dialect =
  | No_reasoning
  | Openai_o1 of { reasoning_effort : string }
  | Anthropic_extended of { budget_tokens : int option }
  | Kimi_thinking of { budget_tokens : int option }
  | Generic_thinking of { budget_tokens : int option }

type replay_policy =
  | Include
  | Exclude
  | Summarize

type continuation_boundary =
  | Stop_at_tool_call
  | Stop_at_turn_end
  | No_boundary

type t =
  { dialect : dialect
  ; provider : provider_kind
  ; model_id : string
  ; supports_reasoning : bool
  ; continuation_boundary : continuation_boundary
  ; replay_policy : replay_policy
  }

let openai_reasoning_effort model_id =
  (* o1-series model ids may carry suffixes such as o1-preview or
     o1-mini. The effort knob is model-family-level for now. *)
  if String.starts_with ~prefix:"o1-mini" model_id then "low"
  else if String.starts_with ~prefix:"o1-preview" model_id then "high"
  else "medium"
;;

let classify ~provider ~(model_id : string) ~enable_thinking ~thinking_budget =
  match provider with
  | Anthropic when Option.is_some enable_thinking ->
    Anthropic_extended { budget_tokens = thinking_budget }
  | Kimi when Option.is_some enable_thinking ->
    Kimi_thinking { budget_tokens = thinking_budget }
  | OpenAI_compat when String.starts_with ~prefix:"o1" model_id ->
    Openai_o1 { reasoning_effort = openai_reasoning_effort model_id }
  | _ ->
    if Option.is_some enable_thinking
    then Generic_thinking { budget_tokens = thinking_budget }
    else No_reasoning
;;

let default_boundary = function
  | No_reasoning -> No_boundary
  | Openai_o1 _ -> Stop_at_tool_call
  | Anthropic_extended _ -> Stop_at_tool_call
  | Kimi_thinking _ -> Stop_at_turn_end
  | Generic_thinking _ -> Stop_at_tool_call
;;

let replay_policy_of_config ~supports_reasoning ~preserve_thinking =
  match preserve_thinking with
  | Some true -> Include
  | Some false -> Exclude
  | None -> if supports_reasoning then Summarize else Exclude
;;

let of_provider_config (cfg : Llm_provider.Provider_config.t) =
  let dialect =
    classify ~provider:cfg.kind ~model_id:cfg.model_id
      ~enable_thinking:cfg.enable_thinking
      ~thinking_budget:cfg.thinking_budget
  in
  let supports_reasoning =
    match dialect with
    | No_reasoning -> false
    | _ -> true
  in
  { dialect
  ; provider = cfg.kind
  ; model_id = cfg.model_id
  ; supports_reasoning
  ; continuation_boundary = default_boundary dialect
  ; replay_policy =
      replay_policy_of_config ~supports_reasoning
        ~preserve_thinking:cfg.preserve_thinking
  }
;;
