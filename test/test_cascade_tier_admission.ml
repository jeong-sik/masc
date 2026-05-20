(** Unit tests for [Masc_mcp.Cascade_tier_admission].

    RFC-0153 Phase B.1. Tests the module-level contract:
    - [Bypass] policy: never touches the inflight counter, always
      runs [f].
    - [Required] policy: respects capacity, increments+decrements
      counter, returns typed [Cascade_saturation_signal.t] on
      capacity_full.
    - Exception safety: counter is released even when [f] raises.
    - Lazy tier creation: unseen tier uses the default capacity. *)

open Alcotest

module A = Masc_mcp.Cascade_tier_admission
module S = Masc_mcp.Cascade_saturation_signal
module KTD = Masc_mcp.Keeper_turn_driver.For_testing

let signal_testable = testable S.pp S.equal

let int_check msg expected actual =
  check int msg expected actual

let bool_check msg expected actual =
  check bool msg expected actual

(* {1 Construction and configuration} *)

let test_create_default_capacity () =
  let t = A.create () in
  int_check "default max 8 on unseen tier" 8
    (A.configured_max t ~tier_id:"unseen")

let test_create_custom_default () =
  let t = A.create ~default_max_inflight:16 () in
  int_check "custom default 16 on unseen tier" 16
    (A.configured_max t ~tier_id:"any")

let test_configure_overrides_default () =
  let t = A.create ~default_max_inflight:8 () in
  A.configure t ~tier_id:"hot" ~max_inflight:4;
  int_check "configure overrides default" 4
    (A.configured_max t ~tier_id:"hot");
  int_check "other tier still default" 8
    (A.configured_max t ~tier_id:"cold")

let test_current_inflight_starts_zero () =
  let t = A.create () in
  int_check "inflight = 0 on unseen tier" 0
    (A.current_inflight t ~tier_id:"unseen")

(* {1 Bypass policy} *)

let test_bypass_runs_function () =
  let t = A.create ~default_max_inflight:1 () in
  let invocations = ref 0 in
  let result =
    A.with_admission t ~tier_id:"saturated"
      ~admission_policy:A.Bypass
      (fun () ->
        incr invocations;
        "value")
  in
  (match result with
   | Ok v -> check string "bypass returns f result" "value" v
   | Error _ -> Alcotest.fail "bypass returned Error");
  int_check "f called once" 1 !invocations

let test_bypass_does_not_touch_inflight () =
  let t = A.create ~default_max_inflight:1 () in
  let _ =
    A.with_admission t ~tier_id:"tier-x"
      ~admission_policy:A.Bypass
      (fun () -> ())
  in
  int_check "inflight unchanged" 0
    (A.current_inflight t ~tier_id:"tier-x")

let test_bypass_works_at_saturation () =
  let t = A.create ~default_max_inflight:0 () in
  (* default 0 = always capacity_full for Required, but Bypass should still work *)
  let result =
    A.with_admission t ~tier_id:"any"
      ~admission_policy:A.Bypass
      (fun () -> 42)
  in
  match result with
  | Ok v -> int_check "bypass succeeded at 0-capacity tier" 42 v
  | Error _ -> Alcotest.fail "bypass blocked at 0-capacity tier"

(* {1 Required policy — capacity available} *)

let test_required_within_capacity () =
  let t = A.create ~default_max_inflight:2 () in
  let result =
    A.with_admission t ~tier_id:"main"
      ~admission_policy:A.Required
      (fun () -> "ok")
  in
  match result with
  | Error _ -> Alcotest.fail "Required failed within capacity"
  | Ok v ->
      check string "Required returned f result" "ok" v;
      int_check "inflight released after success" 0
        (A.current_inflight t ~tier_id:"main")

(* {1 Required policy — capacity full} *)

let test_required_at_capacity_full () =
  let t = A.create ~default_max_inflight:1 () in
  (* Manually acquire so the next Required hit is capacity_full *)
  (match A.try_acquire t ~tier_id:"main" with
   | Granted _ -> ()
   | Capacity_full _ -> Alcotest.fail "expected first acquire to succeed");
  let result =
    A.with_admission t ~tier_id:"main"
      ~admission_policy:A.Required
      (fun () -> Alcotest.fail "f should not run at capacity_full")
  in
  match result with
  | Ok _ -> Alcotest.fail "Required should have rejected"
  | Error (S.Inflight_capacity_full { tier_id; max_inflight }) ->
      check string "tier_id echoed" "main" tier_id;
      int_check "max_inflight echoed" 1 max_inflight
  | Error _other -> Alcotest.fail "wrong signal variant"

