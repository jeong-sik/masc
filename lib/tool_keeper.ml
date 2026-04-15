(** Keeper tools are scoped to the caller's current base_path.
    Do not retarget requests across other base_path registries. *)
let resolve_ctx ctx ~name:_ _args = ctx

let handle_keeper_reset ctx args : tool_result =
  match resolve_keeper_meta ctx args with
  | Error err -> error_result_typed ~code:Validation_error err
  | Ok meta ->
    let reset_met = Keeper_types.reset_runtime_state meta in
    let json = Keeper_types.keeper_meta_to_yojson reset_met in
    (true, Yojson.Safe.pretty_to_string json)

let execute_keeper_up ctx args : tool_result =
  let ok, body = Turn.handle_keeper_up ctx args in
  if not ok then (ok, body)
  else
    let json =
      try Yojson.Safe.from_string body with Yojson.Json_error _ -> `String body
    in
    invalidate_keeper_list_cache ();
    Keeper_status_detail.invalidate_status_cache_for (get_string args "name" "");
    (true,
     Yojson.Safe.pretty_to_string
       (annotate_keeper_json ~runtime_class:"keeper" json))

let handle_keeper_up ctx args : tool_result =
  let state = Server_startup_state.(!state) in
  if not state.state_ready then begin
    let elapsed = Server_startup_state.elapsed_since_start () in
    Log.Keeper.warn "keeper_up rejected: server not ready (%.1fs since start)" elapsed;
    error_result_typed ~code:Service_unavailable (Printf.sprintf "Server not ready (%.1fs since start)" elapsed)
  end else
    execute_keeper_up ctx args

let handle_keeper_status ctx args : tool_result =
  match resolve_keeper_meta ctx args with
  | Error err -> error_result_typed ~code:Validation_error err
  | Ok meta ->
    let status = Keeper_types.keeper_status_detail meta in
    let json = Keeper_types.keeper_status_detail_to_yojson status in
    (true, Yojson.Safe.pretty_to_string json)

let handle_keeper_list ctx _args : tool_result =
  let keepers = Keeper_types.list_keeper_metas ctx in
  let json = `List (List.map Keeper_types.keeper_meta_to_yojson keepers) in
  (true, Yojson.Safe.pretty_to_string json)

let handle_keeper_heartbeat ctx args : tool_result =
  match resolve_keeper_meta ctx args with
  | Error err -> error_result_typed ~code:Validation_error err
  | Ok meta ->
    let updated = Keeper_types.update_heartbeat meta in
    let json = Keeper_types.keeper_meta_to_yojson updated in
    (true, Yojson.Safe.pretty_to_string json)

let handle_keeper_checkpoint ctx args : tool_result =
  match resolve_keeper_meta ctx args with
  | Error err -> error_result_typed ~code:Validation_error err
  | Ok meta ->
    let checkpoint = Keeper_types.get_checkpoint meta in
    let json = Keeper_types.checkpoint_to_yojson checkpoint in
    (true, Yojson.Safe.pretty_to_string json)

let handle_keeper_reconcile ctx args : tool_result =
  match resolve_keeper_meta ctx args with
  | Error err -> error_result_typed ~code:Validation_error err
  | Ok meta ->
    let reconciled = Keeper_types.reconcile_state meta in
    let json = Keeper_types.keeper_meta_to_yojson reconciled in
    (true, Yojson.Safe.pretty_to_string json)

let handle_keeper_pause ctx args : tool_result =
  match resolve_keeper_meta ctx args with
  | Error err -> error_result_typed ~code:Validation_error err
  | Ok meta ->
    let paused = Keeper_types.set_paused meta true in
    let json = Keeper_types.keeper_meta_to_yojson paused in
    (true, Yojson.Safe.pretty_to_string json)

let handle_keeper_resume ctx args : tool_result =
  match resolve_keeper_meta ctx args with
  | Error err -> error_result_typed ~code:Validation_error err
  | Ok meta ->
    let resumed = Keeper_types.set_paused meta false in
    let json = Keeper_types.keeper_meta_to_yojson resumed in
    (true, Yojson.Safe.pretty_to_string json)

let handle_keeper_delete ctx args : tool_result =
  match resolve_keeper_meta ctx args with
  | Error err -> error_result_typed ~code:Validation_error err
  | Ok meta ->
    Keeper_types.delete_keeper meta;
    (true, ok_response "Keeper deleted")

let handle_keeper_export ctx args : tool_result =
  match resolve_keeper_meta ctx args with
  | Error err -> error_result_typed ~code:Validation_error err
  | Ok meta ->
    let export = Keeper_types.export_keeper meta in
    let json = Keeper_types.keeper_export_to_yojson export in
    (true, Yojson.Safe.pretty_to_string json)

