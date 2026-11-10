(** Tool-metrics projection over the single SQLite store. *)

type hydrate_report = {
  loaded_records : int;
  pruned_records : int;
}

open Result.Syntax
let reset_for_testing = Tool_metrics_store.reset_for_testing

let sample_of_row (row : Tool_metrics_store.row) =
  let disposition =
    match row.disposition with
    | "completed" -> Ok Tool_metrics.Completed
    | "deferred" -> Ok Tool_metrics.Deferred
    | "failed" -> Ok Tool_metrics.Failed
    | value -> Error ("unknown persisted tool metric disposition: " ^ value)
  in
  let* disposition = disposition in
  Ok
    { Tool_metrics.tool_name = row.tool_name
    ; disposition
    ; duration_ms = row.duration_ms
    }

let announce_written ~base_path =
  Dashboard_observation_commit.written ~base_path ~scope:`Workspace `Tool_metrics

let enqueue ~base_path (result : Tool_result.result) =
  let masc_root = Common.masc_dir_from_base_path ~base_path in
  let row : Tool_metrics_store.row =
    { record_id = Random_id.uuid_v7 ()
    ; ts = Time_compat.now ()
    ; tool_name = Tool_result.tool_name result
    ; disposition = Tool_result.string_of_disposition result
    ; duration_ms = Tool_result.duration_ms result
    }
  in
  (* The size of the message the dispatcher returned. The keeper tool ledger's
     [result_bytes] is this same message's length. *)
  let result_bytes = String.length (Tool_result.message result) in
  let result = Fun.protect ~finally:(fun () -> announce_written ~base_path)
      (fun () -> Tool_metrics_store.insert ~masc_root ~result_bytes row) in
  (* An SQLite I/O failure can follow a visible commit. A read invalidation
     conveys no invented success and must not replace the write outcome. *)
  match result with
  | Ok () -> ()
  | Error error ->
    Otel_metric_store.inc_counter
      Otel_metric_store.metric_tool_metrics_persist_dropped
      ();
    Log.Metrics.warn "tool_metrics_persist: write failed: %s" error

let hydrate ~base_path ~retention_days =
  let masc_root = Common.masc_dir_from_base_path ~base_path in
  let pruned = Fun.protect ~finally:(fun () -> announce_written ~base_path)
      (fun () -> Tool_metrics_store.prune ~masc_root ~retention_days) in
  let* pruned_records = pruned in
  Tool_metrics.replace_samples (fun add ->
    let* loaded_records =
      Tool_metrics_store.iter_all ~masc_root ~f:(fun row ->
        let* sample = sample_of_row row in
        add sample;
        Ok ())
    in
    Ok { loaded_records; pruned_records })
