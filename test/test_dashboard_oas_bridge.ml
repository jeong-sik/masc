(** Tests for [Dashboard_oas_bridge].

    Twelve-signal collector for I1 telemetry pipeline (#11924). Covers
    ring-buffer semantics (record/recent/clear), provider filter, and
    the nearest-rank percentile in {!Dashboard_oas_bridge.summary}. *)

module DOB = Masc_mcp.Dashboard_oas_bridge

let make_sample
    ?(provider = "anthropic")
    ?(model = "claude-opus-4-7")
    ?(ttfb = 100.0)
    ?(dur = 200.0)
    ?(serialization = 5.0)
    ?(input = 100)
    ?(output = 200)
    ?(throughput = 1000.0)
    ?(cost = 0.001)
    ?(cache = false)
    ?(status = DOB.Success)
    ?(retry = 0)
    () : DOB.sample =
  {
    provider_id = provider;
    model_id = model;
    ttfb_ms = ttfb;
    total_duration_ms = dur;
    serialization_ms = serialization;
    input_tokens = input;
    output_tokens = output;
    throughput_tokens_per_s = throughput;
    cost_usd = cost;
    cache_hit = cache;
    status;
    retry_count = retry;
  }

let setup () = DOB.clear ()

(* --- record + recent --- *)

let test_record_then_recent () =
  setup ();
  DOB.record (make_sample ());
  let xs = DOB.recent () in
  Alcotest.(check int) "1 sample" 1 (List.length xs)

let test_unknown_provider_returns_empty () =
  setup ();
  DOB.record (make_sample ~provider:"anthropic" ());
  Alcotest.(check int) "unknown provider" 0
    (List.length (DOB.recent ~provider:"nope" ()))

(* --- provider filter + cross-provider merge --- *)

let test_provider_filter () =
  setup ();
  DOB.record (make_sample ~provider:"anthropic" ());
  DOB.record (make_sample ~provider:"anthropic" ());
  DOB.record (make_sample ~provider:"ollama" ());
  Alcotest.(check int) "anthropic" 2
    (List.length (DOB.recent ~provider:"anthropic" ()));
  Alcotest.(check int) "ollama" 1
    (List.length (DOB.recent ~provider:"ollama" ()));
  Alcotest.(check int) "all merged" 3 (List.length (DOB.recent ()))

(* --- summary on empty / non-empty --- *)

let test_summary_empty () =
  setup ();
  let r = DOB.summary () in
  Alcotest.(check int) "sample_count" 0 r.DOB.sample_count;
  Alcotest.(check (float 1e-9)) "ttfb_p50" 0.0 r.DOB.ttfb_p50_ms

let test_summary_percentile_nearest_rank () =
  setup ();
  (* Insert 10 samples with ttfb in {0, 100, 200, ..., 900}. *)
  for i = 0 to 9 do
    DOB.record (make_sample ~ttfb:(float_of_int (i * 100)) ())
  done;
  let r = DOB.summary () in
  Alcotest.(check int) "n=10" 10 r.DOB.sample_count;
  (* nearest-rank: idx_p50 = ceil(0.5 * 10) - 1 = 4 -> sorted[4] = 400. *)
  Alcotest.(check (float 1e-9)) "p50 = 400" 400.0 r.DOB.ttfb_p50_ms;
  (* idx_p95 = ceil(0.95 * 10) - 1 = 9 -> sorted[9] = 900. *)
  Alcotest.(check (float 1e-9)) "p95 = 900" 900.0 r.DOB.ttfb_p95_ms

let test_summary_cache_and_cost () =
  setup ();
  DOB.record (make_sample ~cache:true ~cost:0.10 ());
  DOB.record (make_sample ~cache:false ~cost:0.20 ());
  DOB.record (make_sample ~cache:true ~cost:0.30 ());
  let r = DOB.summary () in
  Alcotest.(check (float 1e-9)) "cache_hit_ratio" (2.0 /. 3.0)
    r.DOB.cache_hit_ratio;
  Alcotest.(check (float 1e-9)) "total_cost_usd" 0.60 r.DOB.total_cost_usd

let test_summary_status_counts () =
  setup ();
  DOB.record (make_sample ~status:DOB.Success ());
  DOB.record (make_sample ~status:(DOB.Error { transient = true }) ());
  DOB.record (make_sample ~status:DOB.Timeout ());
  DOB.record (make_sample ~status:(DOB.Cancelled { reason = "user" }) ());
  let r = DOB.summary () in
  Alcotest.(check (float 1e-9)) "error_ratio" 0.5 r.DOB.error_ratio;
  Alcotest.(check int) "cancelled_count" 1 r.DOB.cancelled_count

(* --- clear --- *)

let test_clear_provider () =
  setup ();
  DOB.record (make_sample ~provider:"anthropic" ());
  DOB.record (make_sample ~provider:"ollama" ());
  DOB.clear ~provider:"anthropic" ();
  Alcotest.(check int) "anthropic cleared" 0
    (List.length (DOB.recent ~provider:"anthropic" ()));
  Alcotest.(check int) "ollama remains" 1
    (List.length (DOB.recent ~provider:"ollama" ()))

let () =
  Alcotest.run "Dashboard_oas_bridge"
    [
      ( "record_recent",
        [
          Alcotest.test_case "record + recent" `Quick test_record_then_recent;
          Alcotest.test_case "unknown provider" `Quick
            test_unknown_provider_returns_empty;
        ] );
      ( "provider_filter",
        [ Alcotest.test_case "filter + merge" `Quick test_provider_filter ] );
      ( "summary",
        [
          Alcotest.test_case "empty" `Quick test_summary_empty;
          Alcotest.test_case "percentile nearest-rank" `Quick
            test_summary_percentile_nearest_rank;
          Alcotest.test_case "cache hit + cost" `Quick
            test_summary_cache_and_cost;
          Alcotest.test_case "status counts" `Quick test_summary_status_counts;
        ] );
      ( "clear",
        [ Alcotest.test_case "clear provider" `Quick test_clear_provider ] );
    ]
