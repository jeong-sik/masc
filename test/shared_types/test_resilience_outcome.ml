(** Tier I5 — Resilience_outcome stub GADT unit tests.

    Verifies the three-class outcome contract, defensive level clamping,
    extraction helpers, and result-lifting. *)

open Alcotest

module RO = Shared_types.Resilience_outcome
module C = Shared_types.Confidence
module AID = Shared_types.Artifact_id

(* String error type to satisfy the 'e parameter in tests. *)

(* ──────────────────────────────────────────────────────────── *)
(* Constructors + predicates                                     *)
(* ──────────────────────────────────────────────────────────── *)

let test_full_constructor () =
  let id = AID.generate () in
  let o = RO.full ~value:42 ~confidence:C.one ~artifacts:[ id ] in
  check bool "is_full" true (RO.is_full o);
  check bool "not partial" false (RO.is_partial o);
  check bool "not graceful" false (RO.is_graceful o);
  check (option int) "value extracted" (Some 42) (RO.value_opt o)

let test_partial_constructor () =
  let id_ok = AID.generate () in
  let id_fail = AID.generate () in
  let o : (int, string) RO.t =
    RO.partial
      ~value:7
      ~completed:[ id_ok ]
      ~failed:[ id_fail, "boom" ]
      ~confidence:(C.make 0.6)
      ~degradation_level:2
  in
  check bool "is_partial" true (RO.is_partial o);
  check bool "not full" false (RO.is_full o);
  check (option int) "value extracted" (Some 7) (RO.value_opt o)

let test_graceful_with_fallback () =
  let o : (int, string) RO.t =
    RO.graceful
      ~fallback:99
      ~reason:"network timeout"
      ~recovery_strategy:"Retry"
      ~confidence:(C.make 0.3)
      ()
  in
  check bool "is_graceful" true (RO.is_graceful o);
  check (option int) "fallback exposed" (Some 99) (RO.value_opt o)

let test_graceful_without_fallback () =
  let o : (int, string) RO.t =
    RO.graceful
      ~reason:"unrecoverable"
      ~recovery_strategy:"Handoff"
      ~confidence:C.zero
      ()
  in
  check bool "is_graceful" true (RO.is_graceful o);
  check (option int) "no fallback" None (RO.value_opt o)

(* ──────────────────────────────────────────────────────────── *)
(* Defensive degradation_level clamp                             *)
(* ──────────────────────────────────────────────────────────── *)

let assert_partial_level expected o =
  match (o : (int, string) RO.t) with
  | RO.PartialSuccess { degradation_level; _ } ->
    check int "level clamped" expected degradation_level
  | _ -> fail "expected PartialSuccess"

let test_partial_clamps_low () =
  RO.partial ~value:1 ~completed:[] ~failed:[]
    ~confidence:C.one ~degradation_level:0
  |> assert_partial_level 1

let test_partial_clamps_high () =
  RO.partial ~value:1 ~completed:[] ~failed:[]
    ~confidence:C.one ~degradation_level:9
  |> assert_partial_level 4

let test_partial_passthrough_in_range () =
  RO.partial ~value:1 ~completed:[] ~failed:[]
    ~confidence:C.one ~degradation_level:3
  |> assert_partial_level 3

(* ──────────────────────────────────────────────────────────── *)
(* Confidence extraction                                          *)
(* ──────────────────────────────────────────────────────────── *)

let test_confidence_extraction () =
  let o_full : (int, string) RO.t =
    RO.full ~value:1 ~confidence:(C.make 0.9) ~artifacts:[]
  in
  let o_partial : (int, string) RO.t =
    RO.partial ~value:1 ~completed:[] ~failed:[]
      ~confidence:(C.make 0.5) ~degradation_level:2
  in
  let o_graceful : (int, string) RO.t =
    RO.graceful ~reason:"x" ~recovery_strategy:"Abort"
      ~confidence:(C.make 0.1) ()
  in
  check (float 1e-9) "full confidence" 0.9 (C.to_float (RO.confidence o_full));
  check (float 1e-9) "partial confidence" 0.5 (C.to_float (RO.confidence o_partial));
  check (float 1e-9) "graceful confidence" 0.1 (C.to_float (RO.confidence o_graceful))

(* ──────────────────────────────────────────────────────────── *)
(* map                                                            *)
(* ──────────────────────────────────────────────────────────── *)

let test_map_full_preserves_class () =
  let o : (int, string) RO.t = RO.full ~value:3 ~confidence:C.one ~artifacts:[] in
  let o' = RO.map (fun n -> n * 10) o in
  check bool "still full" true (RO.is_full o');
  check (option int) "mapped value" (Some 30) (RO.value_opt o')

let test_map_graceful_maps_fallback () =
  let o : (int, string) RO.t =
    RO.graceful ~fallback:5 ~reason:"x" ~recovery_strategy:"Retry"
      ~confidence:C.zero ()
  in
  let o' = RO.map (fun n -> n + 100) o in
  check bool "still graceful" true (RO.is_graceful o');
  check (option int) "fallback mapped" (Some 105) (RO.value_opt o')

let test_map_graceful_without_fallback_stays_none () =
  let o : (int, string) RO.t =
    RO.graceful ~reason:"x" ~recovery_strategy:"Abort" ~confidence:C.zero ()
  in
  let o' = RO.map (fun n -> n * 2) o in
  check (option int) "no fallback" None (RO.value_opt o')

(* ──────────────────────────────────────────────────────────── *)
(* cata                                                           *)
(* ──────────────────────────────────────────────────────────── *)

let test_cata_dispatches_correctly () =
  let label : (int, string) RO.t -> string =
    RO.cata
      ~full:(fun _ _ _ -> "full")
      ~partial:(fun _ _ _ _ _ -> "partial")
      ~graceful:(fun _ _ _ _ -> "graceful")
  in
  let f : (int, string) RO.t = RO.full ~value:1 ~confidence:C.one ~artifacts:[] in
  let p : (int, string) RO.t =
    RO.partial ~value:1 ~completed:[] ~failed:[]
      ~confidence:C.one ~degradation_level:2
  in
  let g : (int, string) RO.t =
    RO.graceful ~reason:"x" ~recovery_strategy:"Abort" ~confidence:C.zero ()
  in
  check string "full" "full" (label f);
  check string "partial" "partial" (label p);
  check string "graceful" "graceful" (label g)

(* ──────────────────────────────────────────────────────────── *)
(* lift_result                                                    *)
(* ──────────────────────────────────────────────────────────── *)

let test_lift_result_ok () =
  let o : (int, string) RO.t = RO.lift_result (Ok 42) in
  check bool "Ok lifts to FullSuccess" true (RO.is_full o);
  check (option int) "value preserved" (Some 42) (RO.value_opt o);
  check (float 1e-9) "default confidence 1.0" 1.0 (C.to_float (RO.confidence o))

let test_lift_result_ok_with_confidence () =
  let o : (int, string) RO.t =
    RO.lift_result ~confidence:(C.make 0.7) (Ok 1)
  in
  check (float 1e-9) "custom confidence" 0.7 (C.to_float (RO.confidence o))

let test_lift_result_error () =
  let o : (int, string) RO.t = RO.lift_result (Error "boom") in
  check bool "Error lifts to GracefulFailure" true (RO.is_graceful o);
  check (option int) "no fallback" None (RO.value_opt o);
  check (float 1e-9) "zero confidence" 0.0 (C.to_float (RO.confidence o))

(* ──────────────────────────────────────────────────────────── *)
(* class_to_string                                                *)
(* ──────────────────────────────────────────────────────────── *)

let test_class_to_string () =
  let f : (int, string) RO.t = RO.full ~value:1 ~confidence:C.one ~artifacts:[] in
  let p : (int, string) RO.t =
    RO.partial ~value:1 ~completed:[] ~failed:[]
      ~confidence:C.one ~degradation_level:1
  in
  let g : (int, string) RO.t =
    RO.graceful ~reason:"x" ~recovery_strategy:"Abort" ~confidence:C.zero ()
  in
  check string "full label" "FullSuccess" (RO.class_to_string f);
  check string "partial label" "PartialSuccess" (RO.class_to_string p);
  check string "graceful label" "GracefulFailure" (RO.class_to_string g)

(* ──────────────────────────────────────────────────────────── *)
(* Suite                                                          *)
(* ──────────────────────────────────────────────────────────── *)

let () =
  run "Resilience_outcome (stub)" [
    "Constructors", [
      test_case "full" `Quick test_full_constructor;
      test_case "partial" `Quick test_partial_constructor;
      test_case "graceful with fallback" `Quick test_graceful_with_fallback;
      test_case "graceful without fallback" `Quick test_graceful_without_fallback;
    ];
    "Defensive level clamp", [
      test_case "clamps below 1" `Quick test_partial_clamps_low;
      test_case "clamps above 4" `Quick test_partial_clamps_high;
      test_case "passthrough in range" `Quick test_partial_passthrough_in_range;
    ];
    "Extraction", [
      test_case "confidence by class" `Quick test_confidence_extraction;
    ];
    "map", [
      test_case "full preserves class" `Quick test_map_full_preserves_class;
      test_case "graceful maps fallback" `Quick test_map_graceful_maps_fallback;
      test_case "graceful without fallback stays None" `Quick
        test_map_graceful_without_fallback_stays_none;
    ];
    "cata", [
      test_case "dispatches correctly" `Quick test_cata_dispatches_correctly;
    ];
    "lift_result", [
      test_case "Ok → FullSuccess" `Quick test_lift_result_ok;
      test_case "Ok with custom confidence" `Quick test_lift_result_ok_with_confidence;
      test_case "Error → GracefulFailure" `Quick test_lift_result_error;
    ];
    "class_to_string", [
      test_case "labels all three" `Quick test_class_to_string;
    ];
  ]
