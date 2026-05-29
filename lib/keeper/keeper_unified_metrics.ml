(** Keeper_unified_metrics — Observation helpers, decision records, and
    metrics update for the unified keeper cycle.

    Extracted from keeper_unified_turn.ml to reduce godfile size.
    All functions here are pure or write-only (JSONL/SSE); no keeper
    lifecycle state is owned by this module.

    @since 0.120.0 *)

open Keeper_types
open Keeper_meta_contract
open Keeper_types_profile
open Keeper_context_runtime
module Social = Keeper_social_model

include Keeper_unified_metrics_support
include Keeper_unified_metrics_json_support


let append_decision_record = Keeper_unified_metrics_decision.append_decision_record
let update_metrics_from_result = Keeper_unified_metrics_result.update_metrics_from_result
let append_metrics_snapshot = Keeper_unified_metrics_snapshot.append_metrics_snapshot
let broadcast_lifecycle_events =
  Keeper_unified_metrics_broadcast.broadcast_lifecycle_events
let update_metrics_from_failure = Keeper_unified_metrics_failure.update_metrics_from_failure
