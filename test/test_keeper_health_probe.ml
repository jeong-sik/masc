(* Tests for keeper_health_probe.  Pure synchronous tests for the
   cache and cascade ratio logic; the async fiber is covered by
   integration tests in test_keeper_supervisor.ml. *)

let test_is_healthy_unknown () =
  Alcotest.(check bool) "unknown = false" false
    (Masc_mcp.Keeper_health_probe.is_healthy ~keeper_name:"k1")

let test_check_cascade_health_all_healthy () =
  (* With 0 registry entries, every cascade has 0/0 failures = healthy. *)
  let base_dir = Filename.temp_file "probe-" "" in
  Sys.remove base_dir;
  let results =
    Masc_mcp.Keeper_health_probe.check_cascade_health
      ~base_path:base_dir
  in
  Alcotest.(check int) "empty registry = no cascades" 0
    (List.length results)

let () =
  Alcotest.run "keeper_health_probe" [
    "cache", [
      Alcotest.test_case "unknown_is_false" `Quick
        test_is_healthy_unknown;
    ];
    "cascade", [
      Alcotest.test_case "empty_registry_all_healthy" `Quick
        test_check_cascade_health_all_healthy;
    ];
  ]
