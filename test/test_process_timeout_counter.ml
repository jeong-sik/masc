(* test/test_process_timeout_counter.ml

   #9632: pin the canonical Prometheus metric name + label
   shape for [Process_eio] timeout observability.

   Background: [run_argv] / [run_argv_with_stdin] /
   [run_argv_with_stdin_and_status_split] /
   [run_argv_with_status_split] all WARN-log on
   [Eio.Time.Timeout] but never produced a metric, so
   operators could not answer "which command is timing out
   and is 15s/60s the right budget?" without log scraping.

   Layering: [masc_process] sits below [masc_mcp.Prometheus]
   in the library dep graph, so the emit runs through
   [Process_eio.process_timeout_observer_fn] which [lib/coord.ml]
   wires to [Masc_mcp.Coord.record_process_timeout].  This test
   exercises the wired pair — [record_process_timeout]
   directly for counter mechanics, and [Process_eio.argv_program]
   for the cardinality-bounding helper. *)

let counter_for ~program ~timeout_sec =
  Masc_mcp.Prometheus.metric_value_or_zero
    Masc_mcp.Coord.process_timeout_metric
    ~labels:
      [ "program", program
      ; ("timeout_bucket", Masc_mcp.Timeout_bucket.(to_label (of_seconds timeout_sec)))
      ]
    ()
;;

let test_metric_name_stable () =
  Alcotest.(check string)
    "process timeout canonical metric name"
    Masc_mcp.Prometheus.metric_process_timeout
    Masc_mcp.Coord.process_timeout_metric
;;

let test_metric_registered_at_init () =
  let text = Masc_mcp.Prometheus.to_prometheus_text () in
  let has literal =
    try
      ignore (Str.search_forward (Str.regexp_string literal) text 0);
      true
    with
    | Not_found -> false
  in
  Alcotest.(check bool)
    "process timeout HELP registered"
    true
    (has "# HELP masc_process_timeout_total");
  Alcotest.(check bool)
    "process timeout TYPE registered"
    true
    (has "# TYPE masc_process_timeout_total counter")
;;

let test_argv_program_basename () =
  Alcotest.(check string)
    "absolute path → basename"
    "git"
    (Process_eio.argv_program [ "/usr/bin/git"; "status"; "--porcelain" ]);
  Alcotest.(check string)
    "bare command → unchanged"
    "gh"
    (Process_eio.argv_program [ "gh"; "auth"; "status" ])
;;

let test_argv_program_empty () =
  Alcotest.(check string) "empty argv → sentinel" "<empty>" (Process_eio.argv_program [])
;;

let test_record_increments () =
  let program = "test_program_9632" in
  let timeout_sec = 15.0 in
  let before = counter_for ~program ~timeout_sec in
  Masc_mcp.Coord.record_process_timeout ~program ~timeout_sec;
  Alcotest.(check (float 0.0001))
    "+1 on call"
    (before +. 1.0)
    (counter_for ~program ~timeout_sec);
  Masc_mcp.Coord.record_process_timeout ~program ~timeout_sec;
  Alcotest.(check (float 0.0001))
    "+1 again"
    (before +. 2.0)
    (counter_for ~program ~timeout_sec)
;;

let test_program_isolation () =
  (* Two programs with the same timeout must not bleed. *)
  let timeout_sec = 60.0 in
  let prog_a = "isolation_a_9632" in
  let prog_b = "isolation_b_9632" in
  let before_a = counter_for ~program:prog_a ~timeout_sec in
  Masc_mcp.Coord.record_process_timeout ~program:prog_b ~timeout_sec;
  Alcotest.(check (float 0.0001))
    "program A unchanged"
    before_a
    (counter_for ~program:prog_a ~timeout_sec)
;;

let test_timeout_sec_isolation () =
  (* Same program with two budgets must split into separate series. *)
  let program = "budget_split_9632" in
  let before_15 = counter_for ~program ~timeout_sec:15.0 in
  let before_60 = counter_for ~program ~timeout_sec:60.0 in
  Masc_mcp.Coord.record_process_timeout ~program ~timeout_sec:15.0;
  Alcotest.(check (float 0.0001))
    "15s budget +1"
    (before_15 +. 1.0)
    (counter_for ~program ~timeout_sec:15.0);
  Alcotest.(check (float 0.0001))
    "60s budget unchanged"
    before_60
    (counter_for ~program ~timeout_sec:60.0)
;;

let () =
  Alcotest.run
    "process_timeout_counter_9632"
    [ ( "metric_name"
      , [ Alcotest.test_case "canonical name stable" `Quick test_metric_name_stable
        ; Alcotest.test_case
            "registered in Prometheus init"
            `Quick
            test_metric_registered_at_init
        ] )
    ; ( "argv_program"
      , [ Alcotest.test_case "basename" `Quick test_argv_program_basename
        ; Alcotest.test_case "empty sentinel" `Quick test_argv_program_empty
        ] )
    ; "record", [ Alcotest.test_case "increments on call" `Quick test_record_increments ]
    ; ( "isolation"
      , [ Alcotest.test_case "programs isolated" `Quick test_program_isolation
        ; Alcotest.test_case "timeout_sec isolated" `Quick test_timeout_sec_isolation
        ] )
    ]
;;
