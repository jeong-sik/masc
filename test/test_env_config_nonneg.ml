(** Unit tests for strict fail-closed [Env_config_core] readers and typed
    [Config_boot_overrides] decoding (no silent default substitution on
    malformed, negative, or non-finite inputs). *)

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

let raises_config_error f =
  try
    ignore (f ());
    false
  with C.Config_error _ -> true

(* ── get_int_nonneg ───────────────────────────────────────────────── *)

let test_int_nonneg_negative_fails_closed () =
  with_env "MASC_TEST_NONNEG_INT_NEG" "-5" @@ fun () ->
  Alcotest.(check bool) "negative -5 raises Config_error" true
    (raises_config_error (fun () ->
         C.get_int_nonneg ~default:10 "MASC_TEST_NONNEG_INT_NEG"))

let test_int_nonneg_zero_passes () =
  with_env "MASC_TEST_NONNEG_INT_ZERO" "0" @@ fun () ->
  check_int "zero passes through" 0
    (C.get_int_nonneg ~default:99 "MASC_TEST_NONNEG_INT_ZERO")

let test_int_nonneg_positive_passes () =
  with_env "MASC_TEST_NONNEG_INT_POS" "42" @@ fun () ->
  check_int "positive 42 passes through" 42
    (C.get_int_nonneg ~default:99 "MASC_TEST_NONNEG_INT_POS")

let test_int_nonneg_unset_uses_default () =
  check_int "unset → default" 7
    (C.get_int_nonneg ~default:7 "MASC_TEST_NONNEG_INT_UNSET_XYZ123")

let test_int_nonneg_garbage_fails_closed () =
  with_env "MASC_TEST_NONNEG_INT_GARBAGE" "not_a_number" @@ fun () ->
  Alcotest.(check bool) "non-int parse raises Config_error" true
    (raises_config_error (fun () ->
         C.get_int_nonneg ~default:11 "MASC_TEST_NONNEG_INT_GARBAGE"))

(* ── get_float_nonneg ─────────────────────────────────────────────── *)

let test_float_nonneg_negative_fails_closed () =
  with_env "MASC_TEST_NONNEG_FLOAT_NEG" "-1.5" @@ fun () ->
  Alcotest.(check bool) "negative -1.5 raises Config_error" true
    (raises_config_error (fun () ->
         C.get_float_nonneg ~default:30.0 "MASC_TEST_NONNEG_FLOAT_NEG"))

let test_float_nonneg_zero_passes () =
  with_env "MASC_TEST_NONNEG_FLOAT_ZERO" "0.0" @@ fun () ->
  check_float "zero passes through" 0.0
    (C.get_float_nonneg ~default:99.0 "MASC_TEST_NONNEG_FLOAT_ZERO")

let test_float_nonneg_positive_passes () =
  with_env "MASC_TEST_NONNEG_FLOAT_POS" "2.5" @@ fun () ->
  check_float "positive 2.5 passes through" 2.5
    (C.get_float_nonneg ~default:99.0 "MASC_TEST_NONNEG_FLOAT_POS")

let test_float_nonneg_nonfinite_fails_closed () =
  List.iter
    (fun raw ->
       with_env "MASC_TEST_NONNEG_FLOAT_NF" raw @@ fun () ->
       Alcotest.(check bool) (raw ^ " raises Config_error") true
         (raises_config_error (fun () ->
              C.get_float_nonneg ~default:12.0 "MASC_TEST_NONNEG_FLOAT_NF")))
    [ "nan"; "inf"; "-inf"; "junk" ]

let test_float_nonneg_unset_uses_default () =
  check_float "unset → default" 5.5
    (C.get_float_nonneg ~default:5.5 "MASC_TEST_NONNEG_FLOAT_UNSET_XYZ123")

(* ── strict fail-closed handling (unconditional) ─────────────────── *)

let test_get_bool_malformed_fails_closed () =
  with_env "MASC_TEST_PARSE_BOOL_BAD" "flase" @@ fun () ->
  Alcotest.(check bool) "malformed bool raises Config_error" true
    (raises_config_error (fun () ->
         C.get_bool ~default:true "MASC_TEST_PARSE_BOOL_BAD"))

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

let test_float_clamped_nonfinite_fails_closed () =
  List.iter
    (fun raw ->
       with_env "MASC_TEST_CLAMPED_FLOAT_NF" raw @@ fun () ->
       Alcotest.(check bool) (raw ^ " raises Config_error") true
         (raises_config_error (fun () ->
              C.get_float_clamped ~default:900.0 ~min_v:60.0 ~max_v:3600.0
                "MASC_TEST_CLAMPED_FLOAT_NF")))
    [ "nan"; "inf"; "-inf" ]

