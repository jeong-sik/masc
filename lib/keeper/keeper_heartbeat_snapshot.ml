(* keeper_heartbeat_snapshot — heartbeat snapshot write and stage timing
   metrics.

   Extracted from keeper_keepalive.ml. The [write_heartbeat_snapshot]
   function is the primary heartbeat status persistence path, reading
   context from checkpoint and appending observations to the metrics ledger. *)

open Keeper_types
open Keeper_meta_contract
open Keeper_types_profile

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
  let base_dir = session_base_dir ctx.config in
  let session_id = Keeper_id.Trace_id.to_string meta_current.runtime.trace_id in
  let session_dir = Filename.concat base_dir session_id in
  (* RFC main-domain-scheduler-latency §8 P4b: the count comes from the
     store's canonical summary while the file on disk is the one the summary
     was taken from, so a heartbeat no longer reads and parses the whole
     checkpoint (13-20 MB per keeper, every keepalive interval) for one
     integer. *)
  let message_count =
    match
      Keeper_checkpoint_store.canonical_message_count ~session_dir ~session_id
    with
    | Ok count -> count
    | Error Keeper_checkpoint_store.Not_found -> None
    | Error
        Keeper_checkpoint_store.(
          Store_error detail | Parse_error detail | Io_error detail | Agent_core_error detail)
      ->
      Log.Keeper.warn
        "keeper:%s heartbeat message count unavailable: %s"
        session_id
        detail;
      None
  in
    let snapshot =
      `Assoc
        (Keeper_metrics_record.fields Keeper_metrics_record.Heartbeat
        @ [ "ts", `String (now_iso ())
        ; "ts_unix", `Float now_ts
        ; "channel", `String "heartbeat"
        ; "name", `String meta_current.name
        ; "trace_id", `String (Keeper_id.Trace_id.to_string meta_current.runtime.trace_id)
        ; ( "message_count"
          , Json_util.option_to_yojson (fun count -> `Int count) message_count )
        ; "stage_timing", Keeper_keepalive_signal.stage_timing_to_json ~ring:timing_ring ~count:timing_filled
        ])
    in
    Dated_jsonl.append metrics_store snapshot;
    (try
       let json =
         `Assoc
           [ "type", `String "keeper_heartbeat"
           ; "name", `String meta_current.name
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
