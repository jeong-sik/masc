(** Keeper_alerting -- skill routing, path safety checks, and tool-call
    preparation helpers for keeper execution.

    This module intentionally does not score or fan out "interesting" alerts.
    Keeper/operator escalation must come from typed runtime facts or an explicit
    LLM/Fusion boundary, not keyword weights or numeric heuristics. *)

let keeper_model_tools = Tool_shard.keeper_model_tools

let merge_usage
    (a : Agent_sdk.Types.api_usage)
    (b : Agent_sdk.Types.api_usage) : Agent_sdk.Types.api_usage =
  {
    Agent_sdk.Types.input_tokens = a.input_tokens + b.input_tokens;
    output_tokens = a.output_tokens + b.output_tokens;
    cache_creation_input_tokens =
      a.cache_creation_input_tokens + b.cache_creation_input_tokens;
    cache_read_input_tokens = a.cache_read_input_tokens + b.cache_read_input_tokens;
    cost_usd =
      (match a.cost_usd, b.cost_usd with
       | Some x, Some y -> Some (x +. y)
       | Some x, None | None, Some x -> Some x
       | None, None -> None);
  }

include Keeper_skill_routing
include Keeper_alerting_path
