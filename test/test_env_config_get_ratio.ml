(** Unit tests for [Env_config_core.get_ratio].

    Pins the [\[0.0, 1.0\]]-bounded float contract:

    - in-range parses pass through unchanged (0.0, 0.5, 1.0)
    - out-of-range parses (negative, > 1.0, NaN, +∞, -∞) →
      [default]
    - non-numeric parse → [default] (delegated from {!get_float})
    - unset env var → [default]
    - out-of-range [default] is itself clamped to
      [\[0.0, 1.0\]] (defense-in-depth)

    Each test uses a unique env-var name so cases are independent
    when run in parallel. *)

open Masc_mcp
module C = Env_config_core

let with_env name value f =
  let prev = Sys.getenv_opt name in
  Unix.putenv name value;
  let finally () =
    match prev with
    | Some v -> Unix.putenv name v
    | None -> Unix.putenv name ""
  in
  Fun.protect ~finally f

let check_float label expected actual =
  Alcotest.(check (float 0.001)) label expected actual

let check_bool label expected actual =
  Alcotest.(check bool) label expected actual

(* ── happy path: in-range parses ─────────────────────────────────── *)

let test_in_range_zero () =
  with_env "MASC_TEST_RATIO_ZERO" "0.0" @@ fun () ->
  check_float "0.0 passes through" 0.0
    (C.get_ratio ~default:0.5 "MASC_TEST_RATIO_ZERO")

let test_in_range_half () =
  with_env "MASC_TEST_RATIO_HALF" "0.5" @@ fun () ->
  check_float "0.5 passes through" 0.5
    (C.get_ratio ~default:0.7 "MASC_TEST_RATIO_HALF")

let test_in_range_one () =
  with_env "MASC_TEST_RATIO_ONE" "1.0" @@ fun () ->
  check_float "1.0 passes through" 1.0
    (C.get_ratio ~default:0.5 "MASC_TEST_RATIO_ONE")

(* ── out-of-range: rejection ─────────────────────────────────────── *)

let test_negative_rejected () =
  with_env "MASC_TEST_RATIO_NEG" "-0.1" @@ fun () ->
  check_float "-0.1 → default 0.7" 0.7
    (C.get_ratio ~default:0.7 "MASC_TEST_RATIO_NEG")

let test_above_one_rejected () =
  with_env "MASC_TEST_RATIO_GT1" "1.5" @@ fun () ->
  check_float "1.5 → default 0.6" 0.6
    (C.get_ratio ~default:0.6 "MASC_TEST_RATIO_GT1")

let test_above_one_boundary_rejected () =
  (* exactly 1.0 + epsilon should reject; 1.0 itself accepted *)
  with_env "MASC_TEST_RATIO_GT1B" "1.0001" @@ fun () ->
  check_float "1.0001 → default 0.4" 0.4
    (C.get_ratio ~default:0.4 "MASC_TEST_RATIO_GT1B")

let test_nan_rejected () =
  with_env "MASC_TEST_RATIO_NAN" "nan" @@ fun () ->
  check_float "NaN → default 0.3" 0.3
    (C.get_ratio ~default:0.3 "MASC_TEST_RATIO_NAN")

let test_pos_inf_rejected () =
  with_env "MASC_TEST_RATIO_PINF" "inf" @@ fun () ->
  check_float "+inf → default 0.2" 0.2
    (C.get_ratio ~default:0.2 "MASC_TEST_RATIO_PINF")

let test_neg_inf_rejected () =
  with_env "MASC_TEST_RATIO_NINF" "-inf" @@ fun () ->
  check_float "-inf → default 0.8" 0.8
    (C.get_ratio ~default:0.8 "MASC_TEST_RATIO_NINF")

(* ── parse fallthrough ───────────────────────────────────────────── *)

let test_garbage_uses_default () =
  with_env "MASC_TEST_RATIO_GARBAGE" "junk" @@ fun () ->
  check_float "non-float → default 0.5" 0.5
    (C.get_ratio ~default:0.5 "MASC_TEST_RATIO_GARBAGE")

