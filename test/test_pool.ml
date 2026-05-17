(* RFC-0107 Phase D.2d — Pool unit tests.

   Tests the pure, transport-independent pieces of the connection pool:
   Host_key normalization, default_config sanity, response/stats type
   shapes.  Live piaf integration (acquire/release lifecycle,
   keep-alive reuse) is exercised in the D.2e cascade-storm reproducer.

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

(* ── stats type shape — Prometheus consumer schema ───────────── *)

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
    create_count_total = 0;
  } in
  Alcotest.(check int) "zero total_idle" 0 zero.total_idle;
  Alcotest.(check int) "zero total_inflight" 0 zero.total_inflight;
  Alcotest.(check (list (pair string int))) "empty idle_per_host"
    [] zero.idle_per_host

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
    ]
