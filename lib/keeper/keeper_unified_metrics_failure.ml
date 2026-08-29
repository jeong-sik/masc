(** Failure-path metric update for unified keeper cycle, extracted from
    keeper_unified_metrics.ml.

    Pure write-only side-effect: updates keeper_meta runtime fields
    based on a failure observation. *)

open Keeper_types
open Keeper_meta_contract
open Keeper_types_profile
open Keeper_context_runtime

include Keeper_unified_metrics_support
include Keeper_unified_metrics_json_support

let update_metrics_from_failure (meta : keeper_meta) ~(latency_ms : int)
    ~(observation : Keeper_world_observation.world_observation)
    ~(reason : string)
    ?core_error
    () : keeper_meta =
  let now_ts = Time_compat.now () in
  record_keeper_idle_seconds
    ~keeper_name:meta.name
    ~idle_seconds:observation.idle_seconds;
  let is_scheduled_autonomous_cycle =
    is_scheduled_autonomous_cycle_of_observation observation
  in
  let public_reason =
    match core_error with
    | Some err -> (
        match Keeper_turn_driver.classify_masc_internal_error err with
        | Some (Keeper_turn_driver.Resumable_cli_session { detail; _ }) ->
            let trimmed = String.trim detail in
            if trimmed = "" then reason else trimmed
        | Some (Keeper_turn_driver.Capacity_backpressure _ as err) ->
            Option.value
              ~default:reason
              (Keeper_turn_driver.summary_of_masc_internal_error err)
        | Some (Keeper_turn_driver.Runtime_exhausted _ as err) -> (
            match Keeper_turn_driver.summary_of_masc_internal_error err with
            | Some summary -> summary
            | None -> reason)
        | Some err ->
            Option.value
              ~default:reason
              (Keeper_turn_driver.summary_of_masc_internal_error err)
        | None -> reason)
    | None -> reason
  in
  if is_scheduled_autonomous_cycle then
    Otel_metric_store.inc_counter Keeper_metrics.(to_string ProactiveOutcome)
      ~labels:[ ("keeper", meta.name); ("outcome", "error") ]
      ();
  let preview =
    let trimmed = String.trim public_reason in
    if trimmed = "" then "keeper cycle failed"
    else short_preview trimmed
  in
  {
    meta with
    updated_at = now_iso ();
    runtime = { meta.runtime with
      usage = { meta.runtime.usage with
        total_turns = meta.runtime.usage.total_turns + 1;
        last_turn_ts = now_ts;
        (* A failed turn has no provider usage observation. Preserve the
           previous typed observation and its own timestamp. *)
        last_latency_ms = latency_ms;
      };
      proactive_rt = { meta.runtime.proactive_rt with
        count_total =
          meta.runtime.proactive_rt.count_total
          + (if is_scheduled_autonomous_cycle then 1 else 0);
        (* Always update last_ts on scheduled_autonomous attempts,
           including transient errors. Without this, transient errors
           (e.g. llama-server down) leave last_ts stale, causing
           cooldown_elapsed=false permanently → scheduled turns never
           resume. last_ts tracks attempts, not successes.
           Root cause of keeper zombie state: #5594. *)
        last_ts =
          if is_scheduled_autonomous_cycle then now_ts
          else meta.runtime.proactive_rt.last_ts;
        last_outcome =
          if is_scheduled_autonomous_cycle then Proactive_error
          else meta.runtime.proactive_rt.last_outcome;
        last_reason =
          if is_scheduled_autonomous_cycle
          then "unified:error:" ^ String.trim public_reason
          else meta.runtime.proactive_rt.last_reason;
        last_preview =
          if is_scheduled_autonomous_cycle then preview
          else meta.runtime.proactive_rt.last_preview;
      };
    };
  }
