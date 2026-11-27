module Stream = Server_model_metrics_stream
module Kept = Model_inference_metrics_kept
open Yojson.Safe.Util

let request : Stream.request = { window_minutes = 60; bucket_minutes = 5 }
let row ~id ~at = `Assoc [
  "ts_unix", `Float at; "trace_id", `String id; "turn_id", `Int 1;
  "tool_call_count", `Int 0; "tools_used", `List [];
  "telemetry", `Assoc ["model_used", `String "internal-model";
    "outcome", `String "success"; "turn_count", `Int 1; "agent_core_turn_ordinal", `Int 0;
    "usage_reported", `Bool false; "telemetry_reported", `Bool false]]

let with_workspace f =
  let base_path = Filename.temp_dir "model-query-" "" in
  Fun.protect ~finally:(fun () -> Fs_compat.remove_tree base_path) (fun () ->
    let config = Masc.Workspace.default_config base_path in
    let directory = Common.keepers_runtime_dir_of_base ~base_path in
    Fs_compat.mkdir_p directory;
    f config)

let append config json = Masc.Keeper_types_support.append_decision_record config "query" json
let read config ?(query = request) ~now kept =
  let next, result = Stream.read_snapshot ~base_path:config.Masc.Workspace.base_path ~request:query ~now kept in
  match result with Ok snapshot -> next, snapshot | Error error -> Alcotest.fail error
let count snapshot = snapshot.Stream.json |> member "total_entries" |> to_int

let event topic =
  let payload = { Sse_event.Types.topic; scope = `Workspace } in
  let fields = Sse_event.dashboard_observation_changed_payload_to_json payload |> to_assoc in
  { Masc.Sse.ext_frame = "";
    ext_payload = `Assoc (["type", `String Masc.Workspace_dataset_event.event_type;
      "dataset", `String "dashboard_observation"] @ fields);
    ext_event_id = 1; ext_emitted_at = 0.0 }

let test_cold_and_subsequent_direct_reads () = with_workspace (fun config ->
  let now = Unix.gettimeofday () in
  append config (row ~id:"first" ~at:(now -. 20.));
  let kept, first = read config ~now Kept.empty in
  Alcotest.(check int) "cold query answers its actual row, without pending cache" 1 (count first);
  Alcotest.(check bool) "no asynchronous cache metadata" true (first.json |> member "cache" = `Null);
  Alcotest.(check string) "cost-store status is answered in first frame" "available"
    (first.json |> member "cost_ledger_read" |> member "state" |> to_string);
  append config (row ~id:"second" ~at:(now -. 10.));
  let _, continued = read config ~now kept in
  let _, rest = read config ~now Kept.empty in
  Alcotest.(check int) "stream reads late committed append inside former TTL" 2 (count continued);
  Alcotest.(check string) "REST and native snapshots share the same direct aggregate"
    (Yojson.Safe.to_string rest.json) (Yojson.Safe.to_string continued.json);
  let metric = continued.json |> member "models" |> to_list |> List.hd in
  Alcotest.(check bool) "missing input usage stays unknown" true (metric |> member "total_input_tokens" = `Null);
  Alcotest.(check bool) "missing cost stays unknown" true (metric |> member "total_cost_usd" = `Null))

let test_row_deadline_and_empty_bucket () = with_workspace (fun config ->
  let now = Unix.gettimeofday () in
  let at = now -. 3600. +. 10. in
  append config (row ~id:"expiry" ~at);
  let kept, first = read config ~now Kept.empty in
  let deadline = Option.get first.next_change_at in
  Alcotest.(check (float 0.)) "actual 60-minute query deadline" (Float.succ (at +. 3600.)) deadline;
  let _, at_cutoff = read config ~now:(Float.pred deadline) kept in
  Alcotest.(check int) "row included at exact lower cutoff" 1 (count at_cutoff);
  let _, after = read config ~now:deadline kept in
  Alcotest.(check int) "row expires without another write" 0 (count after);
  Alcotest.(check (option (float 0.))) "empty bucket has no advancing label timer" None after.next_change_at;
  let _, shorter = read config ~query:{ request with window_minutes = 15 } ~now Kept.empty in
  Alcotest.(check int) "a distinct query has its own window" 0 (count shorter))

