(** Tool-metrics projection over the single SQLite store. *)

type hydrate_report = {
  loaded_records : int;
  pruned_records : int;
}

type store_summary = Tool_metrics_store.summary = {
  path : string;
  exists : bool;
  entry_count : int;
  latest_ts : float option;
}

let ( let* ) = Result.bind
let database_path = Tool_metrics_store.database_path
let store_summary = Tool_metrics_store.summary
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

let enqueue ~base_path (result : Tool_result.result) =
  let row : Tool_metrics_store.row =
    { record_id = Random_id.uuid_v7 ()
    ; ts = Time_compat.now ()
    ; tool_name = Tool_result.tool_name result
    ; disposition = Tool_result.string_of_disposition result
    ; duration_ms = Tool_result.duration_ms result
    }
  in
  match Tool_metrics_store.insert ~base_path row with
  | Ok () -> ()
  | Error error ->
    Otel_metric_store.inc_counter
      Otel_metric_store.metric_tool_metrics_persist_dropped
      ();
    Log.Metrics.warn "tool_metrics_persist: write failed: %s" error

let hydrate ~base_path ~retention_days =
  let* pruned_records =
    Tool_metrics_store.prune ~base_path ~retention_days
  in
  Tool_metrics.replace_samples (fun add ->
    let* loaded_records =
      Tool_metrics_store.iter_all ~base_path ~f:(fun row ->
        let* sample = sample_of_row row in
        add sample;
        Ok ())
    in
    Ok { loaded_records; pruned_records })

let read_recent ~base_path ?since_ts ?until_ts ~n () =
  Result.map
    (List.map Tool_metrics_store.row_to_json)
    (Tool_metrics_store.read_recent
       ~base_path
       ?since_ts
       ?until_ts
       ~n
       ())
