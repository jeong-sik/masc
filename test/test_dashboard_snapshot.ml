(** Unit tests for the Phase 3 prototype landing of RFC-0138.

    Until handler wiring lands, we validate the storage primitive:
    - current () is None before any publish
    - publish_for_test writes a slot, current () reads it
    - reset_for_test clears the slot back to None
    - make_for_test produces a snapshot whose fields are byte-identical
      to its arguments (no transformation, no rounding) *)

open Masc

let config = Workspace.default_config "/tmp/dashboard-snapshot-test"

let test_current_starts_empty () =
  Dashboard_snapshot.reset_for_test ();
  Alcotest.(check bool) "no live snapshot before publish"
    true (Option.is_none (Dashboard_snapshot.current ()))
;;

let test_publish_then_current () =
  Dashboard_snapshot.reset_for_test ();
  let snap =
    Dashboard_snapshot.make_for_test ~config
      ~shell:(`String "shell-value")
      ~tools:(`String "tools-value")
      ~namespace_truth:(`String "nt-value")
      ~telemetry_summary:(`String "ts-value")
      ()
  in
  Dashboard_snapshot.publish_for_test snap;
  match Dashboard_snapshot.current () with
  | None -> Alcotest.fail "expected Some after publish"
  | Some t ->
    Alcotest.(check string) "shell roundtrip"
      "shell-value" (Yojson.Safe.Util.to_string t.shell);
    Alcotest.(check string) "tools roundtrip"
      "tools-value" (Yojson.Safe.Util.to_string t.tools.json);
    Alcotest.(check string) "namespace_truth roundtrip"
      "nt-value" (Yojson.Safe.Util.to_string t.namespace_truth);
    Alcotest.(check string) "telemetry_summary roundtrip"
      "ts-value" (Yojson.Safe.Util.to_string t.telemetry_summary)
;;

let test_reset_clears_slot () =
  let snap =
    Dashboard_snapshot.make_for_test ~config
      ~shell:`Null ~tools:`Null
      ~namespace_truth:`Null ~telemetry_summary:`Null ()
  in
  Dashboard_snapshot.publish_for_test snap;
  Alcotest.(check bool) "populated before reset"
    true (Option.is_some (Dashboard_snapshot.current ()));
  Dashboard_snapshot.reset_for_test ();
  Alcotest.(check bool) "empty after reset"
    true (Option.is_none (Dashboard_snapshot.current ()))
;;

let test_generated_at_recent () =
  let before = Unix.gettimeofday () in
  let s =
    Dashboard_snapshot.make_for_test ~config ~shell:`Null ~tools:`Null
      ~namespace_truth:`Null ~telemetry_summary:`Null ()
  in
  let after = Unix.gettimeofday () in
  Alcotest.(check bool) "generated_at >= before"
    true (s.generated_at >= before);
  Alcotest.(check bool) "generated_at <= after"
    true (s.generated_at <= after)
;;

let test_projection_ttl_reuse_boundaries () =
  let reuse ~now ~ttl ~refreshed_at =
    Dashboard_snapshot.For_testing.should_reuse_projection
      ~now ~ttl ~refreshed_at
  in
  Alcotest.(check bool) "inside ttl reuses" true
    (reuse ~now:109.9 ~ttl:10.0 ~refreshed_at:100.0);
  Alcotest.(check bool) "ttl boundary refreshes" false
    (reuse ~now:110.0 ~ttl:10.0 ~refreshed_at:100.0);
  Alcotest.(check bool) "clock rollback refreshes" false
    (reuse ~now:99.0 ~ttl:10.0 ~refreshed_at:100.0)
;;

let test_projection_cache_retains_last_good_and_successful_null () =
  let now_value = ref 100.0 in
  let now () = !now_value in
  let calls = ref 0 in
  let cache = Dashboard_snapshot.For_testing.make_cache () in
  let refresh compute =
    Dashboard_snapshot.For_testing.refresh_projection
      ~now ~ttl:10.0 ~cache compute
  in
  let first = refresh (fun () -> incr calls; `String "good") in
  Alcotest.(check string) "first success" "good" (Yojson.Safe.Util.to_string first);
  now_value := 105.0;
  let hit = refresh (fun () -> incr calls; `String "unexpected") in
  Alcotest.(check string) "fresh hit" "good" (Yojson.Safe.Util.to_string hit);
  Alcotest.(check int) "fresh hit skips callback" 1 !calls;
  now_value := 111.0;
  let fallback = refresh (fun () -> incr calls; failwith "refresh failed") in
  Alcotest.(check string) "failed refresh keeps last good" "good"
    (Yojson.Safe.Util.to_string fallback);
  let null_cache = Dashboard_snapshot.For_testing.make_cache () in
  now_value := 200.0;
  let null_calls = ref 0 in
  ignore
    (Dashboard_snapshot.For_testing.refresh_projection
       ~now ~ttl:10.0 ~cache:null_cache
       (fun () -> incr null_calls; `Null));
  now_value := 205.0;
  ignore
    (Dashboard_snapshot.For_testing.refresh_projection
       ~now ~ttl:10.0 ~cache:null_cache
       (fun () -> incr null_calls; `String "unexpected"));
  Alcotest.(check int) "successful null is cached" 1 !null_calls;
  let cold_cache = Dashboard_snapshot.For_testing.make_cache () in
  Alcotest.check_raises "cold failure aborts publish" (Failure "cold")
    (fun () ->
       ignore
         (Dashboard_snapshot.For_testing.refresh_projection
            ~now ~ttl:10.0 ~cache:cold_cache
            (fun () -> failwith "cold")))
