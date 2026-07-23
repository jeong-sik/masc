(** Keeper_alerting — path safety checks for keeper execution.

    The keeper alert fanout layer (board/Slack/Slack-DM/GitHub senders,
    retry+dedup machinery) was removed here: its sole caller
    [maybe_emit_interesting_alert] and the keyword-weight scorer
    [keeper_alert_signal] were deleted in #23929 (heuristic-scoring
    purge), leaving the fanout senders with zero call sites. See masc
    issue #54 (Settings→Notify write path) for the replacement design —
    browser-side delivery over the dashboard's existing typed SSE
    stream, not a resurrected server-side heuristic emitter. *)

open Keeper_types
open Keeper_meta_contract
open Keeper_types_profile
open Keeper_memory

let keeper_model_tools = Tool_shard.keeper_model_tools

let merge_usage
    (a : Agent_sdk.Types.api_usage)
    (b : Agent_sdk.Types.api_usage) : Agent_sdk.Types.api_usage =
  { Agent_sdk.Types.input_tokens = a.input_tokens + b.input_tokens;
    output_tokens = a.output_tokens + b.output_tokens;
    cache_creation_input_tokens =
      a.cache_creation_input_tokens + b.cache_creation_input_tokens;
    cache_read_input_tokens =
      a.cache_read_input_tokens + b.cache_read_input_tokens;
    cost_usd =
      (match a.cost_usd, b.cost_usd with
       | Some x, Some y -> Some (x +. y)
       | Some x, None | None, Some x -> Some x
       | None, None -> None) }

include Keeper_alerting_path
