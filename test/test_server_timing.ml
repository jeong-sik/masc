open Masc

let test_empty_header () =
  let t = Server_timing.create () in
  Alcotest.(check string) "empty header value" "" (Server_timing.to_header_value t);
  Alcotest.(check (list (pair string string)))
    "extra_header empty" [] (Server_timing.extra_header t)
;;

let test_single_phase_format () =
  let t = Server_timing.create () in
  Server_timing.record_ms t Server_timing.Cache_lookup 12.34;
  let header = Server_timing.to_header_value t in
  (* Single decimal, RFC 8673 token grammar: ALPHA / DIGIT / "-" / "_" / "."  *)
  Alcotest.(check string) "single entry rounded" "cache_lookup;dur=12.3" header
;;

let test_multiple_phases_insertion_order () =
  let t = Server_timing.create () in
  Server_timing.record_ms t Server_timing.Cache_lookup 5.0;
  Server_timing.record_ms t Server_timing.Projection_status 100.0;
  Server_timing.record_ms t Server_timing.Json_serialize 2.5;
  let header = Server_timing.to_header_value t in
  Alcotest.(check string) "insertion order preserved"
    "cache_lookup;dur=5.0, projection_status;dur=100.0, json_serialize;dur=2.5"
    header
;;

let test_repeated_phase_accumulates () =
  let t = Server_timing.create () in
  Server_timing.record_ms t Server_timing.Projection_agents 10.0;
  Server_timing.record_ms t Server_timing.Projection_agents 7.5;
  let header = Server_timing.to_header_value t in
  Alcotest.(check string) "same phase accumulates"
    "projection_agents;dur=17.5" header
;;

let test_measure_records_elapsed () =
  let t = Server_timing.create () in
  let _result =
    Server_timing.measure t Server_timing.Tools_compute (fun () ->
      Unix.sleepf 0.005;
      42)
  in
  let header = Server_timing.to_header_value t in
  (* The entry exists with the right token; we cannot assert exact ms because
     sleep is approximate, but it must be at least 1ms. *)
  let prefix = "tools_compute;dur=" in
  Alcotest.(check bool) "entry present"
    true (String.length header > String.length prefix
          && String.sub header 0 (String.length prefix) = prefix)
;;

let test_measure_records_on_exception () =
  let t = Server_timing.create () in
  let caught =
    try
      let _ =
        Server_timing.measure t Server_timing.Json_serialize (fun () ->
          failwith "boom")
      in
      false
    with Failure _ -> true
  in
  Alcotest.(check bool) "exception re-raised" true caught;
  let header = Server_timing.to_header_value t in
  Alcotest.(check bool) "elapsed still recorded on failure path"
    true (String.length header > 0)
;;

let test_phase_token_total_and_lowercase () =
  let all_phases : Server_timing.phase list = [
    Cache_lookup; Cache_compute;
    Projection_status; Projection_agents; Projection_tasks;
    Projection_keepers; Projection_configured_keepers;
    Projection_config_resolution; Projection_runtime_resolution;
    Project_snapshot_shell_refresh; Project_snapshot_runtime;
    Tools_compute;
    Telemetry_query; Telemetry_filter;
    Telemetry_summary_per_keeper; Telemetry_summary_aggregate;
    Json_serialize;
  ] in
  List.iter (fun p ->
    let tok = Server_timing.phase_token p in
    Alcotest.(check bool)
      (Printf.sprintf "token nonempty: %s" tok)
      true (String.length tok > 0);
    String.iter (fun c ->
      let ok =
        (c >= '0' && c <= '9') ||
        (c >= 'a' && c <= 'z') ||
        c = '-' || c = '_' || c = '.'
      in
      Alcotest.(check bool)
        (Printf.sprintf "RFC8673 token char in %s: %c" tok c)
        true ok
    ) tok
  ) all_phases
;;

let test_custom_phase_sanitized () =
  let raw = "weird name with space/and@punct" in
  let tok = Server_timing.phase_token (Custom raw) in
  String.iter (fun c ->
    let ok =
      (c >= '0' && c <= '9') ||
      (c >= 'A' && c <= 'Z') ||
      (c >= 'a' && c <= 'z') ||
      c = '-' || c = '_' || c = '.'
    in
    Alcotest.(check bool)
      (Printf.sprintf "Custom sanitised char: %c" c) true ok
  ) tok;
  let empty_tok = Server_timing.phase_token (Custom "") in
  Alcotest.(check bool)
    "empty Custom yields non-empty token"
    true (String.length empty_tok > 0)
;;

let test_extra_header_wrap () =
  let t = Server_timing.create () in
  Server_timing.record_ms t Server_timing.Cache_compute 1.0;
  match Server_timing.extra_header t with
  | [ (name, value) ] ->
    Alcotest.(check string) "header name" "Server-Timing" name;
    Alcotest.(check bool) "value non-empty"
      true (String.length value > 0)
  | _ -> Alcotest.fail "expected exactly one extra header"
;;

let () =
  Alcotest.run "Server_timing"
    [
      ( "empty",
        [ Alcotest.test_case "empty header" `Quick test_empty_header ] );
      ( "format",
        [ Alcotest.test_case "single phase" `Quick test_single_phase_format;
          Alcotest.test_case "insertion order" `Quick test_multiple_phases_insertion_order;
          Alcotest.test_case "phase accumulates" `Quick test_repeated_phase_accumulates;
        ] );
      ( "measure",
        [ Alcotest.test_case "records elapsed" `Quick test_measure_records_elapsed;
          Alcotest.test_case "records on exception" `Quick test_measure_records_on_exception;
        ] );
      ( "tokens",
        [ Alcotest.test_case "phase_token total + RFC8673" `Quick test_phase_token_total_and_lowercase;
          Alcotest.test_case "Custom sanitised" `Quick test_custom_phase_sanitized;
        ] );
      ( "wrap",
        [ Alcotest.test_case "extra_header" `Quick test_extra_header_wrap ] );
    ]
;;