let handle_keeper_import ctx args : tool_result =
  let json_str = get_string args "data" "" in
  try
    let json = Yojson.Safe.from_string json_str in
    match Keeper_types.keeper_export_of_yojson json with
    | Ok export ->
      let meta = Keeper_types.import_keeper ctx export in
      let json = Keeper_types.keeper_meta_to_yojson meta in
      (true, Yojson.Safe.pretty_to_string json)
    | Error e -> error_result_typed ~code:Invalid_argument e
  with Yojson.Json_error e ->
    error_result_typed ~code:Invalid_argument (Printf.sprintf "JSON parse error: %s" e)

let handle_keeper_validate ctx args : tool_result =
  match resolve_keeper_meta ctx args with
  | Error err -> error_result_typed ~code:Validation_error err
  | Ok meta ->
    let validation = Keeper_types.validate_keeper meta in
    let json = Keeper_types.validation_result_to_yojson validation in
    (true, Yojson.Safe.pretty_to_string json)

let handle_keeper_repair ctx args : tool_result =
  match resolve_keeper_meta ctx args with
  | Error err -> error_result_typed ~code:Validation_error err
  | Ok meta ->
    let repaired = Keeper_types.repair_keeper meta in
    let json = Keeper_types.keeper_meta_to_yojson repaired in
    (true, Yojson.Safe.pretty_to_string json)

let handle_keeper_stats ctx args : tool_result =
  match resolve_keeper_meta ctx args with
  | Error err -> error_result_typed ~code:Validation_error err
  | Ok meta ->
    let stats = Keeper_types.compute_stats meta in
    let json = Keeper_types.keeper_stats_to_yojson stats in
    (true, Yojson.Safe.pretty_to_string json)

let handle_keeper_logs ctx args : tool_result =
  match resolve_keeper_meta ctx args with
  | Error err -> error_result_typed ~code:Validation_error err
  | Ok meta ->
    let limit = get_int args "limit" 100 in
    let logs = Keeper_types.get_logs meta ~limit in
    let json = `List (List.map Keeper_types.log_entry_to_yojson logs) in
    (true, Yojson.Safe.pretty_to_string json)

let handle_keeper_alerts ctx args : tool_result =
  match resolve_keeper_meta ctx args with
  | Error err -> error_result_typed ~code:Validation_error err
  | Ok meta ->
    let alerts = Keeper_types.get_alerts meta in
    let json = `List (List.map Keeper_types.alert_to_yojson alerts) in
    (true, Yojson.Safe.pretty_to_string json)

let handle_keeper_config ctx args : tool_result =
  match resolve_keeper_meta ctx args with
  | Error err -> error_result_typed ~code:Validation_error err
  | Ok meta ->
    let config = Keeper_types.get_config meta in
    let json = Keeper_types.keeper_config_to_yojson config in
    (true, Yojson.Safe.pretty_to_string json)

let handle_keeper_set_config ctx args : tool_result =
  match resolve_keeper_meta ctx args with
  | Error err -> error_result_typed ~code:Validation_error err
  | Ok meta ->
    let config_json_str = get_string args "config" "" in
    try
      let config_json = Yojson.Safe.from_string config_json_str in
      match Keeper_types.keeper_config_of_yojson config_json with
      | Ok config ->
        let updated = Keeper_types.set_config meta config in
        let json = Keeper_types.keeper_meta_to_yojson updated in
        (true, Yojson.Safe.pretty_to_string json)
      | Error e -> error_result_typed ~code:Invalid_argument e
    with Yojson.Json_error e ->
      error_result_typed ~code:Invalid_argument (Printf.sprintf "JSON parse error: %s" e)

let handle_keeper_notify ctx args : tool_result =
  match resolve_keeper_meta ctx args with
  | Error err -> error_result_typed ~code:Validation_error err
  | Ok meta ->
    let message = get_string args "message" "" in
    let level = get_string args "level" "info" in
    Keeper_types.send_notification meta ~level message;
    (true, ok_response "Notification sent")

let handle_keeper_broadcast ctx args : tool_result =
  let message = get_string args "message" "" in
  let level = get_string args "level" "info" in
  Keeper_types.broadcast_notification ~level message;
  (true, ok_response "Broadcast sent")

