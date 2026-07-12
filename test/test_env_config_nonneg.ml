(** Unit tests for [Env_config_core.get_int_nonneg] /
    [Env_config_core.get_float_nonneg].

    Pins three properties:

    1. {b Negative input → default} (the contract this PR adds).
       An operator who writes [MASC_KEEPER_MEMORY_MAX_NOTES=-5]
       gets the default, not the literal [-5].
    2. {b Non-negative parses pass through unchanged} (no
       behavior change vs {!get_int} / {!get_float} on the
       happy path).
    3. {b Float NaN → default} (NaN sneaks past [< 0.0] checks
       silently because [nan < 0.0] is [false]; explicit
       {!Float.is_nan} guard pins this).

    The tests use a unique env-var prefix per case to avoid
    cross-contamination when run in parallel. *)

open Masc
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

(* ── production knob regression anchors ───────────────────────────────
   Pin the two knobs whose call sites (sse.ml [snapshot_min_interval_sec],
   server_runtime_bootstrap.ml [gc_space_overhead]) were changed from a
   hand-rolled [try _of_string (Sys.getenv ..) with Not_found -> default]
   -- which let [Failure] escape and crash module load on a malformed
   value -- to these validated helpers.  Garbage must now yield the
   documented default rather than raise. *)

let test_snapshot_interval_garbage_uses_default () =
  with_env "MASC_SNAPSHOT_INTERVAL_SEC" "notafloat" @@ fun () ->
  check_float "MASC_SNAPSHOT_INTERVAL_SEC garbage -> default 5.0" 5.0
    (C.get_float_nonneg ~default:5.0 "MASC_SNAPSHOT_INTERVAL_SEC")

let test_gc_space_overhead_garbage_uses_default () =
  with_env "MASC_GC_SPACE_OVERHEAD" "abc" @@ fun () ->
  check_int "MASC_GC_SPACE_OVERHEAD garbage -> default 100" 100
    (C.get_int_nonneg ~default:100 "MASC_GC_SPACE_OVERHEAD")

(* ── loud malformed handling (warn by default, strict raises) ──────────
   A non-empty env value that does not parse is an operator misconfiguration,
   not a silent fallback. By default the helpers warn and use [default];
   [MASC_PARSE_WARN] escalates to [Config_error] (fail-fast boot). An empty
   value stays "unset" (silent default). *)

let raises_config_error f =
  try
    ignore (f ());
    false
  with C.Config_error _ -> true

let test_get_bool_malformed_uses_default () =
  with_env "MASC_TEST_PARSE_BOOL_BAD" "flase" @@ fun () ->
  Alcotest.(check bool) "malformed bool → default true" true
    (C.get_bool ~default:true "MASC_TEST_PARSE_BOOL_BAD");
  Alcotest.(check bool) "malformed bool → default false" false
    (C.get_bool ~default:false "MASC_TEST_PARSE_BOOL_BAD")

let test_get_bool_case_insensitive_synonyms () =
  with_env "MASC_TEST_PARSE_BOOL_ON" "ON" @@ fun () ->
  Alcotest.(check bool) "ON → true" true
    (C.get_bool ~default:false "MASC_TEST_PARSE_BOOL_ON");
  with_env "MASC_TEST_PARSE_BOOL_OFF" "Off" @@ fun () ->
  Alcotest.(check bool) "Off → false" false
    (C.get_bool ~default:true "MASC_TEST_PARSE_BOOL_OFF")

let test_empty_value_is_unset_default () =
  with_env "MASC_TEST_PARSE_EMPTY_INT" "" @@ fun () ->
  check_int "empty int → default (silent)" 5
    (C.get_int ~default:5 "MASC_TEST_PARSE_EMPTY_INT");
  with_env "MASC_TEST_PARSE_EMPTY_BOOL" "" @@ fun () ->
  Alcotest.(check bool) "empty bool → default (silent)" true
    (C.get_bool ~default:true "MASC_TEST_PARSE_EMPTY_BOOL")

(* Non-vacuous: on the pre-fix code [get_int]/[get_bool] silently return the
   default on a malformed value, so [raises_config_error] would be [false] and
   these turn red. Strict mode is the behavioral change under test. *)
let test_strict_mode_raises_on_malformed () =
  with_env "MASC_PARSE_WARN" "1" @@ fun () ->
  ( with_env "MASC_TEST_PARSE_STRICT_INT" "notanint" @@ fun () ->
    Alcotest.(check bool) "strict + malformed int raises Config_error" true
      (raises_config_error (fun () ->
           C.get_int ~default:0 "MASC_TEST_PARSE_STRICT_INT")) );
  with_env "MASC_TEST_PARSE_STRICT_BOOL" "definitely-not-bool" @@ fun () ->
  Alcotest.(check bool) "strict + malformed bool raises Config_error" true
    (raises_config_error (fun () ->
         C.get_bool ~default:true "MASC_TEST_PARSE_STRICT_BOOL"))

let test_non_strict_malformed_does_not_raise () =
  with_env "MASC_PARSE_WARN" "0" @@ fun () ->
  with_env "MASC_TEST_PARSE_NONSTRICT_INT" "notanint" @@ fun () ->
  check_int "non-strict malformed int → default, no raise" 9
    (C.get_int ~default:9 "MASC_TEST_PARSE_NONSTRICT_INT")

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
      ( "production_knob_regression",
        [
          Alcotest.test_case "MASC_SNAPSHOT_INTERVAL_SEC garbage → default"
            `Quick test_snapshot_interval_garbage_uses_default;
          Alcotest.test_case "MASC_GC_SPACE_OVERHEAD garbage → default"
            `Quick test_gc_space_overhead_garbage_uses_default;
        ] );
      ( "loud_malformed_handling",
        [
          Alcotest.test_case "malformed bool → default" `Quick
            test_get_bool_malformed_uses_default;
          Alcotest.test_case "bool case-insensitive synonyms" `Quick
            test_get_bool_case_insensitive_synonyms;
          Alcotest.test_case "empty value → default (silent)" `Quick
            test_empty_value_is_unset_default;
          Alcotest.test_case "strict mode raises on malformed" `Quick
            test_strict_mode_raises_on_malformed;
          Alcotest.test_case "non-strict malformed does not raise" `Quick
            test_non_strict_malformed_does_not_raise;
        ] );
    ]
