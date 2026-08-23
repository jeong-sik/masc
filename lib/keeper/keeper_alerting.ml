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

include Keeper_alerting_path
