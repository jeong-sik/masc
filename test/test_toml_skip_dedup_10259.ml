(** #10259: every reconcile cycle re-emits "toml_loader: skipping
    janitor.toml: invalid cascade_name 'ollama_only' ..." for the same
    4 keepers.  16+ identical WARN events landed in
    system_log_2026-04-25.jsonl in a 43-minute window — 25%+ of the
    800-line tail.  These tests pin [log_toml_skip_once] dedup logic:
    same (file, error) emits once; new error text re-emits; reset
    helper restarts the bookkeeping for fresh process / test
    isolation. *)

open Alcotest
module K = Masc_mcp.Keeper_types_profile

let test_first_call_emits () =
  K.reset_logged_toml_skip_for_test ();
  let emitted =
    K.log_toml_skip_once
      ~file:"janitor.toml"
      ~error:"invalid cascade_name 'ollama_only' (reserved: ...)"
  in
  check bool "first observation emits" true emitted

let test_repeat_call_suppressed () =
  K.reset_logged_toml_skip_for_test ();
  let _ = K.log_toml_skip_once
    ~file:"janitor.toml" ~error:"invalid cascade_name 'ollama_only'"
  in
  let second = K.log_toml_skip_once
    ~file:"janitor.toml" ~error:"invalid cascade_name 'ollama_only'"
  in
  let third = K.log_toml_skip_once
    ~file:"janitor.toml" ~error:"invalid cascade_name 'ollama_only'"
  in
  check bool "second emission suppressed" false second;
  check bool "third emission suppressed" false third

let test_distinct_files_both_emit () =
  K.reset_logged_toml_skip_for_test ();
  let a = K.log_toml_skip_once
    ~file:"janitor.toml" ~error:"E"
  in
  let b = K.log_toml_skip_once
    ~file:"taskmaster.toml" ~error:"E"
  in
  check bool "different file emits even with same error" true a;
  check bool "different file emits even with same error" true b

let test_distinct_errors_both_emit () =
  K.reset_logged_toml_skip_for_test ();
  let a = K.log_toml_skip_once
    ~file:"janitor.toml" ~error:"invalid cascade_name 'ollama_only'"
  in
  let b = K.log_toml_skip_once
    ~file:"janitor.toml" ~error:"invalid cascade_name 'primary'"
  in
  check bool "first error emits" true a;
  check bool "different error text re-emits" true b

let test_reset_restores_first_emission () =
  K.reset_logged_toml_skip_for_test ();
  let _ = K.log_toml_skip_once ~file:"x.toml" ~error:"e" in
  let suppressed = K.log_toml_skip_once ~file:"x.toml" ~error:"e" in
  check bool "before reset: suppressed" false suppressed;
  K.reset_logged_toml_skip_for_test ();
  let after_reset = K.log_toml_skip_once ~file:"x.toml" ~error:"e" in
  check bool "after reset: emits again" true after_reset

let () =
  run "toml_skip_dedup_10259" [
    ("dedup", [
        test_case "first call emits" `Quick test_first_call_emits;
        test_case "repeat call suppressed" `Quick test_repeat_call_suppressed;
        test_case "distinct files both emit (same error)" `Quick
          test_distinct_files_both_emit;
        test_case "distinct error text re-emits (same file)" `Quick
          test_distinct_errors_both_emit;
        test_case "reset restores first-emission semantics" `Quick
          test_reset_restores_first_emission;
      ]);
  ]