(* {1 Exception safety} *)

exception Test_exn

let test_required_releases_on_exception () =
  let t = A.create ~default_max_inflight:1 () in
  let raised = ref false in
  (try
     let _ =
       A.with_admission t ~tier_id:"main"
         ~admission_policy:A.Required
         (fun () -> raise Test_exn)
     in
     Alcotest.fail "exception should have propagated"
   with Test_exn -> raised := true);
  bool_check "exception propagated" true !raised;
  int_check "counter released on exception" 0
    (A.current_inflight t ~tier_id:"main")

(* {1 try_acquire / release low-level pair} *)

let test_try_acquire_release_pair () =
  let t = A.create ~default_max_inflight:2 () in
  (match A.try_acquire t ~tier_id:"t1" with
   | Granted { inflight_after_acquire = 1; max_inflight = 2 } -> ()
   | _ -> Alcotest.fail "expected Granted {1, 2}");
  (match A.try_acquire t ~tier_id:"t1" with
   | Granted { inflight_after_acquire = 2; max_inflight = 2 } -> ()
   | _ -> Alcotest.fail "expected Granted {2, 2}");
  (match A.try_acquire t ~tier_id:"t1" with
   | Capacity_full { inflight_at_check = 2; max_inflight = 2 } -> ()
   | _ -> Alcotest.fail "expected Capacity_full {2, 2}");
  A.release t ~tier_id:"t1";
  int_check "inflight 1 after one release" 1
    (A.current_inflight t ~tier_id:"t1");
  A.release t ~tier_id:"t1";
  int_check "inflight 0 after two releases" 0
    (A.current_inflight t ~tier_id:"t1");
  (* extra release is no-op at floor *)
  A.release t ~tier_id:"t1";
  int_check "inflight 0 after extra release (floor)" 0
    (A.current_inflight t ~tier_id:"t1")

let test_release_unknown_tier_is_noop () =
  let t = A.create () in
  A.release t ~tier_id:"never-acquired";
  int_check "unknown tier inflight stays 0" 0
    (A.current_inflight t ~tier_id:"never-acquired")

(* {1 Per-tier isolation} *)

let test_tiers_are_independent () =
  let t = A.create ~default_max_inflight:1 () in
  (match A.try_acquire t ~tier_id:"A" with
   | Granted _ -> ()
   | Capacity_full _ -> Alcotest.fail "A acquire failed");
  (match A.try_acquire t ~tier_id:"B" with
   | Granted _ -> ()
   | Capacity_full _ -> Alcotest.fail "B acquire failed");
  int_check "A inflight 1" 1 (A.current_inflight t ~tier_id:"A");
  int_check "B inflight 1" 1 (A.current_inflight t ~tier_id:"B");
  A.release t ~tier_id:"A";
  int_check "A released, B unchanged" 1
    (A.current_inflight t ~tier_id:"B");
  int_check "A released to 0" 0 (A.current_inflight t ~tier_id:"A")

(* {1 Keeper turn driver wire-in} *)

let test_keeper_policy_proactive_required () =
  match
    KTD.cascade_tier_admission_policy_of_priority
      Llm_provider.Request_priority.Proactive
  with
  | A.Required -> ()
  | A.Bypass -> Alcotest.fail "proactive keeper turns must require admission"

let test_keeper_policy_interactive_required () =
  match
    KTD.cascade_tier_admission_policy_of_priority
      Llm_provider.Request_priority.Interactive
  with
  | A.Required -> ()
  | A.Bypass -> Alcotest.fail "interactive keeper turns must require admission"

let test_keeper_policy_background_bypass () =
  match
    KTD.cascade_tier_admission_policy_of_priority
      Llm_provider.Request_priority.Background
  with
  | A.Bypass -> ()
  | A.Required -> Alcotest.fail "background side tasks must bypass admission"

