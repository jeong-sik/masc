(** Tests for Tool_metrics — per-tool timing and success/failure metrics *)

module M = Masc_mcp.Tool_metrics
module R = Masc_mcp.Tool_result

let setup () = M.clear ()

let make_result ~name ~success ~duration_ms =
  { R.success; data = `Null; legacy_message = ""; tool_name = name; duration_ms }

let test_record_and_stats () =
  setup ();
  M.record (make_result ~name:"t1" ~success:true ~duration_ms:10.0);
  M.record (make_result ~name:"t1" ~success:true ~duration_ms:20.0);
  M.record (make_result ~name:"t1" ~success:false ~duration_ms:5.0);
  match M.stats_for "t1" with
  | Some s ->
    Alcotest.(check int) "call_count" 3 s.call_count;
    Alcotest.(check int) "success" 2 s.success_count;
    Alcotest.(check int) "failure" 1 s.failure_count;
    Alcotest.(check bool) "mean > 0" true (s.mean_ms > 0.0)
  | None -> Alcotest.fail "expected stats"

let test_percentiles () =
  setup ();
  (* Insert 100 values: 1.0, 2.0, ..., 100.0 *)
  for i = 1 to 100 do
    M.record (make_result ~name:"perc" ~success:true
                ~duration_ms:(float_of_int i))
  done;
  match M.stats_for "perc" with
  | Some s ->
    Alcotest.(check bool) "p50 ~ 50" true (s.p50_ms >= 49.0 && s.p50_ms <= 51.0);
    Alcotest.(check bool) "p95 ~ 95" true (s.p95_ms >= 94.0 && s.p95_ms <= 96.0);
    Alcotest.(check bool) "p99 ~ 99" true (s.p99_ms >= 98.0 && s.p99_ms <= 100.0);
    Alcotest.(check bool) "mean ~ 50.5" true (s.mean_ms >= 49.0 && s.mean_ms <= 52.0)
  | None -> Alcotest.fail "expected stats"

let test_unknown_tool () =
  setup ();
  Alcotest.(check bool) "none" true (Option.is_none (M.stats_for "ghost"))

let test_all_stats_sorted () =
  setup ();
  M.record (make_result ~name:"rarely" ~success:true ~duration_ms:1.0);
  for _ = 1 to 5 do
    M.record (make_result ~name:"often" ~success:true ~duration_ms:2.0)
  done;
  let all = M.all_stats () in
  Alcotest.(check int) "2 tools" 2 (List.length all);
  Alcotest.(check string) "most called first" "often" (List.hd all).tool_name

let test_to_json () =
  setup ();
  M.record (make_result ~name:"j1" ~success:true ~duration_ms:10.0);
  match M.stats_for "j1" with
  | Some s ->
    let json = M.to_json s in
    (match json with
     | `Assoc fields ->
       Alcotest.(check bool) "has tool_name" true
         (List.exists (fun (k, _) -> k = "tool_name") fields);
       Alcotest.(check bool) "has p50" true
         (List.exists (fun (k, _) -> k = "p50_ms") fields)
     | _ -> Alcotest.fail "expected Assoc")
  | None -> Alcotest.fail "expected stats"

let test_all_to_json () =
  setup ();
  M.record (make_result ~name:"a" ~success:true ~duration_ms:1.0);
  M.record (make_result ~name:"b" ~success:false ~duration_ms:2.0);
  match M.all_to_json () with
  | `List l -> Alcotest.(check int) "2 entries" 2 (List.length l)
  | _ -> Alcotest.fail "expected List"

let () =
  Alcotest.run "Tool_metrics" [
    "recording", [
      Alcotest.test_case "record and stats" `Quick test_record_and_stats;
      Alcotest.test_case "unknown tool" `Quick test_unknown_tool;
    ];
    "percentiles", [
      Alcotest.test_case "p50/p95/p99" `Quick test_percentiles;
    ];
    "aggregation", [
      Alcotest.test_case "sorted by count" `Quick test_all_stats_sorted;
      Alcotest.test_case "to_json" `Quick test_to_json;
      Alcotest.test_case "all_to_json" `Quick test_all_to_json;
    ];
  ]
