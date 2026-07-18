(** Tier I4 — Shared types unit tests.

    Verifies the abstract-type invariants and JSON round-trips for
    [Shared_types.{Confidence, Timestamp, Artifact_id}]. *)

open Alcotest

(* ──────────────────────────────────────────────────────────── *)
(* Confidence                                                    *)
(* ──────────────────────────────────────────────────────────── *)

module C = Shared_types.Confidence

let test_confidence_clamps_high () =
  let c = C.make 1.5 in
  check (float 0.0) "clamps to 1.0" 1.0 (C.to_float c)

let test_confidence_clamps_low () =
  let c = C.make (-0.3) in
  check (float 0.0) "clamps to 0.0" 0.0 (C.to_float c)

let test_confidence_clamps_nan () =
  let c = C.make Float.nan in
  check (float 0.0) "NaN → 0.0" 0.0 (C.to_float c)

let test_confidence_passthrough_in_range () =
  let c = C.make 0.42 in
  check (float 1e-12) "stays 0.42" 0.42 (C.to_float c)

let test_confidence_combine_geometric_mean () =
  let a = C.make 0.81 in
  let b = C.make 0.49 in
  let g = C.combine a b in
  (* sqrt(0.81 * 0.49) = sqrt(0.3969) = 0.63 *)
  check (float 1e-9) "geometric mean" 0.63 (C.to_float g)

let test_confidence_combine_with_zero () =
  let a = C.make 0.9 in
  let g = C.combine a C.zero in
  check (float 1e-12) "0 absorbs" 0.0 (C.to_float g)

let test_confidence_json_round_trip () =
  let c = C.make 0.73 in
  let json = C.to_json c in
  match C.of_json json with
  | Ok back -> check (float 1e-12) "round-trip" 0.73 (C.to_float back)
  | Error e -> fail e

let test_confidence_of_json_int () =
  match C.of_json (`Int 1) with
  | Ok c -> check (float 0.0) "int 1 → 1.0" 1.0 (C.to_float c)
  | Error e -> fail e

let test_confidence_of_json_invalid () =
  match C.of_json (`String "0.5") with
  | Ok _ -> fail "should reject string"
  | Error _ -> ()

(* ──────────────────────────────────────────────────────────── *)
(* Timestamp                                                     *)
(* ──────────────────────────────────────────────────────────── *)

module T = Shared_types.Timestamp

let test_timestamp_ordering () =
  let a = T.of_float 1700000000.0 in
  let b = T.of_float 1700000001.0 in
  check int "a < b" (-1) (Int.compare (T.compare a b) 0)

let test_timestamp_now_recent () =
  let n = T.now () in
  check bool "now > 2026-01-01 epoch" true (n > 1735689600.0)

let test_timestamp_json_round_trip () =
  let t = T.of_float 1700000123.456 in
  match T.of_json (T.to_json t) with
  | Ok back -> check (float 1e-9) "round-trip" 1700000123.456 (T.to_float back)
  | Error e -> fail e

(* ──────────────────────────────────────────────────────────── *)
(* Artifact_id (UUID v7)                                         *)
(* ──────────────────────────────────────────────────────────── *)

module A = Shared_types.Artifact_id

let test_artifact_id_generate_format () =
  let id = A.generate () in
  let s = A.to_string id in
  check int "36 chars" 36 (String.length s);
  check char "dash at 8" '-' s.[8];
  check char "dash at 13" '-' s.[13];
  check char "dash at 18" '-' s.[18];
  check char "dash at 23" '-' s.[23];
  check char "version 7" '7' s.[14]

let test_artifact_id_generate_uniqueness () =
  let a = A.generate () in
  let b = A.generate () in
  check bool "different IDs" false (A.equal a b)

let test_artifact_id_round_trip () =
  let original = A.generate () in
  match A.of_string (A.to_string original) with
  | Ok back -> check bool "parse equals generate" true (A.equal original back)
  | Error e -> fail e

let test_artifact_id_of_string_too_short () =
  match A.of_string "short" with
  | Ok _ -> fail "should reject"
  | Error _ -> ()

let test_artifact_id_of_string_wrong_version () =
  let v4 = "01890e2a-4c8e-4b21-9f3c-1234567890ab" in
  match A.of_string v4 with
  | Ok _ -> fail "should reject v4"
  | Error _ -> ()

let test_artifact_id_of_string_missing_dash () =
  let no_dash = "01890e2a04c8e-7b21-9f3c-1234567890abcd" in
  match A.of_string no_dash with
  | Ok _ -> fail "should reject missing dash"
  | Error _ -> ()

let test_artifact_id_of_string_invalid_variant () =
  let bad_variant = "01890e2a-4c8e-7b21-2f3c-1234567890ab" in
  match A.of_string bad_variant with
  | Ok _ -> fail "should reject variant nibble '2'"
  | Error _ -> ()

let test_artifact_id_time_ordering () =
  (* UUID v7 prefix = ms timestamp; sequential generates should sort. *)
  let a = A.generate () in
  Unix.sleepf 0.005;
  let b = A.generate () in
  let cmp = A.compare a b in
  check bool "earlier-generated sorts first" true (cmp < 0)

(* ──────────────────────────────────────────────────────────── *)
(* Suite                                                         *)
(* ──────────────────────────────────────────────────────────── *)

let () =
  Random.self_init ();
  run "Shared_types" [
    "Confidence", [
      test_case "clamps high" `Quick test_confidence_clamps_high;
      test_case "clamps low" `Quick test_confidence_clamps_low;
      test_case "clamps NaN" `Quick test_confidence_clamps_nan;
      test_case "passthrough in range" `Quick test_confidence_passthrough_in_range;
      test_case "combine geometric mean" `Quick test_confidence_combine_geometric_mean;
      test_case "combine with zero" `Quick test_confidence_combine_with_zero;
      test_case "json round-trip" `Quick test_confidence_json_round_trip;
      test_case "of_json int" `Quick test_confidence_of_json_int;
      test_case "of_json rejects string" `Quick test_confidence_of_json_invalid;
    ];
    "Timestamp", [
      test_case "ordering" `Quick test_timestamp_ordering;
      test_case "now is recent" `Quick test_timestamp_now_recent;
      test_case "json round-trip" `Quick test_timestamp_json_round_trip;
    ];
    "Artifact_id", [
      test_case "generate format" `Quick test_artifact_id_generate_format;
      test_case "uniqueness" `Quick test_artifact_id_generate_uniqueness;
      test_case "round-trip" `Quick test_artifact_id_round_trip;
      test_case "of_string too short" `Quick test_artifact_id_of_string_too_short;
      test_case "of_string wrong version" `Quick test_artifact_id_of_string_wrong_version;
      test_case "of_string missing dash" `Quick test_artifact_id_of_string_missing_dash;
      test_case "of_string invalid variant" `Quick test_artifact_id_of_string_invalid_variant;
      test_case "time ordering" `Quick test_artifact_id_time_ordering;
    ];
  ]