;;

let test_activity_defaults_cache_retains_last_good () =
  let now_value = ref 100.0 in
  let now () = !now_value in
  let calls = ref 0 in
  let cache = Dashboard_snapshot.For_testing.make_activity_cache () in
  let refresh compute =
    Dashboard_snapshot.For_testing.refresh_activity_defaults
      ~now ~ttl:10.0 ~cache compute
  in
  let dummy1 : Activity_graph.default_projections =
    { events_default = `String "e1"
    ; graph_default = `String "g1"
    ; swimlane_default = `String "s1"
    }
  in
  let dummy2 : Activity_graph.default_projections =
    { events_default = `String "e2"
    ; graph_default = `String "g2"
    ; swimlane_default = `String "s2"
    }
  in
  let first = refresh (fun () -> incr calls; dummy1) in
  Alcotest.(check string) "first success" "e1"
    (Yojson.Safe.Util.to_string first.events_default);
  now_value := 105.0;
  let hit = refresh (fun () -> incr calls; dummy2) in
  Alcotest.(check string) "fresh hit" "e1"
    (Yojson.Safe.Util.to_string hit.events_default);
  Alcotest.(check int) "fresh hit skips callback" 1 !calls;
  now_value := 111.0;
  let fallback = refresh (fun () -> incr calls; failwith "refresh failed") in
  Alcotest.(check string) "failed refresh keeps last good" "e1"
    (Yojson.Safe.Util.to_string fallback.events_default);
  let cold_cache = Dashboard_snapshot.For_testing.make_activity_cache () in
  Alcotest.check_raises "cold failure aborts publish" (Failure "cold")
    (fun () ->
       ignore
         (Dashboard_snapshot.For_testing.refresh_activity_defaults
            ~now ~ttl:10.0 ~cache:cold_cache
            (fun () -> failwith "cold")))
;;