let test_float_clamped_bounds () =
  with_env "MASC_TEST_CLAMPED_FLOAT_LOW" "10.0" @@ fun () ->
  check_float "below min_v → min_v 60.0" 60.0
    (C.get_float_clamped ~default:900.0 ~min_v:60.0 ~max_v:3600.0
       "MASC_TEST_CLAMPED_FLOAT_LOW");
  with_env "MASC_TEST_CLAMPED_FLOAT_HIGH" "7200.0" @@ fun () ->
  check_float "above max_v → max_v 3600.0" 3600.0
    (C.get_float_clamped ~default:900.0 ~min_v:60.0 ~max_v:3600.0
       "MASC_TEST_CLAMPED_FLOAT_HIGH");
  with_env "MASC_TEST_CLAMPED_FLOAT_MID" "300.0" @@ fun () ->
  check_float "in range → 300.0" 300.0
    (C.get_float_clamped ~default:900.0 ~min_v:60.0 ~max_v:3600.0
       "MASC_TEST_CLAMPED_FLOAT_MID")

let test_typed_boot_values_skip_string_roundtrip () =
  Config_boot_overrides.reset_for_tests ();
  Fun.protect ~finally:Config_boot_overrides.reset_for_tests (fun () ->
    Config_boot_overrides.set_typed "MASC_TEST_TYPED_INT" (Config_boot_overrides.Int 42);
    Config_boot_overrides.set_typed "MASC_TEST_TYPED_BOOL" (Config_boot_overrides.Bool true);
    Config_boot_overrides.set_typed "MASC_TEST_TYPED_FLOAT" (Config_boot_overrides.Float 2.5);
    check_int "typed int direct" 42 (C.get_int ~default:0 "MASC_TEST_TYPED_INT");
    Alcotest.(check bool) "typed bool direct" true (C.get_bool ~default:false "MASC_TEST_TYPED_BOOL");
    check_float "typed float direct" 2.5 (C.get_float ~default:0.0 "MASC_TEST_TYPED_FLOAT");
    Alcotest.(check bool) "type mismatch fails closed" true
      (raises_config_error (fun () -> C.get_int ~default:0 "MASC_TEST_TYPED_BOOL")))

let test_port_malformed_fails_closed () =
  List.iter
    (fun raw ->
       with_env "MASC_TEST_BAD_PORT" raw @@ fun () ->
       Alcotest.(check bool) ("bad port " ^ raw ^ " raises Config_error") true
         (raises_config_error (fun () -> C.get_port ~default:8080 "MASC_TEST_BAD_PORT")))
    [ "0"; "70000"; "-1"; "abc" ]

let () =
  Alcotest.run "Env_config_core_nonneg"
    [ ( "get_int_nonneg"
      , [ Alcotest.test_case "negative fails closed" `Quick test_int_nonneg_negative_fails_closed
        ; Alcotest.test_case "zero passes" `Quick test_int_nonneg_zero_passes
        ; Alcotest.test_case "positive passes" `Quick test_int_nonneg_positive_passes
        ; Alcotest.test_case "unset → default" `Quick test_int_nonneg_unset_uses_default
        ; Alcotest.test_case "garbage fails closed" `Quick test_int_nonneg_garbage_fails_closed
        ] )
    ; ( "get_float_nonneg"
      , [ Alcotest.test_case "negative fails closed" `Quick test_float_nonneg_negative_fails_closed
        ; Alcotest.test_case "zero passes" `Quick test_float_nonneg_zero_passes
        ; Alcotest.test_case "positive passes" `Quick test_float_nonneg_positive_passes
        ; Alcotest.test_case "non-finite/garbage fail closed" `Quick test_float_nonneg_nonfinite_fails_closed
        ; Alcotest.test_case "unset → default" `Quick test_float_nonneg_unset_uses_default
        ] )
    ; ( "get_float_clamped"
      , [ Alcotest.test_case "non-finite fails closed" `Quick test_float_clamped_nonfinite_fails_closed
        ; Alcotest.test_case "min/max bounds" `Quick test_float_clamped_bounds
        ] )
    ; ( "strict_and_typed"
      , [ Alcotest.test_case "malformed bool fails closed" `Quick test_get_bool_malformed_fails_closed
        ; Alcotest.test_case "bool case-insensitive synonyms" `Quick test_get_bool_case_insensitive_synonyms
        ; Alcotest.test_case "empty value → default (silent)" `Quick test_empty_value_is_unset_default
        ; Alcotest.test_case "typed boot values skip string roundtrip" `Quick test_typed_boot_values_skip_string_roundtrip
        ; Alcotest.test_case "malformed port fails closed" `Quick test_port_malformed_fails_closed
        ] )
    ]
