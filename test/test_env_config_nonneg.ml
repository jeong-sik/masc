(** Unit tests for [Env_config_core.get_int_nonneg] /
    [Env_config_core.get_float_nonneg].

    Pins three properties:

    1. {b Negative input → default} (the contract this PR adds).
       An operator who writes [MASC_KEEPER_ALERT_MAX_RETRIES=-5]
       gets the default, not the literal [-5].
    2. {b Non-negative parses pass through unchanged} (no
       behavior change vs {!get_int} / {!get_float} on the
       happy path).
    3. {b Float NaN → default} (NaN sneaks past [< 0.0] checks
       silently because [nan < 0.0] is [false]; explicit
       {!Float.is_nan} guard pins this).

    The tests use a unique env-var prefix per case to avoid
    cross-contamination when run in parallel. *)

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

let check_int label expected actual =
  Alcotest.(check int) label expected actual

let check_float label expected actual =
  Alcotest.(check (float 0.001)) label expected actual

(* ── get_int_nonneg ───────────────────────────────────────────────── *)

let test_int_nonneg_negative_falls_back () =
  with_env "MASC_TEST_NONNEG_INT_NEG" "-5" @@ fun () ->
  check_int "negative -5 → default 10" 10
    (C.get_int_nonneg ~default:10 "MASC_TEST_NONNEG_INT_NEG")

let test_int_nonneg_zero_passes () =
  with_env "MASC_TEST_NONNEG_INT_ZERO" "0" @@ fun () ->
  check_int "zero passes through" 0
    (C.get_int_nonneg ~default:99 "MASC_TEST_NONNEG_INT_ZERO")

let test_int_nonneg_positive_passes () =
  with_env "MASC_TEST_NONNEG_INT_POS" "42" @@ fun () ->
  check_int "positive 42 passes through" 42
    (C.get_int_nonneg ~default:99 "MASC_TEST_NONNEG_INT_POS")

let test_int_nonneg_unset_uses_default () =
  (* Env var intentionally unset for this test. *)
  check_int "unset → default" 7
    (C.get_int_nonneg ~default:7 "MASC_TEST_NONNEG_INT_UNSET_XYZ123")

let test_int_nonneg_garbage_uses_default () =
  with_env "MASC_TEST_NONNEG_INT_GARBAGE" "not_a_number" @@ fun () ->
  check_int "non-int parse → default (inherited from get_int)" 11
    (C.get_int_nonneg ~default:11 "MASC_TEST_NONNEG_INT_GARBAGE")

(* ── get_float_nonneg ─────────────────────────────────────────────── *)

let test_float_nonneg_negative_falls_back () =
  with_env "MASC_TEST_NONNEG_FLOAT_NEG" "-1.5" @@ fun () ->
  check_float "negative -1.5 → default 30.0" 30.0
    (C.get_float_nonneg ~default:30.0 "MASC_TEST_NONNEG_FLOAT_NEG")

let test_float_nonneg_zero_passes () =
  with_env "MASC_TEST_NONNEG_FLOAT_ZERO" "0.0" @@ fun () ->
  check_float "zero passes through" 0.0
    (C.get_float_nonneg ~default:99.0 "MASC_TEST_NONNEG_FLOAT_ZERO")

let test_float_nonneg_positive_passes () =
  with_env "MASC_TEST_NONNEG_FLOAT_POS" "2.5" @@ fun () ->
  check_float "positive 2.5 passes through" 2.5
    (C.get_float_nonneg ~default:99.0 "MASC_TEST_NONNEG_FLOAT_POS")

let test_float_nonneg_nan_falls_back () =
  (* NaN sneaks past [< 0.0] silently — the explicit
     non-finite guard is the property under test. *)
  with_env "MASC_TEST_NONNEG_FLOAT_NAN" "nan" @@ fun () ->
  check_float "NaN → default 12.0" 12.0
    (C.get_float_nonneg ~default:12.0 "MASC_TEST_NONNEG_FLOAT_NAN")

let test_float_nonneg_pos_inf_falls_back () =
  (* [+∞ > 0.0] is [true] so a [< 0.0]-only check would let it
     through.  [Float.is_finite] guard catches it. *)
  with_env "MASC_TEST_NONNEG_FLOAT_PINF" "inf" @@ fun () ->
  check_float "+inf → default 13.0" 13.0
    (C.get_float_nonneg ~default:13.0 "MASC_TEST_NONNEG_FLOAT_PINF")

let test_float_nonneg_neg_inf_falls_back () =
  (* [-∞ < 0.0] alone would suffice, but pinning the non-finite
     contract uniformly across {NaN, +∞, -∞} is the property. *)
  with_env "MASC_TEST_NONNEG_FLOAT_NINF" "-inf" @@ fun () ->
  check_float "-inf → default 14.0" 14.0
    (C.get_float_nonneg ~default:14.0 "MASC_TEST_NONNEG_FLOAT_NINF")

let test_float_nonneg_unset_uses_default () =
  check_float "unset → default" 5.5
    (C.get_float_nonneg
       ~default:5.5 "MASC_TEST_NONNEG_FLOAT_UNSET_XYZ123")

let test_float_nonneg_garbage_uses_default () =
  with_env "MASC_TEST_NONNEG_FLOAT_GARBAGE" "junk" @@ fun () ->
  check_float "non-float parse → default" 8.0
    (C.get_float_nonneg
       ~default:8.0 "MASC_TEST_NONNEG_FLOAT_GARBAGE")

(* ── runner ───────────────────────────────────────────────────────── *)

let () =
  Alcotest.run "Env_config_core_nonneg"
    [
      ( "get_int_nonneg",
        [
          Alcotest.test_case "negative → default" `Quick
            test_int_nonneg_negative_falls_back;
          Alcotest.test_case "zero passes" `Quick
            test_int_nonneg_zero_passes;
          Alcotest.test_case "positive passes" `Quick
            test_int_nonneg_positive_passes;
          Alcotest.test_case "unset → default" `Quick
            test_int_nonneg_unset_uses_default;
          Alcotest.test_case "garbage → default" `Quick
            test_int_nonneg_garbage_uses_default;
        ] );
      ( "get_float_nonneg",
        [
          Alcotest.test_case "negative → default" `Quick
            test_float_nonneg_negative_falls_back;
          Alcotest.test_case "zero passes" `Quick
            test_float_nonneg_zero_passes;
          Alcotest.test_case "positive passes" `Quick
            test_float_nonneg_positive_passes;
          Alcotest.test_case "NaN → default" `Quick
            test_float_nonneg_nan_falls_back;
          Alcotest.test_case "+inf → default" `Quick
            test_float_nonneg_pos_inf_falls_back;
          Alcotest.test_case "-inf → default" `Quick
            test_float_nonneg_neg_inf_falls_back;
          Alcotest.test_case "unset → default" `Quick
            test_float_nonneg_unset_uses_default;
          Alcotest.test_case "garbage → default" `Quick
            test_float_nonneg_garbage_uses_default;
        ] );
    ]
