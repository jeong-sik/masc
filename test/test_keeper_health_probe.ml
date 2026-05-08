(* Tests for keeper_health_probe.  Pure synchronous tests for the
   cache and cascade ratio logic; the supervisor wiring (run_once
   call site, get_cascade_status branch) is covered by integration
   tests in test_keeper_supervisor.ml. *)

module H = Masc_mcp.Keeper_health_probe

let pp_status fmt = function
  | H.Unknown -> Format.fprintf fmt "Unknown"
  | H.Healthy -> Format.fprintf fmt "Healthy"
  | H.Unhealthy r -> Format.fprintf fmt "Unhealthy(%s)" r
;;

let status_eq a b =
  match a, b with
  | H.Unknown, H.Unknown -> true
  | H.Healthy, H.Healthy -> true
  | H.Unhealthy x, H.Unhealthy y -> String.equal x y
  | _ -> false
;;

let status_t = Alcotest.testable pp_status status_eq

let test_get_cascade_status_default_unknown () =
  (* Cold-cache regression: a cascade name never written must return
     Unknown.  Before [get_cascade_status] existed, the supervisor
     consulted [is_healthy] which collapses Unknown to false — turning
     the boot-time race window into a permanent auto-resume lockout
     for every keeper paused with [auto_resume_after_sec].  See PR
     #14146 + supervisor Phase 3.5. *)
  Alcotest.check
    status_t
    "cold cascade cache = Unknown"
    H.Unknown
    (H.get_cascade_status ~cascade_name:"never-written-cascade-xyz")
;;

let test_is_healthy_unknown () =
  (* Backward-compat shim returns false on Unknown — kept to document
     the old behavior callers should migrate away from. *)
  Alcotest.(check bool)
    "is_healthy on uninitialized keeper = false"
    false
    (Masc_mcp.Keeper_health_probe.is_healthy ~keeper_name:"k1-never-set")
;;

let test_check_cascade_health_all_healthy () =
  let base_dir = Filename.temp_file "probe-" "" in
  Sys.remove base_dir;
  let results = Masc_mcp.Keeper_health_probe.check_cascade_health ~base_path:base_dir in
  Alcotest.(check int) "empty registry = no cascades" 0 (List.length results)
;;

let () =
  Alcotest.run
    "keeper_health_probe"
    [ ( "cache"
      , [ Alcotest.test_case
            "default_status_is_unknown"
            `Quick
            test_get_cascade_status_default_unknown
        ; Alcotest.test_case "is_healthy_unknown_compat" `Quick test_is_healthy_unknown
        ] )
    ; ( "cascade"
      , [ Alcotest.test_case
            "empty_registry_all_healthy"
            `Quick
            test_check_cascade_health_all_healthy
        ] )
    ]
;;