let test_unset_uses_default () =
  check_float "unset → default 0.42" 0.42
    (C.get_ratio ~default:0.42 "MASC_TEST_RATIO_UNSET_XYZ123")

(* ── default clamping (defense in depth) ─────────────────────────── *)

let test_default_below_zero_clamped () =
  (* env unset, default itself is out of range — clamp to 0.0. *)
  check_float "default -0.5 clamped to 0.0" 0.0
    (C.get_ratio
       ~default:(-0.5) "MASC_TEST_RATIO_DEFAULT_NEG_XYZ123")

let test_default_above_one_clamped () =
  check_float "default 1.7 clamped to 1.0" 1.0
    (C.get_ratio
       ~default:1.7 "MASC_TEST_RATIO_DEFAULT_GT1_XYZ123")

let test_default_nan_sanitised () =
  (* [Float.min nan 1.0] propagates NaN, so a naive clamp would
     return NaN when default = NaN.  Pin the contract that the
     helper must always return a finite [0, 1] value. *)
  let r =
    C.get_ratio
      ~default:Float.nan "MASC_TEST_RATIO_DEFAULT_NAN_XYZ123"
  in
  check_bool "NaN default sanitised to finite" true
    (Float.is_finite r);
  check_bool "NaN default sanitised within [0, 1]" true
    (r >= 0.0 && r <= 1.0)

let test_default_pos_inf_sanitised () =
  let r =
    C.get_ratio
      ~default:Float.infinity
      "MASC_TEST_RATIO_DEFAULT_PINF_XYZ123"
  in
  check_bool "+inf default sanitised to finite" true
    (Float.is_finite r);
  check_bool "+inf default sanitised within [0, 1]" true
    (r >= 0.0 && r <= 1.0)

let test_default_neg_inf_sanitised () =
  let r =
    C.get_ratio
      ~default:Float.neg_infinity
      "MASC_TEST_RATIO_DEFAULT_NINF_XYZ123"
  in
  check_bool "-inf default sanitised to finite" true
    (Float.is_finite r);
  check_bool "-inf default sanitised within [0, 1]" true
    (r >= 0.0 && r <= 1.0)

(* ── runner ──────────────────────────────────────────────────────── *)

let () =
  Alcotest.run "Env_config_core_get_ratio"
    [
      ( "in-range parses",
        [
          Alcotest.test_case "0.0 passes" `Quick test_in_range_zero;
          Alcotest.test_case "0.5 passes" `Quick test_in_range_half;
          Alcotest.test_case "1.0 passes" `Quick test_in_range_one;
        ] );
      ( "out-of-range rejection",
        [
          Alcotest.test_case "negative → default" `Quick
            test_negative_rejected;
          Alcotest.test_case ">1.0 → default" `Quick
            test_above_one_rejected;
          Alcotest.test_case "1.0+ε → default" `Quick
            test_above_one_boundary_rejected;
          Alcotest.test_case "NaN → default" `Quick test_nan_rejected;
          Alcotest.test_case "+inf → default" `Quick
            test_pos_inf_rejected;
          Alcotest.test_case "-inf → default" `Quick
            test_neg_inf_rejected;
        ] );
      ( "parse fallthrough",
        [
          Alcotest.test_case "garbage → default" `Quick
            test_garbage_uses_default;
          Alcotest.test_case "unset → default" `Quick
            test_unset_uses_default;
        ] );
      ( "default clamping",
        [
          Alcotest.test_case "default <0 clamped to 0.0" `Quick
            test_default_below_zero_clamped;
          Alcotest.test_case "default >1 clamped to 1.0" `Quick
            test_default_above_one_clamped;
          Alcotest.test_case "default NaN sanitised to finite [0,1]"
            `Quick test_default_nan_sanitised;
          Alcotest.test_case "default +inf sanitised to finite [0,1]"
            `Quick test_default_pos_inf_sanitised;
          Alcotest.test_case "default -inf sanitised to finite [0,1]"
            `Quick test_default_neg_inf_sanitised;
        ] );
    ]