let handle_keeper_query ctx args : tool_result =
  let query = get_string args "query" "" in
  try
    let results = Keeper_types.query_keepers ctx query in
    let json = `List (List.map Keeper_types.keeper_meta_to_yojson results) in
    (true, Yojson.Safe.pretty_to_string json)
  with e ->
    error_result_typed ~code:Invalid_argument (Printexc.to_string e)

let handle_keeper_search ctx args : tool_result =
  let pattern = get_string args "pattern" "" in
  try
    let results = Keeper_types.search_keepers ctx pattern in
    let json = `List (List.map Keeper_types.keeper_meta_to_yojson results) in
    (true, Yojson.Safe.pretty_to_string json)
  with e ->
    error_result_typed ~code:Invalid_argument (Printexc.to_string e)

let handle_keeper_filter ctx args : tool_result =
  let filter_json_str = get_string args "filter" "" in
  try
    let filter_json = Yojson.Safe.from_string filter_json_str in
    let results = Keeper_types.filter_keepers ctx filter_json in
    let json = `List (List.map Keeper_types.keeper_meta_to_yojson results) in
    (true, Yojson.Safe.pretty_to_string json)
  with Yojson.Json_error e ->
    error_result_typed ~code:Invalid_argument (Printf.sprintf "JSON parse error: %s" e)

let handle_keeper_aggregate ctx args : tool_result =
  let agg_json_str = get_string args "aggregation" "" in
  try
    let agg_json = Yojson.Safe.from_string agg_json_str in
    let result = Keeper_types.aggregate_keepers ctx agg_json in
    (true, Yojson.Safe.pretty_to_string result)
  with Yojson.Json_error e ->
    error_result_typed ~code:Invalid_argument (Printf.sprintf "JSON parse error: %s" e)

let handle_keeper_batch ctx args : tool_result =
  let batch_json_str = get_string args "batch" "" in
  try
    let batch_json = Yojson.Safe.from_string batch_json_str in
    let results = Keeper_types.batch_operation ctx batch_json in
    let json = `List results in
    (true, Yojson.Safe.pretty_to_string json)
  with Yojson.Json_error e ->
    error_result_typed ~code:Invalid_argument (Printf.sprintf "JSON parse error: %s" e)

let handle_keeper_transaction ctx args : tool_result =
  let txn_json_str = get_string args "transaction" "" in
  try
    let txn_json = Yojson.Safe.from_string txn_json_str in
    let result = Keeper_types.execute_transaction ctx txn_json in
    (true, Yojson.Safe.pretty_to_string result)
  with Yojson.Json_error e ->
    error_result_typed ~code:Invalid_argument (Printf.sprintf "JSON parse error: %s" e)

let handle_keeper_rollback ctx args : tool_result =
  let txn_id = get_string args "transaction_id" "" in
  try
    Keeper_types.rollback_transaction ctx txn_id;
    (true, ok_response "Transaction rolled back")
  with e ->
    error_result_typed ~code:Invalid_argument (Printexc.to_string e)

let handle_keeper_commit ctx args : tool_result =
  let txn_id = get_string args "transaction_id" "" in
  try
    Keeper_types.commit_transaction ctx txn_id;
    (true, ok_response "Transaction committed")
  with e ->
    error_result_typed ~code:Invalid_argument (Printexc.to_string e)

let handle_keeper_snapshot ctx args : tool_result =
  match resolve_keeper_meta ctx args with
  | Error err -> error_result_typed ~code:Validation_error err
  | Ok meta ->
    let snapshot = Keeper_types.create_snapshot meta in
    let json = Keeper_types.snapshot_to_yojson snapshot in
    (true, Yojson.Safe.pretty_to_string json)

let handle_keeper_restore ctx args : tool_result =
  let snapshot_json_str = get_string args "snapshot" "" in
  try
    let snapshot_json = Yojson.Safe.from_string snapshot_json_str in
    match Keeper_types.snapshot_of_yojson snapshot_json with
    | Ok snapshot ->
      let meta = Keeper_types.restore_from_snapshot ctx snapshot in
      let json = Keeper_types.keeper_meta_to_yojson meta in
      (true, Yojson.Safe.pretty_to_string json)
    | Error e -> error_result_typed ~code:Invalid_argument e
  with Yojson.Json_error e ->
    error_result_typed ~code:Invalid_argument (Printf.sprintf "JSON parse error: %s" e)

let handle_keeper_version ctx _args : tool_result =
  let version = Keeper_types.get_version () in
  (true, ok_response (Printf.sprintf "Keeper version: %s" version))

let handle_keeper_health ctx _args : tool_result =
  let health = Keeper_types.check_health () in
  let json = Keeper_types.health_status_to_yojson health in
  (true, Yojson.Safe.pretty_to_string json)

