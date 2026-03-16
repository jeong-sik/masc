(** Tests for Lodge_personality module — mood/trait to temperature mapping *)

open Alcotest
open Masc_mcp

(* Helpers *)
let float_eps = 0.001
let check_float_approx msg expected actual =
  check bool msg true (Float.abs (expected -. actual) < float_eps)

(* {1 Temperature computation tests} *)

let test_temperature_skeptical () =
  let t = Lodge_personality.compute_temperature
    ~mood:Lodge_daemon.Skeptical ~curiosity:0.3 in
  check_float_approx "skeptical + low curiosity = 0.3" 0.3 t

let test_temperature_neutral () =
  let t = Lodge_personality.compute_temperature
    ~mood:Lodge_daemon.Neutral ~curiosity:0.3 in
  check_float_approx "neutral + low curiosity = 0.5" 0.5 t

let test_temperature_excited () =
  let t = Lodge_personality.compute_temperature
    ~mood:Lodge_daemon.Excited ~curiosity:0.3 in
  check_float_approx "excited + low curiosity = 0.8" 0.8 t

let test_temperature_curious_high_curiosity () =
  let t = Lodge_personality.compute_temperature
    ~mood:Lodge_daemon.Curious ~curiosity:0.9 in
  check_float_approx "curious + high curiosity = 0.75" 0.75 t

let test_temperature_satisfied_high_curiosity () =
  let t = Lodge_personality.compute_temperature
    ~mood:Lodge_daemon.Satisfied ~curiosity:0.8 in
  check_float_approx "satisfied + high curiosity = 0.5" 0.5 t

let test_temperature_excited_max_curiosity () =
  let t = Lodge_personality.compute_temperature
    ~mood:Lodge_daemon.Excited ~curiosity:1.0 in
  check_float_approx "excited + max curiosity = 0.9" 0.9 t

let test_temperature_clamped_at_1 () =
  (* Even with max mood + bonus, should not exceed 1.0 *)
  let t = Lodge_personality.compute_temperature
    ~mood:Lodge_daemon.Excited ~curiosity:1.0 in
  check bool "temperature <= 1.0" true (t <= 1.0)

let test_temperature_boundary_curiosity () =
  (* curiosity exactly 0.7 should NOT trigger bonus (> 0.7 required) *)
  let t = Lodge_personality.compute_temperature
    ~mood:Lodge_daemon.Neutral ~curiosity:0.7 in
  check_float_approx "curiosity=0.7 no bonus" 0.5 t;
  (* curiosity 0.71 should trigger bonus *)
  let t2 = Lodge_personality.compute_temperature
    ~mood:Lodge_daemon.Neutral ~curiosity:0.71 in
  check_float_approx "curiosity=0.71 has bonus" 0.6 t2

(* {1 Full mood/temperature table} *)

let test_temperature_table () =
  let cases = [
    (Lodge_daemon.Excited,   0.3, 0.8);
    (Lodge_daemon.Excited,   0.9, 0.9);
    (Lodge_daemon.Curious,   0.3, 0.65);
    (Lodge_daemon.Curious,   0.9, 0.75);
    (Lodge_daemon.Neutral,   0.3, 0.5);
    (Lodge_daemon.Neutral,   0.9, 0.6);
    (Lodge_daemon.Satisfied, 0.3, 0.4);
    (Lodge_daemon.Satisfied, 0.9, 0.5);
    (Lodge_daemon.Skeptical, 0.3, 0.3);
    (Lodge_daemon.Skeptical, 0.9, 0.4);
  ] in
  List.iter (fun (mood, curiosity, expected) ->
    let actual = Lodge_personality.compute_temperature ~mood ~curiosity in
    let label = Printf.sprintf "%s/%.1f"
      (Lodge_daemon.string_of_mood mood) curiosity in
    check_float_approx label expected actual
  ) cases

(* {1 OAS Context roundtrip tests} *)

