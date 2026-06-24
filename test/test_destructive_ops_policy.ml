(** Tests for {!Destructive_ops_policy}.

    Verifies:
    - TOML loader rejects missing / malformed config with structured errors
    - Valid config parses to the expected typed policy
    - [enabled = false] disables detection without removing patterns
    - Default policy embeds the canonical 19-entry catalogue
    - Policy-driven detection wires through [Eval_gate.detect_destructive] *)

open Alcotest

let default_policy = Masc.Destructive_ops_policy.default

let assert_ok = function
  | Ok v -> v
  | Error errs ->
    fail (Printf.sprintf "expected Ok, got errors: %s"
            (String.concat "; "
               (List.map
                  (fun e -> Printf.sprintf "%s: %s" e.Masc.Destructive_ops_policy.path
                      e.message)
                  errs)))

let assert_error = function
  | Ok _ -> fail "expected Error"
  | Error _ -> ()

(* ================================================================ *)
(* Loader validation                                                *)
(* ================================================================ *)

let test_load_valid_config () =
  let toml = {|
[destructive_ops]
enabled = true

[[destructive_ops.patterns]]
class = "recursive_delete"
pattern = "rm -rf"
description = "recursive forced deletion"

[[destructive_ops.patterns]]
class = "sql_destructive"
pattern = "drop table"
description = "SQL table drop"
|} in
  let policy = assert_ok (Masc.Destructive_ops_policy.load_string toml) in
  check bool "enabled" true (Masc.Destructive_ops_policy.enabled policy);
  check int "two patterns" 2
    (List.length (Masc.Destructive_ops_policy.patterns policy))

let test_load_missing_patterns () =
  let toml = {|[destructive_ops]
enabled = true
|} in
  assert_error (Masc.Destructive_ops_policy.load_string toml)

let test_load_unknown_class () =
  let toml = {|
[destructive_ops]
enabled = true

[[destructive_ops.patterns]]
class = "unknown_class"
pattern = "rm -rf"
description = "recursive forced deletion"
|} in
  assert_error (Masc.Destructive_ops_policy.load_string toml)

let test_load_missing_pattern_field () =
  let toml = {|
[destructive_ops]
enabled = true

[[destructive_ops.patterns]]
class = "recursive_delete"
description = "recursive forced deletion"
|} in
  assert_error (Masc.Destructive_ops_policy.load_string toml)

let test_load_empty_pattern_field () =
  let toml = {|
[destructive_ops]
enabled = true

[[destructive_ops.patterns]]
class = "recursive_delete"
pattern = ""
description = "recursive forced deletion"
|} in
  assert_error (Masc.Destructive_ops_policy.load_string toml)

let test_load_disabled_policy () =
  let toml = {|
[destructive_ops]
enabled = false

[[destructive_ops.patterns]]
class = "recursive_delete"
pattern = "rm -rf"
description = "recursive forced deletion"
|} in
  let policy = assert_ok (Masc.Destructive_ops_policy.load_string toml) in
  check bool "enabled false" false (Masc.Destructive_ops_policy.enabled policy);
  check int "patterns retained" 1
    (List.length (Masc.Destructive_ops_policy.patterns policy));
  check (option (pair string string)) "detection disabled" None
    (Masc.Eval_gate.detect_destructive policy "rm -rf /")

let test_load_file_missing () =
  assert_error
    (Masc.Destructive_ops_policy.load_file "/nonexistent/destructive_ops.toml")

let test_load_wrong_destructive_ops_type () =
  let toml = {|destructive_ops = "foo"|} in
  assert_error (Masc.Destructive_ops_policy.load_string toml)

let test_load_wrong_enabled_type () =
  let toml = {|
[destructive_ops]
enabled = "true"

[[destructive_ops.patterns]]
class = "recursive_delete"
pattern = "rm -rf"
description = "recursive forced deletion"
|} in
  assert_error (Masc.Destructive_ops_policy.load_string toml)

let test_load_wrong_patterns_type () =
  let toml = {|
[destructive_ops]
patterns = "rm -rf"
|} in
  assert_error (Masc.Destructive_ops_policy.load_string toml)

let test_load_pattern_element_not_table () =
  let toml = {|
[destructive_ops]

[[destructive_ops.patterns]]
class = "recursive_delete"
pattern = "rm -rf"
description = "recursive forced deletion"

[[destructive_ops.patterns]]
"not a table"
|} in
  assert_error (Masc.Destructive_ops_policy.load_string toml)

let test_load_file_preserves_exception_message () =
  match Masc.Destructive_ops_policy.load_file "/nonexistent/destructive_ops.toml" with
  | Ok _ -> fail "expected Error"
  | Error errs ->
    (match errs with
     | [ e ] when String.starts_with ~prefix:"file not found or unreadable:" e.message ->
       (* exception message preserved *)
       ()
     | _ -> fail "expected a single io error with exception details")

(* ================================================================ *)
(* Default catalogue                                                  *)
(* ================================================================ *)

