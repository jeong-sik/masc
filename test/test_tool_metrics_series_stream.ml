module Stream = Server_tool_metrics_series_stream

let event topic =
  let payload = { Sse_event.Types.topic; scope = `Workspace } in
  let fields = Sse_event.dashboard_observation_changed_payload_to_json payload
    |> Yojson.Safe.Util.to_assoc in
  { Masc.Sse.ext_frame = ""
  ; ext_payload = `Assoc
      (["type", `String Masc.Workspace_dataset_event.event_type;
        "dataset", `String (Masc.Workspace_dataset_event.dataset_name
          (Masc.Workspace_dataset_event.Dashboard_observation payload))] @ fields)
  ; ext_event_id = 1; ext_emitted_at = 0.0 }

let test_invalidation_uses_typed_topic () =
  Alcotest.(check bool) "metric writer accepted" true (Stream.is_invalidation (event `Tool_metrics));
  Alcotest.(check bool) "catalog-derived public names accepted" true (Stream.is_invalidation (event `Tools));
  Alcotest.(check bool) "unrelated health does not scan series" false (Stream.is_invalidation (event `Health));
  let malformed = { (event `Tool_metrics) with ext_payload =
    `Assoc ["type", `String Masc.Workspace_dataset_event.event_type;
      "dataset", `String "dashboard_observation"; "topic", `String "tool_metrics";
      "scope", `String "unknown"] } in
  Alcotest.(check bool) "unknown authority scope refused" false (Stream.is_invalidation malformed)

let test_runtime_authority_filters_source_notifications () =
  let first = Filename.temp_dir "tool-series-authority-" "" in
  let second = Filename.temp_dir "tool-series-other-" "" in
  let id = "test-tool-series-authority" in
  Fun.protect ~finally:(fun () ->
    Masc.Sse.unsubscribe_external id;
    Fs_compat.remove_tree first;
    Fs_compat.remove_tree second) (fun () ->
    let authority = Masc.Sse.runtime_authority_exn ~base_path:first in
    let seen = ref 0 in
    Masc.Sse.subscribe_external ~runtime_authority:authority ~id
      ~callback:(fun notification -> if Stream.is_invalidation notification then incr seen) ();
    Masc.Workspace_dataset_event.announce_dashboard_observation ~base_path:second
      ~scope:`Workspace `Tool_metrics;
    Alcotest.(check int) "other workspace creates no refresh" 0 !seen;
    Masc.Workspace_dataset_event.announce_dashboard_observation ~base_path:first
      ~scope:`Workspace `Tool_metrics;
    Alcotest.(check int) "own committed observation wakes query" 1 !seen;
    Masc.Sse.unsubscribe_external id;
    Masc.Workspace_dataset_event.announce_dashboard_observation ~base_path:first
      ~scope:`Workspace `Tool_metrics;
    Alcotest.(check int) "withdrawn query stays retired" 1 !seen)

let test_native_snapshots_expire_rows_without_writes () =
  let base_path = Filename.temp_dir "tool-series-stream-" "" in
  Fun.protect ~finally:(fun () ->
    Tool_metrics_store.reset_for_testing ();
    Fs_compat.remove_tree base_path) (fun () ->
    let config = Masc.Workspace.default_config base_path in
    let now = 1_793_750_400.0 +. 1800.0 in
    let ts = now -. 3600.0 +. 10.0 in
    let request : Server_dashboard_http_agent_api.tool_series_request =
      { since_hours = 1.0; width = Tool_metrics_series.Hour;
        utc_offset_min = 0; tool_name = Some "read" } in
    let get_ok = function Ok value -> value | Error error -> Alcotest.fail error in
    Tool_metrics_store.insert ~masc_root:(Masc.Workspace.masc_dir config)
      ~result_bytes:0
      { record_id = "expires"; ts; tool_name = "read"; disposition = "completed";
        duration_ms = 2.0 } |> get_ok;
    let observe now = Stream.read_snapshot ~config ~request ~now |> get_ok in
    let total snapshot = Yojson.Safe.Util.(snapshot.Stream.json |> member "total"
      |> member "call_count" |> to_int) in
    let before = observe now in
    Alcotest.(check int) "native frame has committed row" 1 (total before);
    let at_cutoff = observe (Float.pred before.next_change_at) in
    Alcotest.(check int) "included at exact lower cutoff" 1 (total at_cutoff);
    let after = observe before.next_change_at in
    Alcotest.(check int) "native frame expires row without new writes" 0 (total after);
    Alcotest.(check int) "snapshot reads retain no background query registration" 0
      (Masc.Sse.external_subscriber_count_with_prefix "tool-series:"))

let eio_test name test = Alcotest.test_case name `Quick (fun () ->
  Eio_main.run (fun env ->
    Fs_compat.set_fs (Eio.Stdenv.fs env);
    Fun.protect ~finally:Fs_compat.clear_fs test))

let () = Alcotest.run "Tool metrics series stream"
  ["contract", [Alcotest.test_case "typed invalidation selection" `Quick test_invalidation_uses_typed_topic;
     eio_test "runtime authority and subscription retirement" test_runtime_authority_filters_source_notifications;
     eio_test "native snapshot obeys actual row expiry" test_native_snapshots_expire_rows_without_writes]]