let handle_keeper_ready ctx _args : tool_result =
  let ready = Keeper_types.is_ready () in
  (true, ok_response (if ready then "Ready" else "Not ready"))

let handle_keeper_ping ctx _args : tool_result =
  (true, ok_response "Pong")

let handle_keeper_echo ctx args : tool_result =
  let message = get_string args "message" "" in
  (true, ok_response message)

let handle_keeper_help ctx _args : tool_result =
  let help_text = {|
Keeper tools:
  keeper_reset - Reset keeper state
  keeper_up - Bring keeper online
  keeper_status - Get keeper status
  keeper_list - List all keepers
  keeper_heartbeat - Send heartbeat
  keeper_checkpoint - Get checkpoint
  keeper_reconcile - Reconcile state
  keeper_pause - Pause keeper
  keeper_resume - Resume keeper
  keeper_delete - Delete keeper
  keeper_export - Export keeper data
  keeper_import - Import keeper data
  keeper_validate - Validate keeper
  keeper_repair - Repair keeper
  keeper_stats - Get keeper stats
  keeper_logs - Get keeper logs
  keeper_alerts - Get keeper alerts
  keeper_config - Get keeper config
  keeper_set_config - Set keeper config
  keeper_notify - Send notification
  keeper_broadcast - Broadcast notification
  keeper_query - Query keepers
  keeper_search - Search keepers
  keeper_filter - Filter keepers
  keeper_aggregate - Aggregate keepers
  keeper_batch - Batch operation
  keeper_transaction - Execute transaction
  keeper_rollback - Rollback transaction
  keeper_commit - Commit transaction
  keeper_snapshot - Create snapshot
  keeper_restore - Restore from snapshot
  keeper_version - Get version
  keeper_health - Check health
  keeper_ready - Check readiness
  keeper_ping - Ping
  keeper_echo - Echo message
  keeper_help - Show this help
|} in
  (true, ok_response help_text)

let dispatch_keeper_tool ctx name args : tool_result =
  match name with
  | "keeper_reset" -> handle_keeper_reset ctx args
  | "keeper_up" -> handle_keeper_up ctx args
  | "keeper_status" -> handle_keeper_status ctx args
  | "keeper_list" -> handle_keeper_list ctx args
  | "keeper_heartbeat" -> handle_keeper_heartbeat ctx args
  | "keeper_checkpoint" -> handle_keeper_checkpoint ctx args
  | "keeper_reconcile" -> handle_keeper_reconcile ctx args
  | "keeper_pause" -> handle_keeper_pause ctx args
  | "keeper_resume" -> handle_keeper_resume ctx args
  | "keeper_delete" -> handle_keeper_delete ctx args
  | "keeper_export" -> handle_keeper_export ctx args
  | "keeper_import" -> handle_keeper_import ctx args
  | "keeper_validate" -> handle_keeper_validate ctx args
  | "keeper_repair" -> handle_keeper_repair ctx args
  | "keeper_stats" -> handle_keeper_stats ctx args
  | "keeper_logs" -> handle_keeper_logs ctx args
  | "keeper_alerts" -> handle_keeper_alerts ctx args
  | "keeper_config" -> handle_keeper_config ctx args
  | "keeper_set_config" -> handle_keeper_set_config ctx args
  | "keeper_notify" -> handle_keeper_notify ctx args
  | "keeper_broadcast" -> handle_keeper_broadcast ctx args
  | "keeper_query" -> handle_keeper_query ctx args
  | "keeper_search" -> handle_keeper_search ctx args
  | "keeper_filter" -> handle_keeper_filter ctx args
  | "keeper_aggregate" -> handle_keeper_aggregate ctx args
  | "keeper_batch" -> handle_keeper_batch ctx args
  | "keeper_transaction" -> handle_keeper_transaction ctx args
  | "keeper_rollback" -> handle_keeper_rollback ctx args
  | "keeper_commit" -> handle_keeper_commit ctx args
  | "keeper_snapshot" -> handle_keeper_snapshot ctx args
  | "keeper_restore" -> handle_keeper_restore ctx args
  | "keeper_version" -> handle_keeper_version ctx args
  | "keeper_health" -> handle_keeper_health ctx args
  | "keeper_ready" -> handle_keeper_ready ctx args
  | "keeper_ping" -> handle_keeper_ping ctx args
  | "keeper_echo" -> handle_keeper_echo ctx args
  | "keeper_help" -> handle_keeper_help ctx args
  | _ -> error_result_typed ~code:Not_found (Printf.sprintf "Unknown keeper tool: %s" name)