let test_default_has_19_patterns () =
  check int "default has 19 patterns" 19
    (List.length (Masc.Destructive_ops_policy.patterns default_policy));
  check bool "default enabled" true
    (Masc.Destructive_ops_policy.enabled default_policy)

let test_default_detects_known_destructive () =
  check (option (pair string string)) "rm -rf detected"
    (Some ("rm -rf", "recursive forced deletion"))
    (Masc.Eval_gate.detect_destructive default_policy "rm -rf /tmp/x");
  check (option (pair string string)) "drop table detected"
    (Some ("drop table", "SQL table drop"))
    (Masc.Eval_gate.detect_destructive default_policy "DROP TABLE users");
  check (option (pair string string)) "safe command passes" None
    (Masc.Eval_gate.detect_destructive default_policy "ls -la")

let test_of_patterns_programmatic () =
  let patterns = [
    { Masc.Shell_safety_types.class_ = Masc.Shell_safety_types.Process_signal
    ; pattern = "kill -9"
    ; description = "forced process kill"
    }
  ] in
  let policy = assert_ok (Masc.Destructive_ops_policy.of_patterns ~enabled:true patterns) in
  check (option (pair string string)) "custom pattern detected"
    (Some ("kill -9", "forced process kill"))
    (Masc.Eval_gate.detect_destructive policy "kill -9 1234")

let test_of_patterns_rejects_empty_pattern () =
  let patterns = [
    { Masc.Shell_safety_types.class_ = Masc.Shell_safety_types.Process_signal
    ; pattern = ""
    ; description = "empty pattern"
    }
  ] in
  assert_error (Masc.Destructive_ops_policy.of_patterns ~enabled:true patterns)

let test_of_patterns_rejects_empty_description () =
  let patterns = [
    { Masc.Shell_safety_types.class_ = Masc.Shell_safety_types.Process_signal
    ; pattern = "kill -9"
    ; description = ""
    }
  ] in
  assert_error (Masc.Destructive_ops_policy.of_patterns ~enabled:true patterns)

let test_of_patterns_rejects_enabled_empty_list () =
  assert_error (Masc.Destructive_ops_policy.of_patterns ~enabled:true [])

let test_of_patterns_disabled_empty_list_ok () =
  let _policy = assert_ok (Masc.Destructive_ops_policy.of_patterns ~enabled:false []) in
  ()

let test_load_string_field_type_error () =
  let toml = {|
[destructive_ops]
enabled = true

[[destructive_ops.patterns]]
class = 1
pattern = "rm -rf"
description = "recursive forced deletion"
|} in
  match Masc.Destructive_ops_policy.load_string toml with
  | Ok _ -> fail "expected Error"
  | Error errs ->
    let got =
      String.concat "; "
        (List.map
           (fun e ->
              Printf.sprintf "%s: %s" e.Masc.Destructive_ops_policy.path e.message)
           errs)
    in
    (match errs with
     | [ e ] when
         e.Masc.Destructive_ops_policy.path = "destructive_ops.patterns[0].class"
         && String.starts_with ~prefix:"pattern class: expected string" e.message -> ()
     | _ -> fail ("expected field-level type error, got: " ^ got))

(* ================================================================ *)
(* Runner                                                             *)
(* ================================================================ *)

let () =
  run "Destructive_ops_policy" [
    ("loader", [
      test_case "valid config" `Quick test_load_valid_config;
      test_case "missing patterns rejected" `Quick test_load_missing_patterns;
      test_case "unknown class rejected" `Quick test_load_unknown_class;
      test_case "missing pattern field rejected" `Quick test_load_missing_pattern_field;
      test_case "empty pattern field rejected" `Quick test_load_empty_pattern_field;
      test_case "disabled policy disables detection" `Quick test_load_disabled_policy;
      test_case "missing file rejected" `Quick test_load_file_missing;
      test_case "wrong destructive_ops type rejected" `Quick test_load_wrong_destructive_ops_type;
      test_case "wrong enabled type rejected" `Quick test_load_wrong_enabled_type;
      test_case "wrong patterns type rejected" `Quick test_load_wrong_patterns_type;
      test_case "pattern element not a table rejected" `Quick test_load_pattern_element_not_table;
      test_case "load_file preserves exception message" `Quick test_load_file_preserves_exception_message;
    ]);
    ("default", [
      test_case "19 patterns" `Quick test_default_has_19_patterns;
      test_case "known destructive detected" `Quick test_default_detects_known_destructive;
    ]);
    ("constructor", [
      test_case "of_patterns programmatic" `Quick test_of_patterns_programmatic;
      test_case "of_patterns rejects empty pattern" `Quick test_of_patterns_rejects_empty_pattern;
      test_case "of_patterns rejects empty description" `Quick test_of_patterns_rejects_empty_description;
      test_case "of_patterns rejects enabled empty list" `Quick test_of_patterns_rejects_enabled_empty_list;
      test_case "of_patterns disabled empty list ok" `Quick test_of_patterns_disabled_empty_list_ok;
      test_case "load_string field type error" `Quick test_load_string_field_type_error;
    ]);
  ]