let test_cost_diagnostics_have_only_semantic_day_deadline () = with_workspace (fun config ->
  let now = Unix.gettimeofday () in
  let store = Cost_ledger.store_of_base_path ~base_path:config.Masc.Workspace.base_path in
  Dated_jsonl.append store (`Assoc []);
  Dated_jsonl.close store;
  let kept, first = read config ~now Kept.empty in
  let violations snapshot = snapshot.Stream.json |> member "cost_ledger_read"
    |> member "schema_violation_rows" |> to_int in
  Alcotest.(check int) "timeless invalid cost row is reported" 1 (violations first);
  let day = Dated_jsonl_kept_days.day_of now in
  let expected = day.starts_at +. Dated_jsonl_kept_days.seconds_per_day +. 3600. in
  Alcotest.(check (option (float 0.))) "diagnostic leaves when its actual file leaves the range"
    (Some expected) first.next_change_at;
  let _, after = read config ~now:expected kept in
  Alcotest.(check int) "expired file no longer contributes diagnostics" 0 (violations after);
  Alcotest.(check (option (float 0.))) "no remaining semantic deadline" None after.next_change_at)

let test_empty_cost_file_does_not_make_a_clock_deadline () = with_workspace (fun config ->
  let now = Unix.gettimeofday () in
  let store = Cost_ledger.store_of_base_path ~base_path:config.Masc.Workspace.base_path in
  Dated_jsonl.append store (`Assoc []);
  Dated_jsonl.close store;
  let date = (Dated_jsonl_kept_days.day_of now).date in
  let paths = match Dated_jsonl.range_day_file_paths_result store ~since:date ~until:date with
    | Ok paths -> paths | Error error -> Alcotest.fail (Dated_jsonl.read_error_to_string error) in
  List.iter (fun path -> Out_channel.with_open_bin path (fun _ -> ())) paths;
  let _, snapshot = read config ~now Kept.empty in
  Alcotest.(check int) "empty existing cost file answers an empty aggregate" 0 (count snapshot);
  Alcotest.(check (option (float 0.))) "empty file departure cannot change the answer" None snapshot.next_change_at)

let test_subscribe_read_and_retirement () = with_workspace (fun config ->
  let now = Unix.gettimeofday () in
  let authority = Masc.Sse.runtime_authority_exn ~base_path:config.Masc.Workspace.base_path in
  let id = "test-model-query-debt" in
  let owed = ref false in
  Fun.protect ~finally:(fun () -> Masc.Sse.unsubscribe_external id) (fun () ->
    Masc.Sse.subscribe_external ~runtime_authority:authority ~id
      ~callback:(fun event -> if Stream.is_invalidation event then owed := true) ();
    let kept, initial = read config ~now Kept.empty in
    append config (row ~id:"after-first-read" ~at:now);
    Masc.Workspace_dataset_event.announce_dashboard_observation
      ~base_path:config.base_path ~scope:`Workspace `Model_metrics;
    Alcotest.(check int) "initial read was actually empty" 0 (count initial);
    Alcotest.(check bool) "commit after the initial read retains trailing debt" true !owed;
    let _, latest = read config ~now kept in
    Alcotest.(check int) "trailing actual reader sees that commit" 1 (count latest);
    owed := false;
    Masc.Workspace_dataset_event.announce_dashboard_observation
      ~base_path:(config.base_path ^ "-other") ~scope:`Workspace `Model_metrics;
    Alcotest.(check bool) "foreign workspace cannot create query debt" false !owed;
    Masc.Sse.unsubscribe_external id;
    Masc.Workspace_dataset_event.announce_dashboard_observation
      ~base_path:config.base_path ~scope:`Workspace `Model_metrics;
    Alcotest.(check bool) "retired query receives no work" false !owed))

let test_cached_snapshot_reuses_kept_and_caps_windows () = with_workspace (fun config ->
  let now = Unix.gettimeofday () in
  let base_path = config.Masc.Workspace.base_path in
  let read_cached query =
    match Stream.read_cached_snapshot ~base_path ~request:query ~now with
    | Ok snapshot -> snapshot
    | Error error -> Alcotest.fail error
  in
  append config (row ~id:"cached-first" ~at:(now -. 30.));
  let first = read_cached request in
  Alcotest.(check int) "cold cached snapshot reads committed row" 1 (count first);
  append config (row ~id:"cached-second" ~at:(now -. 10.));
  let second = read_cached { request with bucket_minutes = 0 } in
  Alcotest.(check int) "shared window cursor folds appended row across bucket variants" 2 (count second);
  for w = 1 to Stream.max_cached_windows + 2 do
    let snap = read_cached { window_minutes = w * 10; bucket_minutes = 0 } in
    Alcotest.(check int) "distinct window after LRU rotation answers exact count" 2 (count snap)
  done;
  let after_ttl = now +. Stream.max_cached_staleness_s +. 1.0 in
  append config (row ~id:"cached-after-ttl" ~at:(after_ttl -. 5.));
  match Stream.read_cached_snapshot ~base_path ~request:{ window_minutes = 60; bucket_minutes = 0 } ~now:after_ttl with
  | Ok refreshed ->
    Alcotest.(check int) "stale cached entry refreshes cleanly after TTL expiry" 3 (count refreshed)
  | Error error -> Alcotest.fail error)

