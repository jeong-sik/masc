(** Tier I4 — Shared types unit tests.

    Verifies the abstract-type invariants and JSON round-trips for
    [Shared_types.Artifact_id]. *)

open Alcotest

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

let test_artifact_id_burst_is_monotonic () =
  let generated = List.init 100 (fun _ -> A.generate ()) in
  let rec strictly_increasing = function
    | [] | [ _ ] -> true
    | first :: (second :: _ as rest) ->
      A.compare first second < 0 && strictly_increasing rest
  in
  check bool "serialized generation is monotonic" true
    (strictly_increasing generated)

let test_uuid_v7_clock_clamps_wall_clock_rollback () =
  let observations = ref [ 1_000L; 999L; 1_000L; 1_001L ] in
  let raw_now_ms () =
    match !observations with
    | value :: rest ->
      observations := rest;
      value
    | [] -> fail "clock fixture exhausted"
  in
  let now_ms, advance = Random_id.For_testing.logical_ms_clock raw_now_ms in
  check int64 "first observation" 1_000L (now_ms ());
  check int64 "rollback clamps to last timestamp" 1_000L (now_ms ());
  advance ();
  check int64 "counter exhaustion advances logical time" 1_001L (now_ms ());
  check int64 "wall time resumes without regression" 1_001L (now_ms ())

(* ──────────────────────────────────────────────────────────── *)
(* Suite                                                         *)
(* ──────────────────────────────────────────────────────────── *)

let () =
  Random.self_init ();
  run "Shared_types" [
    "Artifact_id", [
      test_case "generate format" `Quick test_artifact_id_generate_format;
      test_case "uniqueness" `Quick test_artifact_id_generate_uniqueness;
      test_case "round-trip" `Quick test_artifact_id_round_trip;
      test_case "of_string too short" `Quick test_artifact_id_of_string_too_short;
      test_case "of_string wrong version" `Quick test_artifact_id_of_string_wrong_version;
      test_case "of_string missing dash" `Quick test_artifact_id_of_string_missing_dash;
      test_case "of_string invalid variant" `Quick test_artifact_id_of_string_invalid_variant;
      test_case "time ordering" `Quick test_artifact_id_time_ordering;
      test_case "burst is monotonic" `Quick test_artifact_id_burst_is_monotonic;
      test_case "wall-clock rollback is clamped" `Quick
        test_uuid_v7_clock_clamps_wall_clock_rollback;
    ];
  ]
