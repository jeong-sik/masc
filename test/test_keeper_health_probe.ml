(* Tests for keeper_health_probe.  Pure synchronous tests for the
   cache and cascade ratio logic; the supervisor wiring (run_once
   call site, get_cascade_status branch) is covered by integration
   tests in test_keeper_supervisor.ml. *)

module H = Masc_mcp.Keeper_health_probe
module R = Masc_mcp.Keeper_registry
module KSM = Masc_mcp.Keeper_state_machine

let pressure_label_t = Alcotest.(option string)

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

let make_meta ?cascade_name name =
  let fields =
    [
      ("name", `String name);
      ("agent_name", `String name);
      ("trace_id", `String ("trace-" ^ name));
    ]
  in
  let fields =
    match cascade_name with
    | Some cascade_name -> ("cascade_name", `String cascade_name) :: fields
    | None -> fields
  in
  match Masc_test_deps.meta_of_json_fixture (`Assoc fields) with
  | Ok meta -> meta
  | Error err -> Alcotest.fail ("make_meta failed: " ^ err)
;;

let pressure_label_of_failure_reason reason =
  Option.map
    H.runtime_pressure_class_to_string
    (H.runtime_pressure_class_of_failure_reason (Some reason))
;;

let test_get_cascade_status_default_unknown () =
  Alcotest.check
    status_t
    "cold cascade cache = Unknown"
    H.Unknown
    (H.get_cascade_status ~cascade_name:"never-written-cascade-xyz")
;;

let test_check_cascade_health_all_healthy () =
  let base_dir = Filename.temp_file "probe-" "" in
  Sys.remove base_dir;
  let results = Masc_mcp.Keeper_health_probe.check_cascade_health ~base_path:base_dir in
  Alcotest.(check int) "empty registry = no cascades" 0 (List.length results)
;;

let test_runtime_pressure_classifier () =
  Alcotest.check
    pressure_label_t
    "client capacity"
    (Some "client_capacity_full")
    (pressure_label_of_failure_reason
       (R.Provider_runtime_error
          { code = "capacity_backpressure"
          ; detail = "source=client_capacity; all client slots full"
          ; provider_id = None
          ; http_status = None
          }));
  Alcotest.check
    pressure_label_t
    "tier admission"
    (Some "tier_admission_full")
    (pressure_label_of_failure_reason
       (R.Provider_runtime_error
          { code = "capacity_backpressure"
          ; detail = "inflight_capacity_full tier=strict_tool_candidates"
          ; provider_id = None
          ; http_status = None
          }));
  Alcotest.check
    pressure_label_t
    "provider capacity"
    (Some "provider_capacity")
    (pressure_label_of_failure_reason
       (R.Provider_runtime_error
          { code = "provider_capacity_backpressure"
          ; detail = "rate limit"
          ; provider_id = Some "openai"
          ; http_status = Some 429
          }));
  Alcotest.check
    pressure_label_t
    "provider dns"
    (Some "provider_dns_failure")
    (pressure_label_of_failure_reason
       (R.Provider_runtime_error
          { code = "provider_error"
          ; detail = "getaddrinfo ENOTFOUND api.z.ai"
          ; provider_id = Some "zai"
          ; http_status = None
          }));
  Alcotest.check
    pressure_label_t
    "provider timeout"
    (Some "provider_timeout")
    (pressure_label_of_failure_reason
       (R.Provider_runtime_error
          { code = "provider_error"
          ; detail = "inter_chunk_idle timeout"
          ; provider_id = None
          ; http_status = Some 504
          }));
  Alcotest.check
    pressure_label_t
    "provider error"
    (Some "provider_error")
    (pressure_label_of_failure_reason
       (R.Provider_runtime_error
          { code = "provider_error"
          ; detail = "unexpected provider failure"
          ; provider_id = None
          ; http_status = Some 500
          }));
  Alcotest.check
    pressure_label_t
    "oas timeout"
    (Some "oas_timeout_budget")
    (pressure_label_of_failure_reason (R.Oas_timeout_budget_loop { count = 2 }))
;;

let test_run_once_records_specific_failure_ratio_reason () =
  R.clear ();
  let base_dir = Filename.temp_file "probe-pressure-" "" in
  Sys.remove base_dir;
  let cascade_name =
    Printf.sprintf "probe-provider-dns-%d" (Unix.getpid ())
  in
  let register_crashed name reason =
    let meta = make_meta ~cascade_name name in
    ignore (R.register ~base_path:base_dir name meta);
    R.set_failure_reason ~base_path:base_dir name (Some reason);
    ignore
      (R.dispatch_event
         ~base_path:base_dir
         name
         (KSM.Fiber_terminated
            { outcome = "test"; provider_id = None; http_status = None }))
  in
  Fun.protect
    ~finally:R.clear
    (fun () ->
       register_crashed
         "provider-dns-a"
         (R.Provider_runtime_error
            { code = "provider_error"
            ; detail = "getaddrinfo ENOTFOUND api.z.ai"
            ; provider_id = Some "zai"
            ; http_status = None
            });
       register_crashed
         "provider-dns-b"
         (R.Provider_runtime_error
            { code = "provider_error"
            ; detail = "getaddrinfo ENOTFOUND api.z.ai"
            ; provider_id = Some "zai"
            ; http_status = None
            });
       H.run_once ~base_path:base_dir;
       Alcotest.check
         status_t
         "unhealthy reason carries dominant runtime pressure"
         (H.Unhealthy "failure_ratio:provider_dns_failure")
         (H.get_cascade_status ~cascade_name))
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

(* ------------------------------------------------------------------ *)
(* Size-aware admission threshold                                     *)
(* ------------------------------------------------------------------ *)

let check_max_failed name ~total ~expected =
  Alcotest.(check int)
    (Printf.sprintf "max_failed_allowed N=%d %s" total name)
    expected
    (H.max_failed_allowed_for_cascade ~total)
;;

let test_max_failed_small_cascade_floor () =
  (* N<10: floor of 1 — small cascades must tolerate at least 1 down.
     Regression: the prior ratio<0.10 rule meant N=3 had zero tolerance
     and a single auto-paused keeper became a permanent admission
     block in keeper_supervisor.ml. *)
  check_max_failed "N=0 floors to 1" ~total:0 ~expected:1;
  check_max_failed "N=1 floors to 1" ~total:1 ~expected:1;
  check_max_failed "N=3 floors to 1 (was 0 under ratio<0.10)" ~total:3 ~expected:1;
  check_max_failed "N=9 floors to 1" ~total:9 ~expected:1
;;

let test_max_failed_scales_at_ten_percent () =
  (* N>=10: original 10% scaling preserved. *)
  check_max_failed "N=10 = 1" ~total:10 ~expected:1;
  check_max_failed "N=19 = 1" ~total:19 ~expected:1;
  check_max_failed "N=20 = 2" ~total:20 ~expected:2;
  check_max_failed "N=100 = 10" ~total:100 ~expected:10
;;

let test_max_failed_monotone_nondecreasing () =
  (* As N grows, the allowed-failed count must never shrink.
     Guards against future floor changes that would silently tighten
     admission for some N. *)
  let rec loop prev n =
    if n > 50 then ()
    else
      let cur = H.max_failed_allowed_for_cascade ~total:n in
      Alcotest.(check bool)
        (Printf.sprintf "max_failed N=%d >= N=%d" n (n - 1))
        true
        (cur >= prev);
      loop cur (n + 1)
  in
  loop 0 0
;;

let () =
  Alcotest.run
    "keeper_health_probe"
    [ ( "cache"
      , [ Alcotest.test_case
            "default_status_is_unknown"
            `Quick
            test_get_cascade_status_default_unknown
        ] )
    ; ( "cascade"
      , [ Alcotest.test_case
            "empty_registry_all_healthy"
            `Quick
            test_check_cascade_health_all_healthy
        ; Alcotest.test_case
            "runtime_pressure_classifier"
            `Quick
            test_runtime_pressure_classifier
        ; Alcotest.test_case
            "run_once_records_specific_failure_ratio_reason"
            `Quick
            test_run_once_records_specific_failure_ratio_reason
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
    ; ( "admission_threshold"
      , [ Alcotest.test_case
            "small_cascade_floor_of_one"
            `Quick
            test_max_failed_small_cascade_floor
        ; Alcotest.test_case
            "scales_at_ten_percent"
            `Quick
            test_max_failed_scales_at_ten_percent
        ; Alcotest.test_case
            "monotone_nondecreasing"
            `Quick
            test_max_failed_monotone_nondecreasing
        ] )
    ]
;;
