(** Durable stale-paused metadata cleanup.

    The supervisor owns only the staleness policy decision. Once selected, an
    exact meta-version guard and Keeper admission fence move every destructive
    effect into [Keeper_shutdown_finalize]. *)

open Keeper_shutdown_types
open Keeper_shutdown_prepare_join

let record_failure keeper_name site =
  Otel_metric_store.inc_counter
    Keeper_metrics.(to_string SupervisorCleanupFailures)
    ~labels:
      [ "keeper", keeper_name
      ; ( "site"
        , Keeper_supervisor_cleanup_failure_site.to_label site )
      ]
    ()
;;

let report_meta_read_failure ~keeper_name detail =
  record_failure
    keeper_name
    Keeper_supervisor_cleanup_failure_site.Paused_meta_read;
  Log.Keeper.error
    "%s: stale paused metadata read failed during prune selection: %s"
    keeper_name
    detail
;;

let submit
    (ctx : _ Keeper_types_profile.context)
    (meta : Keeper_meta_contract.keeper_meta)
  =
  let cleanup_intent : Keeper_shutdown_types.cleanup_intent =
    { reason =
        Stale_paused_prune
          { meta_version = meta.meta_version
          ; last_updated = meta.updated_at
          ; latched_reason = meta.latched_reason
          }
    ; remove_session = false
    }
  in
  let request : Keeper_shutdown_prepare_join.request =
    { actor = ctx.agent_name
    ; cleanup_intent
    }
  in
  let result =
    match Keeper_registry.get ~base_path:ctx.config.base_path meta.name with
    | Some entry ->
      Keeper_shutdown_runtime.submit ~config:ctx.config ~entry ~request
    | None ->
      Keeper_shutdown_runtime.submit_dormant
        ~config:ctx.config
        ~meta
        ~request
  in
  match result with
  | Ok operation ->
    Log.Keeper.info
      "%s: stale paused meta prune accepted operation=%s"
      meta.name
      (Keeper_shutdown_types.Operation_id.to_string operation.operation_id)
  | Error error ->
    record_failure
      meta.name
      Keeper_supervisor_cleanup_failure_site.Paused_meta_prune_submission;
    Log.Keeper.error
      "%s: stale paused meta prune submission failed: %s"
      meta.name
      (Keeper_shutdown_runtime.submit_error_to_string error)
;;