let test_tools_component_reuses_complete_representations () =
  let now_value = ref 100. in
  let cache = Dashboard_snapshot.For_testing.make_tools_cache () in
  let calls = ref 0 in
  let json version = `Assoc
    [ "version", `Int version
    ; "tool_inventory", `List (List.init 200 (fun _ -> `String "tool-with-repeated-description"))
    ; "keeper_waiting_inventory", `Assoc [ "waiting", `List [ `String "keeper-a" ] ]
    ; "effective_keeper_surface", `Null
    ; "skill_activations", `Null ] in
  let refresh f = Dashboard_snapshot.For_testing.refresh_tools
    ~now:(fun () -> !now_value) ~ttl:60. ~cache ~config
      (fun () -> Dashboard_snapshot.Tools_ready (f ())) in
  let first = refresh (fun () -> incr calls; json 1) in
  let raw = Yojson.Safe.to_string (json 1) in
  Alcotest.(check string) "final decorated AST retains exact identity bytes"
    raw first.encoded.identity;
  Alcotest.(check string) "ETag describes final decorated bytes"
    (Http_server_eio.Response.weak_etag_value raw) first.etag;
  Alcotest.(check string) "resolved root captured with projection"
    (Workspace.masc_root_dir config) first.masc_root;
  List.iter (fun (accept_encoding, encoding) ->
    let body, headers = Http_response_payload.select_prepared ~accept_encoding first.encoded in
    Alcotest.(check (option string)) "selected encoding" encoding
      (List.assoc_opt "content-encoding" headers);
    Alcotest.(check (option string)) "all representations vary on encoding"
      (Some "Accept-Encoding") (List.assoc_opt "vary" headers);
    if encoding = Some "zstd" then (
      match Compression_codec.decompress ~orig_size:(String.length raw) body with
      | Ok decoded -> Alcotest.(check string) "compressed final projection roundtrip" raw decoded
      | Error detail -> Alcotest.fail detail);
    now_value := 120.;
    let hit = refresh (fun () -> incr calls; json 2) in
    let again, _ = Http_response_payload.select_prepared ~accept_encoding hit.encoded in
    Alcotest.(check bool) "whole-snapshot tick reuses the component" true (first == hit);
    Alcotest.(check bool) "poll reuses already encoded bytes" true (body == again))
    [ None, None; Some "gzip", Some "gzip"; Some "zstd,gzip", Some "zstd";
      Some "gzip;q=0,zstd;q=0", None ];
  Alcotest.(check int) "one component computation inside TTL" 1 !calls;
  now_value := 160.;
  let retained = refresh (fun () -> failwith "tools refresh failed") in
  Alcotest.(check bool) "failed refresh retains AST and every encoding together" true
    (first == retained);
  let second = refresh (fun () -> incr calls; json 2) in
  Alcotest.(check bool) "successful component refresh replaces ETag" true
    (first.etag <> second.etag);
  Alcotest.(check string) "previous immutable component remains readable" raw first.encoded.identity;
  Alcotest.(check string) "new bytes match new AST" (Yojson.Safe.to_string (json 2)) second.encoded.identity
;;

let test_tools_pending_and_errors_do_not_renew_ready_ttl () =
  let now_value = ref 100. in
  let cache = Dashboard_snapshot.For_testing.make_tools_cache () in
  let refresh result = Dashboard_snapshot.For_testing.refresh_tools
    ~now:(fun () -> !now_value) ~ttl:60. ~cache ~config (fun () -> result) in
  let open Dashboard_snapshot in
  let pending = refresh (Tools_pending (`String "seed")) in
  now_value := 102.;
  let again = refresh (Tools_pending (`String "new seed timestamp")) in
  Alcotest.(check bool) "pending cycles reuse all prepared representations" true
    (pending == again);
  let failed = refresh (Tools_error (`String "timeout")) in
  Alcotest.(check string) "cold failure is visible" "timeout"
    (Yojson.Safe.Util.to_string failed.json);
  let recovered = refresh (Tools_ready (`Assoc [ "tool_inventory", `List [] ])) in
  Alcotest.(check bool) "empty computed inventory promotes immediately" true
    (recovered != failed);
  now_value := 161.9;
  let calls = ref 0 in
  let retained = For_testing.refresh_tools ~now:(fun () -> !now_value)
    ~ttl:60. ~cache ~config (fun () -> incr calls; Tools_pending `Null) in
  Alcotest.(check int) "ready TTL skips the producer" 0 !calls;
  Alcotest.(check bool) "ready TTL retains the exact projection" true (retained == recovered);
  now_value := 162.;
  List.iter (fun result ->
    let retained = refresh result in
    Alcotest.(check bool) "pending/error at expiry retains last ready encodings" true
      (retained == recovered))
    [ Tools_pending (`String "seed after eviction"); Tools_error (`String "timeout") ];
  let retained = For_testing.refresh_tools ~now:(fun () -> !now_value)
    ~ttl:60. ~cache ~config (fun () -> failwith "producer failed") in
  Alcotest.(check bool) "producer failure retains ready encodings" true
    (retained == recovered);
  now_value := 164.;
  let replacement = refresh (Tools_ready (`String "replacement")) in
  Alcotest.(check string) "failures did not renew successful TTL" "replacement"
    (Yojson.Safe.Util.to_string replacement.json)
;;

let () =
  Alcotest.run "Dashboard_snapshot"
    [
      ( "storage",
        [
          Alcotest.test_case "current () empty initially"
            `Quick test_current_starts_empty;
          Alcotest.test_case "publish then current ()"
            `Quick test_publish_then_current;
          Alcotest.test_case "reset clears slot"
            `Quick test_reset_clears_slot;
        ] );
      ( "metadata",
        [
          Alcotest.test_case "generated_at within call window"
            `Quick test_generated_at_recent;
          Alcotest.test_case "projection ttl reuse boundaries"
            `Quick test_projection_ttl_reuse_boundaries;
          Alcotest.test_case "projection cache keeps last good and null"
            `Quick test_projection_cache_retains_last_good_and_successful_null;
          Alcotest.test_case "activity defaults cache keeps last good"
            `Quick test_activity_defaults_cache_retains_last_good;
          Alcotest.test_case "tools component reuses final HTTP representations"
            `Quick test_tools_component_reuses_complete_representations;
          Alcotest.test_case "tools pending and errors never renew the ready TTL"
            `Quick test_tools_pending_and_errors_do_not_renew_ready_ttl;
        ] );
    ]
;;
