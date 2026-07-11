(* RFC-0107 Phase D.2d — Pool unit tests.

   Tests the pure, transport-independent pieces of the connection pool:
   Host_key normalization, default_config sanity, response/stats type
   shapes.  Live piaf integration (acquire/release lifecycle,
   keep-alive reuse) is exercised in the D.2e runtime-storm reproducer.

   The Pool_no_double_close TLA+ spec
   ([specs/keeper-switch-hierarchy/Pool_no_double_close.tla])
   complements these unit tests by model-checking the
   exactly-one-owner invariant on connection lifetime, motivated by
   Eio #244. *)

module Host_key = Masc_http_client.Pool.For_testing.Host_key

(* ── Host_key.of_uri normalization ───────────────────────────── *)

let test_default_port_http () =
  let key = Host_key.of_uri (Uri.of_string "http://example.com/path") in
  Alcotest.(check int) "default port 80 for http" 80 key.port;
  Alcotest.(check string) "scheme" "http" key.scheme;
  Alcotest.(check string) "host" "example.com" key.host

let test_default_port_https () =
  let key = Host_key.of_uri (Uri.of_string "https://api.example.com/v1") in
  Alcotest.(check int) "default port 443 for https" 443 key.port;
  Alcotest.(check string) "scheme" "https" key.scheme

let test_explicit_port_preserved () =
  let key = Host_key.of_uri (Uri.of_string "http://example.com:8080/x") in
  Alcotest.(check int) "explicit port preserved" 8080 key.port

let test_missing_scheme_falls_back_to_http () =
  let key = Host_key.of_uri (Uri.of_string "//example.com/x") in
  Alcotest.(check string) "missing scheme -> http" "http" key.scheme

let test_missing_host_falls_back_to_localhost () =
  let key = Host_key.of_uri (Uri.of_string "http:///path") in
  Alcotest.(check string) "missing host -> localhost" "localhost" key.host

(* ── Host_key.compare — pool key identity ──────────────────────── *)

let test_compare_equal_same_uri () =
  let a = Host_key.of_uri (Uri.of_string "https://api.com/v1") in
  let b = Host_key.of_uri (Uri.of_string "https://api.com/v2") in
  Alcotest.(check int) "same scheme+host+port equal regardless of path"
    0 (Host_key.compare a b)

let test_compare_differs_on_scheme () =
  let a = Host_key.of_uri (Uri.of_string "http://api.com:443/") in
  let b = Host_key.of_uri (Uri.of_string "https://api.com:443/") in
  Alcotest.(check bool) "scheme differs -> keys differ"
    true (Host_key.compare a b <> 0)

let test_compare_differs_on_port () =
  let a = Host_key.of_uri (Uri.of_string "http://api.com:8080/") in
  let b = Host_key.of_uri (Uri.of_string "http://api.com:9090/") in
  Alcotest.(check bool) "port differs -> keys differ"
    true (Host_key.compare a b <> 0)

let test_compare_differs_on_host () =
  let a = Host_key.of_uri (Uri.of_string "http://a.com/") in
  let b = Host_key.of_uri (Uri.of_string "http://b.com/") in
  Alcotest.(check bool) "host differs -> keys differ"
    true (Host_key.compare a b <> 0)

let test_to_string_format () =
  let key = Host_key.of_uri (Uri.of_string "https://api.example.com:8443/x") in
  Alcotest.(check string) "to_string format"
    "https://api.example.com:8443" (Host_key.to_string key)

(* ── default_config sanity ───────────────────────────────────── *)

let test_default_config_max_idle_bounded () =
  let c = Masc_http_client.Pool.default_config in
  (* RFC-0101 §2: nofile cap 10240. Pool consumption must be a small
     fraction. 256 max_total_idle is ~2.5% of the cap. *)
  Alcotest.(check bool) "max_total_idle <= 1024 (rfc-0101 §2 budget)"
    true (c.max_total_idle <= 1024);
  Alcotest.(check bool) "max_idle_per_host <= max_total_idle"
    true (c.max_idle_per_host <= c.max_total_idle);
  Alcotest.(check bool) "max_idle_per_host >= 1"
    true (c.max_idle_per_host >= 1)

let test_default_config_idle_ttl_reasonable () =
  let c = Masc_http_client.Pool.default_config in
  Alcotest.(check bool) "idle_ttl_seconds > 0"
    true (c.idle_ttl_seconds > 0.0);
  Alcotest.(check bool) "idle_ttl_seconds <= 300s (5 min)"
    true (c.idle_ttl_seconds <= 300.0)

let test_default_config_connect_timeout_reasonable () =
  let c = Masc_http_client.Pool.default_config in
  Alcotest.(check bool) "connect_timeout_seconds > 0"
    true (c.connect_timeout_seconds > 0.0);
  Alcotest.(check bool) "connect_timeout_seconds <= 30s"
    true (c.connect_timeout_seconds <= 30.0)

(* ── http_method polymorphic variant exhaustiveness ──────────── *)

let test_http_method_variants () =
  (* Ensures the variant set hasn't drifted; if a new method is added
     to the public mli, this test must be updated explicitly — making
     drift visible at code review time. *)
  let _exhaustive : Masc_http_client.Pool.http_method -> string = function
    | `GET    -> "GET"
    | `POST   -> "POST"
    | `PUT    -> "PUT"
    | `DELETE -> "DELETE"
    | `HEAD   -> "HEAD"
    | `PATCH  -> "PATCH"
  in
  Alcotest.(check string) "method variants stable" "GET"
    (_exhaustive `GET)

(* ── stats type shape — Otel_metric_store consumer schema ───────────── *)

let test_stats_zero_state_shape () =
  (* When the pool is fresh, all counters are zero and there are no
     idle entries. This locks in the shape the Phase D.4 metrics
     exporter will consume. *)
  let zero : Masc_http_client.Pool.stats = {
    idle_per_host = [];
    total_idle = 0;
    total_inflight = 0;
    reuse_count_total = 0;
    evict_count_total = 0;
    evict_failure_count_total = 0;
    create_count_total = 0;
  } in
  Alcotest.(check int) "zero total_idle" 0 zero.total_idle;
  Alcotest.(check int) "zero total_inflight" 0 zero.total_inflight;
  Alcotest.(check (list (pair string int))) "empty idle_per_host"
    [] zero.idle_per_host

(* ── RFC-0129 — read_body_with_idle ─────────────────────────── *)

(* Build a mock [Piaf.Body.t] that the test fiber can feed chunks into
   on its own schedule. The producer fiber pushes [Some chunk] for each
   chunk and [None] to close; this matches the real Piaf body shape but
   is driven by simulated time so the test runs deterministically. *)
let mock_body_with_producer ~clock ~chunks =
  let (stream, push) = Piaf.Stream.create 16 in
  let body = Piaf.Body.of_string_stream stream in
  let producer () =
    List.iter
      (fun (delay_sec, payload) ->
         if delay_sec > 0.0 then Eio.Time.sleep clock delay_sec;
         push (Some payload))
      chunks;
    push None
  in
  body, producer

(* Tests use the real clock with sub-second delays so the suite stays
   under ~1s wall-clock total. mock_clock isn't available in this Eio
   version; idle timer logic is generic over [clock] so real time is a
   faithful test fixture. *)

let test_idle_steady_stream_completes () =
  Eio_main.run @@ fun env ->
  let clock = Eio.Stdenv.clock env in
  let body, producer =
    mock_body_with_producer ~clock
      ~chunks:[
        (0.02, "first");
        (0.05, " second");
        (0.05, " third");
      ]
  in
  Eio.Switch.run @@ fun sw ->
  Eio.Fiber.fork ~sw producer;
  let result =
    Masc_http_client.Pool.For_testing.read_body_with_idle
      ~clock ~start_sec:(Eio.Time.now clock)
      ~idle_timeout_sec:0.5
      body
  in
  match result with
  | Ok (body_str, p) ->
    Alcotest.(check string) "body assembled" "first second third" body_str;
    Alcotest.(check int) "bytes_received counted" 18 p.bytes_received;
    (match p.first_byte_at_sec with
     | Some _ -> ()
     | None -> Alcotest.fail "expected first_byte_at_sec set")
  | Error (msg, _) ->
    Alcotest.fail (Printf.sprintf "expected Ok, got Error %s" msg)

let test_idle_silent_from_start_cancels () =
  Eio_main.run @@ fun env ->
  let clock = Eio.Stdenv.clock env in
  let body, producer =
    (* Producer delays first chunk well past the idle window. *)
    mock_body_with_producer ~clock
      ~chunks:[ (1.0, "late") ]
  in
  Eio.Switch.run @@ fun sw ->
  Eio.Fiber.fork ~sw producer;
  let result =
    Masc_http_client.Pool.For_testing.read_body_with_idle
      ~clock ~start_sec:(Eio.Time.now clock)
      ~idle_timeout_sec:0.2
      body
  in
  match result with
  | Error (msg, p) ->
    Alcotest.(check bool) "idle-timeout message present"
      true (Astring.String.is_prefix ~affix:"idle timeout" msg);
    Alcotest.(check int) "zero bytes received" 0 p.bytes_received;
    Alcotest.(check (option (float 0.001))) "no first_byte_at_sec"
      None p.first_byte_at_sec
  | Ok (_, _) ->
    Alcotest.fail "expected idle timeout, got Ok"

let test_idle_mid_stream_silence_cancels () =
  Eio_main.run @@ fun env ->
  let clock = Eio.Stdenv.clock env in
  let body, producer =
    mock_body_with_producer ~clock
      ~chunks:[
        (0.02, "early");
        (1.0, "very-late");
      ]
  in
  Eio.Switch.run @@ fun sw ->
  Eio.Fiber.fork ~sw producer;
  let result =
    Masc_http_client.Pool.For_testing.read_body_with_idle
      ~clock ~start_sec:(Eio.Time.now clock)
      ~idle_timeout_sec:0.2
      body
  in
  match result with
  | Error (msg, p) ->
    Alcotest.(check bool) "idle-timeout message present"
      true (Astring.String.is_prefix ~affix:"idle timeout" msg);
    Alcotest.(check int) "early chunk bytes counted" 5 p.bytes_received;
    (match p.first_byte_at_sec with
     | Some _ -> ()
     | None -> Alcotest.fail "expected first_byte_at_sec for early chunk")
  | Ok (_, _) ->
    Alcotest.fail "expected mid-stream idle timeout, got Ok"

let test_total_timeout_reports_progress_snapshot () =
  Eio_main.run @@ fun env ->
  let clock = Eio.Stdenv.clock env in
  let stream, push = Piaf.Stream.create 16 in
  let body = Piaf.Body.of_string_stream stream in
  push (Some "early");
  let progress_ref = ref Masc_http_client.Pool.empty_body_progress in
  let result =
    Eio.Fiber.first
      (fun () ->
         Masc_http_client.Pool.For_testing.read_body_with_idle
           ~progress_ref
           ~clock
           ~start_sec:(Eio.Time.now clock)
           ~idle_timeout_sec:5.0
           body)
      (fun () ->
         Eio.Time.sleep clock 0.05;
         Error ("total timeout after 0.1s", !progress_ref))
  in
  match result with
  | Error (msg, p) ->
    Alcotest.(check bool) "total-timeout message present"
      true (Astring.String.is_prefix ~affix:"total timeout" msg);
    Alcotest.(check int) "early bytes preserved" 5 p.bytes_received;
    (match p.first_byte_at_sec with
     | Some _ -> ()
     | None -> Alcotest.fail "expected first_byte_at_sec for early chunk")
  | Ok (_, _) ->
    Alcotest.fail "expected total timeout, got Ok"

let test_close_unreleased_client_closes_once () =
  Eio_main.run @@ fun _env ->
  let released = ref false in
  let calls = ref [] in
  Masc_http_client.Pool.For_testing.close_unreleased_client released (fun ~close_only ->
    calls := close_only :: !calls;
    released := true);
  Masc_http_client.Pool.For_testing.close_unreleased_client released (fun ~close_only ->
    calls := close_only :: !calls;
    released := true);
  Alcotest.(check (list bool)) "close_only called once" [ true ] (List.rev !calls)

let test_close_unreleased_client_swallows_release_error () =
  Eio_main.run @@ fun _env ->
  let released = ref false in
  let calls = ref 0 in
  Masc_http_client.Pool.For_testing.close_unreleased_client released (fun ~close_only ->
    Alcotest.(check bool) "finalizer forces close_only" true close_only;
    incr calls;
    released := true;
    failwith "synthetic release failure");
  Alcotest.(check int) "release attempted once" 1 !calls;
  Alcotest.(check bool) "marked released before failing" true !released

let test_request_timeout_bounds_never_returning_transport () =
  Eio_main.run @@ fun env ->
  let clock = Eio.Stdenv.clock env in
  let started = Eio.Time.now clock in
  let result =
    Masc_http_client.For_testing.with_request_timeout ~clock ~timeout_sec:0.02
      (fun () ->
         Eio.Time.sleep clock 60.0;
         Ok ())
  in
  let elapsed = Eio.Time.now clock -. started in
  (match result with
   | Error message ->
     Alcotest.(check bool)
       "timeout is explicit"
       true
       (Astring.String.is_prefix ~affix:"timeout after" message)
   | Ok () -> Alcotest.fail "never-returning transport must time out");
  Alcotest.(check bool) "deadline settles promptly" true (elapsed < 0.5)

(* ── Runner ──────────────────────────────────────────────────── *)

let () =
  Alcotest.run "pool"
    [
      ( "Host_key normalization",
        [
          Alcotest.test_case "default port 80 for http" `Quick
            test_default_port_http;
          Alcotest.test_case "default port 443 for https" `Quick
            test_default_port_https;
          Alcotest.test_case "explicit port preserved" `Quick
            test_explicit_port_preserved;
          Alcotest.test_case "missing scheme -> http" `Quick
            test_missing_scheme_falls_back_to_http;
          Alcotest.test_case "missing host -> localhost" `Quick
            test_missing_host_falls_back_to_localhost;
        ] );
      ( "Host_key.compare",
        [
          Alcotest.test_case "same scheme+host+port equal" `Quick
            test_compare_equal_same_uri;
          Alcotest.test_case "scheme differs" `Quick
            test_compare_differs_on_scheme;
          Alcotest.test_case "port differs" `Quick
            test_compare_differs_on_port;
          Alcotest.test_case "host differs" `Quick
            test_compare_differs_on_host;
          Alcotest.test_case "to_string format" `Quick
            test_to_string_format;
        ] );
      ( "default_config bounds (RFC-0101 §2)",
        [
          Alcotest.test_case "max_idle bounded" `Quick
            test_default_config_max_idle_bounded;
          Alcotest.test_case "idle_ttl reasonable" `Quick
            test_default_config_idle_ttl_reasonable;
          Alcotest.test_case "connect_timeout reasonable" `Quick
            test_default_config_connect_timeout_reasonable;
        ] );
      ( "http_method exhaustiveness",
        [
          Alcotest.test_case "variants stable" `Quick
            test_http_method_variants;
        ] );
      ( "stats type shape",
        [
          Alcotest.test_case "zero state" `Quick test_stats_zero_state_shape;
        ] );
      ( "RFC-0129 read_body_with_idle",
        [
          Alcotest.test_case "steady stream completes" `Quick
            test_idle_steady_stream_completes;
          Alcotest.test_case "silent-from-start cancels" `Quick
            test_idle_silent_from_start_cancels;
          Alcotest.test_case "mid-stream silence cancels" `Quick
            test_idle_mid_stream_silence_cancels;
          Alcotest.test_case "total timeout reports progress snapshot" `Quick
            test_total_timeout_reports_progress_snapshot;
        ] );
      ( "cancel-safe release finalizer",
        [
          Alcotest.test_case "closes unreleased client once" `Quick
            test_close_unreleased_client_closes_once;
          Alcotest.test_case "swallows release failure" `Quick
            test_close_unreleased_client_swallows_release_error;
        ] );
      ( "request deadline",
        [
          Alcotest.test_case "never-returning transport is bounded" `Quick
            test_request_timeout_bounds_never_returning_transport;
        ] );
    ]