let test_observe_cost_24h_preserves_cached_cost_on_transient_failure () =
  with_workspace (fun config ->
    let now = Unix.gettimeofday () in
    let base_path = config.Masc.Workspace.base_path in
    let cost_row =
      `Assoc
        [ "ts_unix", `Float (now -. 30.0)
        ; "trace_id", `String "cost-obs-1"
        ; "turn_id", `Int 1
        ; "tool_call_count", `Int 0
        ; "tools_used", `List []
        ; ( "telemetry"
          , `Assoc
              [ "model_used", `String "internal-model"
              ; "outcome", `String "success"
              ; "turn_count", `Int 1
              ; "agent_core_turn_ordinal", `Int 0
              ; "usage_reported", `Bool true
              ; "telemetry_reported", `Bool false
              ; "cost_usd", `Float 2.5
              ] )
        ]
    in
    append config cost_row;
    let first = Stream.observe_cost_24h_usd ~base_path ~now in
    Alcotest.(check bool) "cold observation reports cache_was_absent" true first.cache_was_absent;
    Alcotest.(check bool) "cold observation succeeds" false first.read_failed;
    Alcotest.(check (option (float 0.001))) "cold observation computes cost" (Some 2.5) first.cost_usd;
    Alcotest.(check bool) "cold observation reports window edge" true (Option.is_some first.next_change_at);
    let second = Stream.observe_cost_24h_usd ~base_path ~now in
    Alcotest.(check bool) "warm observation reports cache hit" false second.cache_was_absent;
    Alcotest.(check bool) "warm observation succeeds" false second.read_failed;
    let broken_path =
      Filename.concat (Common.keepers_runtime_dir_of_base ~base_path) "broken.decisions.jsonl"
    in
    Unix.mkdir broken_path 0o700;
    Fun.protect
      ~finally:(fun () -> if Sys.file_exists broken_path then Unix.rmdir broken_path)
      (fun () ->
         let failed = Stream.observe_cost_24h_usd ~base_path ~now:(now +. 60.0) in
         Alcotest.(check bool) "unreadable decision file sets read_failed" true failed.read_failed;
         Alcotest.(check (option (float 0.001)))
           "transient read failure preserves last cached 24h cost"
           (Some 2.5)
           (Stream.peek_cached_cost_24h_usd ~base_path ~now:(now +. 60.0));
         let past_ttl = now +. Stream.max_cached_staleness_s +. 1.0 in
         let failed_late = Stream.observe_cost_24h_usd ~base_path ~now:past_ttl in
         Alcotest.(check bool) "sustained failure still sets read_failed" true failed_late.read_failed;
         Alcotest.(check bool)
           "sustained failure does not refresh staleness TTL"
           true
           (Option.is_none (Stream.peek_cached_cost_24h_usd ~base_path ~now:past_ttl)));
    let after_expiry = now +. Stream.max_cached_staleness_s +. 2.0 in
    let recovered = Stream.observe_cost_24h_usd ~base_path ~now:after_expiry in
    Alcotest.(check bool) "recovery after expiry sees cache_was_absent" true recovered.cache_was_absent;
    Alcotest.(check bool) "recovery clears read_failed" false recovered.read_failed;
    Alcotest.(check (option (float 0.001))) "recovery returns live cost" (Some 2.5) recovered.cost_usd)

let test_typed_query_and_invalidation () =
  let parse target = Stream.request (Httpun.Request.create `GET target) in
  Alcotest.(check bool) "zero/negative windows refused" true
    (Result.is_error (parse "/?window=0") && Result.is_error (parse "/?window=-1"));
  Alcotest.(check bool) "7-day max window accepted" true
    (Result.is_ok (parse "/?window=60")
     && Result.is_ok (parse "/?window=1440")
     && Result.is_ok (parse (Printf.sprintf "/?window=%d" Stream.max_window_minutes)));
  Alcotest.(check bool) "unbounded window above max refused" true
    (Result.is_error (parse (Printf.sprintf "/?window=%d" (Stream.max_window_minutes + 1))));
  Alcotest.(check bool) "malformed query refused" true (Result.is_error (parse "/?bucket_min=NaN"));
  Alcotest.(check bool) "model input wakes model query" true (Stream.is_invalidation (event `Model_metrics));
  Alcotest.(check bool) "unrelated input does no aggregate work" false (Stream.is_invalidation (event `Health))

let eio_test name f = Alcotest.test_case name `Quick (fun () -> Eio_main.run (fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env); Fun.protect ~finally:Fs_compat.clear_fs f))

let () = Alcotest.run "Native model metrics query"
  ["reader", [eio_test "cold and committed snapshots" test_cold_and_subsequent_direct_reads;
    eio_test "cached snapshot reuses kept and caps windows" test_cached_snapshot_reuses_kept_and_caps_windows;
    eio_test "observe_cost_24h preserves cached cost on transient failure"
      test_observe_cost_24h_preserves_cached_cost_on_transient_failure;
    eio_test "query row expiry and empty buckets" test_row_deadline_and_empty_bucket;
    eio_test "actual cost diagnostic day expiry" test_cost_diagnostics_have_only_semantic_day_deadline;
    eio_test "empty file creates no clock deadline" test_empty_cost_file_does_not_make_a_clock_deadline;
    eio_test "subscribe/read debt and retirement" test_subscribe_read_and_retirement;
    Alcotest.test_case "typed query and invalidation" `Quick test_typed_query_and_invalidation]]
