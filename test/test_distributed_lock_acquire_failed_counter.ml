(* #9645: pin canonical metric name + label vocabulary for the
   distributed lock acquire-failed counter.

   [Coord_utils_ops] fires this counter when the retry budget is
   exhausted (50 attempts) and the caller's lock acquire either
   raises [Invalid_argument] or returns [IoError].  Production
   observed [tasks:.backlog] starvation under 16-keeper load —
   the counter lets operators rate-alert without log scraping. *)

let counter_for ~key ~attempts =
  Masc_mcp.Prometheus.metric_value_or_zero
    Masc_mcp.Coord.distributed_lock_acquire_failed_metric
    ~labels:[ ("key", key); ("attempts", string_of_int attempts) ]
    ()

let test_metric_name_stable () =
  Alcotest.(check string)
    "distributed lock acquire failed canonical name"
    Masc_mcp.Prometheus.metric_distributed_lock_acquire_failed
    Masc_mcp.Coord.distributed_lock_acquire_failed_metric

let test_record_increments () =
  let key = "tasks:.backlog-9645-test" in
  let attempts = 50 in
  let before = counter_for ~key ~attempts in
  Masc_mcp.Coord.record_distributed_lock_acquire_failed
    ~key ~attempts;
  Alcotest.(check (float 0.0001))
    "+1 after record"
    (before +. 1.0)
    (counter_for ~key ~attempts)

let test_key_isolation () =
  (* Different keys land in different series — operators
     attribute starvation to a specific lock. *)
  let attempts = 50 in
  let key_a = "tasks:.backlog-iso-9645" in
  let key_b = "keepers:state-iso-9645" in
  let before_a = counter_for ~key:key_a ~attempts in
  Masc_mcp.Coord.record_distributed_lock_acquire_failed
    ~key:key_b ~attempts;
  Alcotest.(check (float 0.0001))
    "key_a counter unaffected by key_b record"
    before_a
    (counter_for ~key:key_a ~attempts)

let test_attempts_label_carried () =
  (* Different attempts values (e.g., the two callers'
     identical 50 vs a future caller with a different cap)
     stay in distinct series. *)
  let key = "tasks:.backlog-attempts-iso-9645" in
  let before_50 = counter_for ~key ~attempts:50 in
  Masc_mcp.Coord.record_distributed_lock_acquire_failed
    ~key ~attempts:20;
  Alcotest.(check (float 0.0001))
    "50-attempt counter unaffected by 20-attempt record"
    before_50
    (counter_for ~key ~attempts:50)

let () =
  Alcotest.run "distributed_lock_acquire_failed_counter_9645" [
    "metric_name", [
      Alcotest.test_case "canonical name stable" `Quick
        test_metric_name_stable;
    ];
    "record", [
      Alcotest.test_case "increments on call" `Quick
        test_record_increments;
    ];
    "isolation", [
      Alcotest.test_case "keys isolated" `Quick test_key_isolation;
      Alcotest.test_case "attempts isolated" `Quick
        test_attempts_label_carried;
    ];
  ]
