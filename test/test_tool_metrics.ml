(** Tests for Tool_metrics — per-tool timing and success/failure metrics *)

module M = Tool_metrics
module R = Tool_result

let setup () = M.clear ()

let make_result ~name ~success ~duration_ms : R.result =
  if success
  then R.Completed { R.tool_name = name; data = `Null; metadata = None; duration_ms }
  else
    R.Failed
      { R.class_ = Runtime_failure
      ; message = ""
      ; data = `Null
      ; metadata = None
      ; tool_name = name
      ; duration_ms
      }

let test_record_and_stats () =
  setup ();
  M.record (make_result ~name:"t1" ~success:true ~duration_ms:10.0);
  M.record (make_result ~name:"t1" ~success:true ~duration_ms:20.0);
  M.record (make_result ~name:"t1" ~success:false ~duration_ms:5.0);
  M.record
    (R.Deferred
       { R.tool_name = "t1"; data = `Null; metadata = None; duration_ms = 7.0 });
  match M.stats_for "t1" with
  | Some s ->
    Alcotest.(check int) "call_count" 4 s.call_count;
    Alcotest.(check int) "success" 2 s.success_count;
    Alcotest.(check int) "deferred" 1 s.deferred_count;
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

let reference_percentile values p =
  let sorted = Array.of_list values in
  Array.sort Float.compare sorted;
  let index =
    Float.to_int
      (Float.round (Float.of_int (Array.length sorted - 1) *. p))
  in
  sorted.(index)

let test_incremental_percentiles_match_sorted_reference () =
  setup ();
  let random = Random.State.make [| 0x32009; 0x5eed |] in
  let values =
    List.init 20_000 (fun _ -> Float.of_int (Random.State.int random 1_000))
  in
  List.iter
    (fun duration_ms ->
       M.record
         (make_result ~name:"reference" ~success:true ~duration_ms))
    values;
  match M.stats_for "reference" with
  | None -> Alcotest.fail "expected reference stats"
  | Some stats ->
    Alcotest.(check int) "all samples retained" 20_000 stats.call_count;
    Alcotest.(check (float 1e-12))
      "p50 matches sorted reference"
      (reference_percentile values 0.50)
      stats.p50_ms;
    Alcotest.(check (float 1e-12))
      "p95 matches sorted reference"
      (reference_percentile values 0.95)
      stats.p95_ms;
    Alcotest.(check (float 1e-12))
      "p99 matches sorted reference"
      (reference_percentile values 0.99)
      stats.p99_ms

let test_monotonic_unique_durations_remain_exact () =
  setup ();
  for value = 1 to 50_000 do
    M.record
      (make_result
         ~name:"monotonic"
         ~success:true
         ~duration_ms:(Float.of_int value))
  done;
  for value = 50_000 downto 1 do
    M.record
      (make_result
         ~name:"monotonic"
         ~success:true
         ~duration_ms:(Float.of_int value))
  done;
  match M.stats_for "monotonic" with
  | None -> Alcotest.fail "expected monotonic stats"
  | Some stats ->
    Alcotest.(check int) "all monotonic samples retained" 100_000 stats.call_count;
    Alcotest.(check (float 1e-12)) "monotonic p50" 25_001.0 stats.p50_ms;
    Alcotest.(check (float 1e-12)) "monotonic p95" 47_500.0 stats.p95_ms;
    Alcotest.(check (float 1e-12)) "monotonic p99" 49_500.0 stats.p99_ms

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

let test_replace_samples_is_atomic_and_idempotent () =
  setup ();
  M.record (make_result ~name:"stale" ~success:true ~duration_ms:99.0);
  let replace () =
    M.replace_samples (fun add ->
      add
        { M.tool_name = "alpha"
        ; disposition = M.Completed
        ; duration_ms = 10.0
        };
      add
        { M.tool_name = "alpha"
        ; disposition = M.Deferred
        ; duration_ms = 20.0
        };
      add
        { M.tool_name = "beta"
        ; disposition = M.Failed
        ; duration_ms = 30.0
        };
      Ok "loaded")
  in
  Alcotest.(check (result string string))
    "producer result"
    (Ok "loaded")
    (replace ());
  Alcotest.(check bool) "old snapshot replaced" true
    (Option.is_none (M.stats_for "stale"));
  let alpha = Option.get (M.stats_for "alpha") in
  Alcotest.(check int) "alpha calls" 2 alpha.call_count;
  Alcotest.(check int) "alpha completed" 1 alpha.success_count;
  Alcotest.(check int) "alpha deferred" 1 alpha.deferred_count;
  Alcotest.(check (result string string))
    "same producer can replace again"
    (Ok "loaded")
    (replace ());
  Alcotest.(check int)
    "second replacement does not double count"
    2
    (Option.get (M.stats_for "alpha")).call_count

let test_replace_samples_keeps_snapshot_on_error () =
  setup ();
  M.record (make_result ~name:"live" ~success:true ~duration_ms:4.0);
  let result =
    M.replace_samples (fun add ->
      add
        { M.tool_name = "partial"
        ; disposition = M.Completed
        ; duration_ms = 1.0
        };
      Error "read failed")
  in
  Alcotest.(check (result string string)) "producer error" (Error "read failed") result;
  Alcotest.(check bool) "partial snapshot not published" true
    (Option.is_none (M.stats_for "partial"));
  Alcotest.(check int)
    "existing snapshot retained"
    1
    (Option.get (M.stats_for "live")).call_count

let test_all_stats_reuses_and_invalidates_snapshot () =
  setup ();
  M.record (make_result ~name:"cached" ~success:true ~duration_ms:1.0);
  let first = M.all_stats () in
  let second = M.all_stats () in
  Alcotest.(check bool) "sequential read reuses snapshot" true (first == second);
  let concurrent =
    List.init 8 (fun _ -> Domain.spawn M.all_stats) |> List.map Domain.join
  in
  Alcotest.(check bool)
    "concurrent reads reuse snapshot"
    true
    (List.for_all (fun snapshot -> snapshot == first) concurrent);
  M.record (make_result ~name:"cached" ~success:true ~duration_ms:2.0);
  let after_record = M.all_stats () in
  Alcotest.(check bool)
    "record invalidates snapshot"
    true
    (after_record != first);
  Alcotest.(check int)
    "recomputed count"
    2
    (List.hd after_record).call_count;
  let replace_result =
    M.replace_samples (fun add ->
      add
        { M.tool_name = "replacement"
        ; disposition = M.Failed
        ; duration_ms = 3.0
        };
      Ok ())
  in
  Alcotest.(check (result unit string)) "replacement succeeds" (Ok ()) replace_result;
  let after_replace = M.all_stats () in
  Alcotest.(check bool)
    "replacement invalidates snapshot"
    true
    (after_replace != after_record);
  Alcotest.(check string)
    "replacement published"
    "replacement"
    (List.hd after_replace).tool_name

let () =
  Alcotest.run "Tool_metrics" [
    "recording", [
      Alcotest.test_case "record and stats" `Quick test_record_and_stats;
      Alcotest.test_case "unknown tool" `Quick test_unknown_tool;
    ];
    "percentiles", [
      Alcotest.test_case "p50/p95/p99" `Quick test_percentiles;
      Alcotest.test_case
        "incremental values match sorted reference"
        `Quick
        test_incremental_percentiles_match_sorted_reference;
      Alcotest.test_case
        "monotonic unique values remain exact"
        `Quick
        test_monotonic_unique_durations_remain_exact;
    ];
    "aggregation", [
      Alcotest.test_case "sorted by count" `Quick test_all_stats_sorted;
      Alcotest.test_case "to_json" `Quick test_to_json;
      Alcotest.test_case "all_to_json" `Quick test_all_to_json;
    ];
    "replacement", [
      Alcotest.test_case
        "sample replacement is atomic and idempotent"
        `Quick
        test_replace_samples_is_atomic_and_idempotent;
      Alcotest.test_case
        "failed replacement keeps current snapshot"
        `Quick
        test_replace_samples_keeps_snapshot_on_error;
    ];
    "snapshot cache", [
      Alcotest.test_case
        "reuses reads and invalidates on writes"
        `Quick
        test_all_stats_reuses_and_invalidates_snapshot;
    ];
  ]
