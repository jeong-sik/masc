(* keeper_heartbeat_snapshot — heartbeat snapshot write and stage timing
   metrics.

   Extracted from keeper_keepalive.ml. The [write_heartbeat_snapshot]
   function is the primary heartbeat status persistence path, reading
   context from checkpoint and appending observations to the metrics ledger. *)

open Keeper_types
open Keeper_meta_contract
open Keeper_types_profile
open Keeper_execution

let keepalive_interval_sec () =
  Runtime_params.get Runtime_settings.keeper_keepalive_interval_sec
;;

let write_heartbeat_snapshot
      ~(ctx : _ context)
      ~(meta_current : keeper_meta)
      ~(now_ts : float)
      ~(timing_ring : Keeper_keepalive_signal.stage_timing array)
      ~(timing_filled : int)
  : unit
  =
  let metrics_store =
    Keeper_types_support.keeper_metrics_store ctx.config meta_current.name
  in
  let runtime_models =
    Provider_runtime_projection.default_execution_model_strings
      ((Keeper_meta_contract.runtime_id_of_meta meta_current))
  in
  let max_runtime_context =
    let resolution =
      Keeper_context_runtime.resolve_max_context_resolution
        ~requested_override:meta_current.max_context_override
        runtime_models
    in
    resolution.effective_budget
  in
  let base_dir = session_base_dir ctx.config in
  ignore (Keeper_fs.ensure_dir (Filename.concat base_dir (Keeper_id.Trace_id.to_string meta_current.runtime.trace_id)));
  let _session, ctx_opt =
    load_context_from_checkpoint
      ~trace_id:(Keeper_id.Trace_id.to_string meta_current.runtime.trace_id)
      ~primary_model_max_tokens:max_runtime_context
      ~base_dir
  in
  let message_count =
    Option.map Keeper_context_runtime.message_count ctx_opt
  in
    let snapshot =
      `Assoc
        [ "ts", `String (now_iso ())
        ; "ts_unix", `Float now_ts
        ; "channel", `String "heartbeat"
        ; "name", `String meta_current.name
        ; "agent_name", `String meta_current.agent_name
        ; "trace_id", `String (Keeper_id.Trace_id.to_string meta_current.runtime.trace_id)
        ; "generation", `Int meta_current.runtime.generation
        ; ( "message_count"
          , Json_util.option_to_yojson (fun count -> `Int count) message_count )
        ; "compacted", `Bool false
        ; "work_kind", `String "status_tick"
        ; "snapshot_source", `String "keeper_context_status"
        ; "memory_check", memory_check_default_json ()
        ; "handoff", `Assoc [ "performed", `Bool false ]
        ; "stage_timing", Keeper_keepalive_signal.stage_timing_to_json ~ring:timing_ring ~count:timing_filled
        ]
    in
    Dated_jsonl.append metrics_store snapshot;
    (try
       let json =
         `Assoc
           [ "type", `String "keeper_heartbeat"
           ; "name", `String meta_current.name
           ; "generation", `Int meta_current.runtime.generation
           ; "ts_unix", `Float now_ts
           ]
       in
       Sse.broadcast json;
       Sse.broadcast_presence json
     with
     | Eio.Cancel.Cancelled _ as e -> raise e
     | exn ->
       Otel_metric_store.inc_counter
         Keeper_metrics.(to_string SseBroadcastFailures)
         ~labels:[("keeper", meta_current.name)]
         ();
       Log.Keeper.error "heartbeat SSE broadcast failed: %s" (Printexc.to_string exn));
    (try
       Keeper_registry_tool_usage_persistence.flush ~base_path:ctx.config.base_path meta_current.name
     with
     | Eio.Cancel.Cancelled _ as e -> raise e
     | exn ->
       Otel_metric_store.inc_counter
         Keeper_metrics.(to_string HeartbeatFailures)
         ~labels:[("keeper", meta_current.name); ("site", "flush_tool_usage")]
         ();
       Log.Keeper.warn ~keeper_name:meta_current.name "flush_tool_usage failed: %s"
         (Printexc.to_string exn))
;;
