open Alcotest
open Runtime

(* ── toml_quote tests ── *)

let test_toml_quote_simple_string () =
  let result = toml_quote "hello" in
  check string "simple string" {|"hello"|} result

let test_toml_quote_contains_double_quote () =
  let result = toml_quote {|say "hello"|} in
  check string "double quote escaped" {|"say \"hello\""|} result

let test_toml_quote_contains_backslash () =
  let result = toml_quote "a\\b" in
  check string "backslash escaped" {|"a\\b"|} result

let test_toml_quote_contains_newline () =
  let result = toml_quote "line1\nline2" in
  check string "newline escaped" {|"line1\nline2"|} result

let test_toml_quote_contains_carriage_return () =
  let result = toml_quote "line1\rline2" in
  check string "carriage return escaped" {|"line1\rline2"|} result

let test_toml_quote_contains_tab () =
  let result = toml_quote "col1\tcol2" in
  check string "tab escaped" {|"col1\tcol2"|} result

let test_toml_quote_control_char () =
  let ctrl_a = String.make 1 (Char.chr 1) in
  let result = toml_quote ("a" ^ ctrl_a ^ "b") in
  check string "control char unicode escaped" {|"a\u0001b"|} result

let test_toml_quote_empty_string () =
  let result = toml_quote "" in
  check string "empty string" {|""|} result

let test_toml_quote_unicode () =
  let result = toml_quote "héllo" in
  check string "unicode preserved" {|"héllo"|} result

(* ── toml_float tests ── *)

let test_toml_float_integer_value () =
  let result = toml_float 42.0 in
  check string "integer value gets .0" "42.0" result

let test_toml_float_decimal () =
  let result = toml_float 3.14 in
  check string "decimal preserved" "3.1400000000000001" result

let test_toml_float_scientific () =
  let result = toml_float 1.5e10 in
  check string "scientific notation" "15000000000.0" result

let test_toml_float_negative () =
  let result = toml_float (-3.14) in
  check string "negative float" "-3.1400000000000001" result

let test_toml_float_zero () =
  let result = toml_float 0.0 in
  check string "zero" "0.0" result

let test_toml_float_small () =
  let result = toml_float 1e-10 in
  check string "very small" "1.0000000000000001e-10" result

(* ── missing_catalog_model_label tests ── *)

let test_missing_catalog_model_label_basic () =
  let missing = { runtime_id = "openai/gpt-4"; model_id = "gpt-4-turbo" } in
  let result = missing_catalog_model_label missing in
  check string "basic label" "openai/gpt-4 (model=gpt-4-turbo)" result

let test_missing_catalog_model_label_with_special_chars () =
  let missing = { runtime_id = "azure/gpt-4-32k"; model_id = "gpt-4-32k-0613" } in
  let result = missing_catalog_model_label missing in
  check string "special chars" "azure/gpt-4-32k (model=gpt-4-32k-0613)" result

(* ── test registration ── *)

let () =
  Alcotest.run "Runtime Catalog Backfill"
    [ ( "toml_quote"
      , [ test_case "simple string" `Quick test_toml_quote_simple_string
        ; test_case "double quote" `Quick test_toml_quote_contains_double_quote
        ; test_case "backslash" `Quick test_toml_quote_contains_backslash
        ; test_case "newline" `Quick test_toml_quote_contains_newline
        ; test_case "carriage return" `Quick test_toml_quote_contains_carriage_return
        ; test_case "tab" `Quick test_toml_quote_contains_tab
        ; test_case "control char" `Quick test_toml_quote_control_char
        ; test_case "empty string" `Quick test_toml_quote_empty_string
        ; test_case "unicode" `Quick test_toml_quote_unicode
        ] )
    ; ( "toml_float"
      , [ test_case "integer value" `Quick test_toml_float_integer_value
        ; test_case "decimal" `Quick test_toml_float_decimal
        ; test_case "scientific" `Quick test_toml_float_scientific
        ; test_case "negative" `Quick test_toml_float_negative
        ; test_case "zero" `Quick test_toml_float_zero
        ; test_case "very small" `Quick test_toml_float_small
        ] )
    ; ( "missing_catalog_model_label"
      , [ test_case "basic" `Quick test_missing_catalog_model_label_basic
        ; test_case "special chars" `Quick test_missing_catalog_model_label_with_special_chars
        ] )
    ]