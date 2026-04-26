(** Level2_config Module Coverage Tests

    Tests for MASC Level 2 Configuration - Externalized Constants:
    - Drift_guard, Lock, Hebbian modules
    - to_json: configuration serialization
*)

open Alcotest
module Level2_config = Masc_mcp.Level2_config

(* ============================================================
   Drift_guard Tests
   ============================================================ *)

let test_drift_guard_threshold_default () =
  let threshold = Level2_config.Drift_guard.default_threshold () in
  check bool "threshold in range" true (threshold > 0.0 && threshold <= 1.0)
;;

let test_drift_guard_weights () =
  let weights = Level2_config.Drift_guard.weights () in
  check bool "jaccard positive" true (weights.jaccard > 0.0);
  check bool "cosine positive" true (weights.cosine > 0.0);
  check
    bool
    "weights sum"
    true
    (abs_float (weights.jaccard +. weights.cosine -. 1.0) < 0.01)
;;

(* ============================================================
   Lock Tests
   ============================================================ *)

let test_lock_warn_threshold () =
  let threshold = Level2_config.Lock.warn_threshold_ms () in
  check bool "positive threshold" true (threshold > 0.0)
;;

(* ============================================================
   Hebbian Tests
   ============================================================ *)

let test_hebbian_learning_rate () =
  let rate = Level2_config.Hebbian.learning_rate () in
  check bool "rate in range" true (rate > 0.0 && rate <= 1.0)
;;

let test_hebbian_decay_rate () =
  let rate = Level2_config.Hebbian.decay_rate () in
  check bool "decay positive" true (rate >= 0.0)
;;

let test_hebbian_min_weight () =
  let min_w = Level2_config.Hebbian.min_weight () in
  check bool "min weight positive" true (min_w >= 0.0)
;;

let test_hebbian_max_weight () =
  let max_w = Level2_config.Hebbian.max_weight () in
  check bool "max weight positive" true (max_w > 0.0)
;;

let test_hebbian_min_less_than_max () =
  let min_w = Level2_config.Hebbian.min_weight () in
  let max_w = Level2_config.Hebbian.max_weight () in
  check bool "min < max" true (min_w < max_w)
;;

(* ============================================================
   to_json Tests
   ============================================================ *)

let test_to_json_returns_assoc () =
  let json = Level2_config.to_json () in
  match json with
  | `Assoc _ -> ()
  | _ -> fail "expected Assoc"
;;

let test_to_json_has_drift_threshold () =
  let json = Level2_config.to_json () in
  match json with
  | `Assoc fields ->
    check bool "has drift_threshold" true (List.mem_assoc "drift_threshold" fields)
  | _ -> fail "expected Assoc"
;;

let test_to_json_has_lock_warn () =
  let json = Level2_config.to_json () in
  match json with
  | `Assoc fields ->
    check bool "has lock_warn_ms" true (List.mem_assoc "lock_warn_ms" fields)
  | _ -> fail "expected Assoc"
;;

let test_to_json_has_hebbian_rate () =
  let json = Level2_config.to_json () in
  match json with
  | `Assoc fields ->
    check bool "has hebbian_rate" true (List.mem_assoc "hebbian_rate" fields)
  | _ -> fail "expected Assoc"
;;

let test_to_json_values_positive () =
  let json = Level2_config.to_json () in
  match json with
  | `Assoc fields ->
    List.iter
      (fun (_, v) ->
         match v with
         | `Float f -> check bool "float positive" true (f >= 0.0)
         | `Int i -> check bool "int positive" true (i >= 0)
         | _ -> ())
      fields
  | _ -> fail "expected Assoc"
;;

let test_to_json_has_hebbian_decay () =
  let json = Level2_config.to_json () in
  match json with
  | `Assoc fields ->
    check bool "has hebbian_decay" true (List.mem_assoc "hebbian_decay" fields)
  | _ -> fail "expected Assoc"
;;

(* ============================================================
   print_config Tests
   ============================================================ *)

let test_print_config_no_error () =
  Level2_config.print_config ();
  ()
;;

(* ============================================================
   Test Runners
   ============================================================ *)

let () =
  run
    "Level2_config Coverage"
    [ ( "drift_guard"
      , [ test_case "threshold default" `Quick test_drift_guard_threshold_default
        ; test_case "weights" `Quick test_drift_guard_weights
        ] )
    ; "lock", [ test_case "warn threshold" `Quick test_lock_warn_threshold ]
    ; ( "hebbian"
      , [ test_case "learning rate" `Quick test_hebbian_learning_rate
        ; test_case "decay rate" `Quick test_hebbian_decay_rate
        ; test_case "min weight" `Quick test_hebbian_min_weight
        ; test_case "max weight" `Quick test_hebbian_max_weight
        ; test_case "min < max" `Quick test_hebbian_min_less_than_max
        ] )
    ; ( "to_json"
      , [ test_case "returns assoc" `Quick test_to_json_returns_assoc
        ; test_case "has drift threshold" `Quick test_to_json_has_drift_threshold
        ; test_case "has lock warn" `Quick test_to_json_has_lock_warn
        ; test_case "has hebbian rate" `Quick test_to_json_has_hebbian_rate
        ; test_case "has hebbian decay" `Quick test_to_json_has_hebbian_decay
        ; test_case "values positive" `Quick test_to_json_values_positive
        ] )
    ; "print_config", [ test_case "no error" `Quick test_print_config_no_error ]
    ]
;;