let test_context_store_read_mood () =
  let ctx = Agent_sdk.Context.create () in
  Lodge_personality.store_in_context ctx
    ~mood:Lodge_daemon.Curious ~curiosity:0.8;
  let mood = Lodge_personality.read_mood_from_context ctx in
  check bool "mood roundtrip" true (mood = Some Lodge_daemon.Curious)

let test_context_store_read_curiosity () =
  let ctx = Agent_sdk.Context.create () in
  Lodge_personality.store_in_context ctx
    ~mood:Lodge_daemon.Neutral ~curiosity:0.65;
  let cur = Lodge_personality.read_curiosity_from_context ctx in
  match cur with
  | Some f -> check_float_approx "curiosity roundtrip" 0.65 f
  | None -> fail "curiosity should be Some"

let test_context_empty_read () =
  let ctx = Agent_sdk.Context.create () in
  let mood = Lodge_personality.read_mood_from_context ctx in
  let cur = Lodge_personality.read_curiosity_from_context ctx in
  check bool "empty mood is None" true (mood = None);
  check bool "empty curiosity is None" true (cur = None)

let test_context_overwrite () =
  let ctx = Agent_sdk.Context.create () in
  Lodge_personality.store_in_context ctx
    ~mood:Lodge_daemon.Excited ~curiosity:0.9;
  Lodge_personality.store_in_context ctx
    ~mood:Lodge_daemon.Skeptical ~curiosity:0.2;
  let mood = Lodge_personality.read_mood_from_context ctx in
  check bool "overwritten mood" true (mood = Some Lodge_daemon.Skeptical)

(* {1 Lodge_atmosphere dynamic mood tests} *)

let test_atmosphere_compute_mood_extremes () =
  (* High positive ratio + high activity → Excited or Curious *)
  let mood_high = Lodge_atmosphere.compute_mood
    ~positive_ratio:1.0 ~activity_level:1.0 in
  let s = Lodge_daemon.string_of_mood mood_high in
  check bool "high signals → excited or curious"
    true (s = "excited" || s = "curious");
  (* Low everything → Skeptical or Satisfied *)
  let mood_low = Lodge_atmosphere.compute_mood
    ~positive_ratio:0.0 ~activity_level:0.0 in
  let s2 = Lodge_daemon.string_of_mood mood_low in
  check bool "low signals → skeptical or satisfied"
    true (s2 = "skeptical" || s2 = "satisfied" || s2 = "neutral")

let test_atmosphere_default_returns_mood () =
  (* Just verify it returns a valid mood without crashing *)
  let mood = Lodge_atmosphere.compute_mood_default () in
  let s = Lodge_daemon.string_of_mood mood in
  check bool "default mood is valid" true (String.length s > 0)

(* {1 Test runner} *)

let () =
  run "Lodge_personality" [
    "compute_temperature", [
      test_case "skeptical base" `Quick test_temperature_skeptical;
      test_case "neutral base" `Quick test_temperature_neutral;
      test_case "excited base" `Quick test_temperature_excited;
      test_case "curious + high curiosity" `Quick test_temperature_curious_high_curiosity;
      test_case "satisfied + high curiosity" `Quick test_temperature_satisfied_high_curiosity;
      test_case "excited + max curiosity" `Quick test_temperature_excited_max_curiosity;
      test_case "clamped at 1.0" `Quick test_temperature_clamped_at_1;
      test_case "boundary curiosity 0.7" `Quick test_temperature_boundary_curiosity;
      test_case "full table" `Quick test_temperature_table;
    ];
    "oas_context", [
      test_case "store/read mood" `Quick test_context_store_read_mood;
      test_case "store/read curiosity" `Quick test_context_store_read_curiosity;
      test_case "empty read" `Quick test_context_empty_read;
      test_case "overwrite" `Quick test_context_overwrite;
    ];
    "atmosphere", [
      test_case "extreme signals" `Quick test_atmosphere_compute_mood_extremes;
      test_case "default mood" `Quick test_atmosphere_default_returns_mood;
    ];
  ]