let test_keeper_wire_enabled_rejects_at_capacity () =
  let t = A.create ~default_max_inflight:1 () in
  (match A.try_acquire t ~tier_id:"keeper-turn" with
   | A.Granted _ -> ()
   | A.Capacity_full _ -> Alcotest.fail "expected setup acquire to succeed");
  let ran = ref false in
  let result =
    KTD.with_cascade_tier_admission_for_testing
      ~admission:t
      ~enabled:true
      ~tier_id:"keeper-turn"
      ~admission_policy:A.Required
      (fun () ->
         ran := true;
         ())
  in
  bool_check "provider attempt not run at capacity" false !ran;
  (match result with
   | Ok () -> Alcotest.fail "expected tier admission rejection"
   | Error (S.Inflight_capacity_full { tier_id; max_inflight }) ->
       check string "tier id echoed" "keeper-turn" tier_id;
       int_check "max inflight echoed" 1 max_inflight
   | Error _ -> Alcotest.fail "wrong saturation signal");
  A.release t ~tier_id:"keeper-turn"

let test_keeper_wire_disabled_is_passthrough () =
  let t = A.create ~default_max_inflight:0 () in
  let ran = ref false in
  let admission_result =
    KTD.with_cascade_tier_admission_for_testing
      ~admission:t
      ~enabled:false
      ~tier_id:"keeper-turn"
      ~admission_policy:A.Required
      (fun () ->
         ran := true;
         "ok")
  in
  bool_check "attempt ran when flag disabled" true !ran;
  check
    (result string signal_testable)
    "disabled flag passthrough"
    (Ok "ok")
    admission_result;
  int_check "disabled path did not touch counter" 0
    (A.current_inflight t ~tier_id:"keeper-turn")

let test_keeper_wire_bypass_policy_is_passthrough () =
  let t = A.create ~default_max_inflight:0 () in
  let admission_result =
    KTD.with_cascade_tier_admission_for_testing
      ~admission:t
      ~enabled:true
      ~tier_id:"keeper-turn"
      ~admission_policy:A.Bypass
      (fun () -> 7)
  in
  check
    (result int signal_testable)
    "bypass policy passthrough"
    (Ok 7)
    admission_result;
  int_check "bypass path did not touch counter" 0
    (A.current_inflight t ~tier_id:"keeper-turn")

(* {1 driver} *)

let suite =
  [ ( "construct",
      [ test_case "default capacity" `Quick test_create_default_capacity;
        test_case "custom default" `Quick test_create_custom_default;
        test_case "configure overrides" `Quick
          test_configure_overrides_default;
        test_case "inflight starts zero" `Quick
          test_current_inflight_starts_zero;
      ] );
    ( "bypass",
      [ test_case "runs function" `Quick test_bypass_runs_function;
        test_case "no counter touch" `Quick
          test_bypass_does_not_touch_inflight;
        test_case "works at saturation" `Quick
          test_bypass_works_at_saturation;
      ] );
    ( "required",
      [ test_case "within capacity" `Quick test_required_within_capacity;
        test_case "capacity full" `Quick test_required_at_capacity_full;
        test_case "release on exception" `Quick
          test_required_releases_on_exception;
      ] );
    ( "low-level",
      [ test_case "acquire/release pair" `Quick
          test_try_acquire_release_pair;
        test_case "release unknown noop" `Quick
          test_release_unknown_tier_is_noop;
      ] );
    ( "isolation",
      [ test_case "tiers independent" `Quick test_tiers_are_independent ] );
    ( "keeper-wire",
      [ test_case "proactive maps to Required" `Quick
          test_keeper_policy_proactive_required;
        test_case "interactive maps to Required" `Quick
          test_keeper_policy_interactive_required;
        test_case "background maps to Bypass" `Quick
          test_keeper_policy_background_bypass;
        test_case "enabled path rejects at capacity" `Quick
          test_keeper_wire_enabled_rejects_at_capacity;
        test_case "disabled flag is passthrough" `Quick
          test_keeper_wire_disabled_is_passthrough;
        test_case "bypass policy is passthrough" `Quick
          test_keeper_wire_bypass_policy_is_passthrough;
      ] );
  ]

let () = Alcotest.run "cascade_tier_admission" suite
