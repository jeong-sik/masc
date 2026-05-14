(* Tests for keeper_health_probe.  Pure synchronous tests for the
   cache and cascade ratio logic; the supervisor wiring (run_once
   call site, get_cascade_status branch) is covered by integration
   tests in test_keeper_supervisor.ml. *)

module H = Masc_mcp.Keeper_health_probe
module KSM = Masc_mcp.Keeper_state_machine

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
  Alcotest.check
    status_t
    "cold cascade cache = Unknown"
    H.Unknown
    (H.get_cascade_status ~cascade_name:"never-written-cascade-xyz")
;;

let test_is_healthy_unknown () =
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

(* ------------------------------------------------------------------ *)
(* Phase-based health predicate (core regression guard)               *)
(* ------------------------------------------------------------------ *)

let test_terminal_unhealthy_exhaustive () =
  (* Dead / Zombie / Crashed are the ONLY unhealthy phases.
     All 10 remaining phases must return false.
     Uses KSM.all_phases so a newly added variant will fail
     compilation if is_terminal_unhealthy doesn't cover it. *)
  let unhealthy = List.filter H.is_terminal_unhealthy KSM.all_phases in
  let healthy = List.filter (fun p -> not (H.is_terminal_unhealthy p)) KSM.all_phases in
  Alcotest.(check int) "exactly 3 unhealthy phases" 3 (List.length unhealthy);
  Alcotest.(check int) "exactly 10 healthy phases" 10 (List.length healthy);
  List.iter (fun p ->
    Alcotest.(check bool) (KSM.phase_to_string p ^ " is terminal unhealthy")
      true (H.is_terminal_unhealthy p))
    [ KSM.Dead; KSM.Zombie; KSM.Crashed ];
  List.iter (fun p ->
    Alcotest.(check bool) (KSM.phase_to_string p ^ " is NOT terminal unhealthy")
      false (H.is_terminal_unhealthy p))
    [ KSM.Offline; KSM.Running; KSM.Failing; KSM.Overflowed
    ; KSM.Compacting; KSM.HandingOff; KSM.Draining; KSM.Paused
    ; KSM.Stopped; KSM.Restarting ]
;;

let test_restarting_is_healthy () =
  (* Core regression: a keeper mid-recovery (Restarting) must NOT
     pollute its cascade.  The old restart_count > 0 proxy caused
     permanent Unhealthy after any single restart since restart_count
     is monotonic. *)
  Alcotest.(check bool)
    "Restarting phase is NOT terminal unhealthy"
    false
    (H.is_terminal_unhealthy KSM.Restarting)
;;

let test_running_is_healthy () =
  Alcotest.(check bool)
    "Running phase is NOT terminal unhealthy"
    false
    (H.is_terminal_unhealthy KSM.Running)
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
    ; ( "phase_predicate"
      , [ Alcotest.test_case
            "terminal_unhealthy_exhaustive"
            `Quick
            test_terminal_unhealthy_exhaustive
        ; Alcotest.test_case
            "restarting_is_healthy_regression"
            `Quick
            test_restarting_is_healthy
        ; Alcotest.test_case
            "running_is_healthy"
            `Quick
            test_running_is_healthy
        ] )
    ]
;;
