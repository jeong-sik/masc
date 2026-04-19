(* Tick 12 (P5 reduced): shadow AST parse observation.

   These tests pin the tag taxonomy that telemetry will histogram
   during the prod-observation window before the regex allowlist is
   actually replaced.  They do NOT assert any behavioural gate —
   the legacy regex is still the authoritative path. *)

open Alcotest

let tag cmd = Masc_mcp.Worker_dev_tools.shadow_parse_outcome cmd

let test_simple_ls_parses () =
  check string "plain ls is parsed_simple"
    "parsed_simple" (tag "ls")

let test_simple_bin_with_arg_parses () =
  check string "ls -l is parsed_simple"
    "parsed_simple" (tag "ls -l")

let test_empty_command_is_parse_error () =
  (* An empty string does not match the grammar start symbol, so the
     parser surfaces it as Parse_error.  Regex allowlist would reject
     it earlier, but telemetry still captures the outcome. *)
  match tag "" with
  | "parse_error" -> ()
  | other -> fail ("expected parse_error, got " ^ other)

let is_non_simple_tag t =
  t = "parse_error"
  || String.starts_with ~prefix:"too_complex" t
  || String.starts_with ~prefix:"parse_aborted" t

let test_shell_chain_marks_unsupported () =
  (* `a && b` is definitely not simple-command.  The parser either
     surfaces Parse_error or Too_complex:* — both are valid signals
     that the string falls outside the current AST gate's coverage.
     We accept either tag so the test does not fight parser-coverage
     upgrades (A1-PR-N) that may reclassify constructs. *)
  let t = tag "ls && rm -rf /" in
  if not (is_non_simple_tag t) then fail ("unexpected tag: " ^ t)

let test_pipe_parses () =
  check string "pipe is parsed_simple" "parsed_simple" (tag "ls | wc -l")

let test_cross_check_pairs_legacy_and_shadow () =
  let legacy_ok = Ok () in
  let legacy, shadow =
    Masc_mcp.Worker_dev_tools.cross_check_command ~legacy:legacy_ok "ls"
  in
  (match legacy with Ok () -> () | Error _ -> fail "legacy preserved");
  check string "shadow=parsed_simple" "parsed_simple" shadow

let () =
  run "shadow_parse" [
    ("tagging", [
      test_case "simple ls" `Quick test_simple_ls_parses;
      test_case "simple bin with arg" `Quick test_simple_bin_with_arg_parses;
      test_case "empty command tag" `Quick test_empty_command_is_parse_error;
      test_case "shell chain unsupported" `Quick
        test_shell_chain_marks_unsupported;
      test_case "pipe parses" `Quick test_pipe_parses;
    ]);
    ("cross_check", [
      test_case "cross_check preserves legacy result" `Quick
        test_cross_check_pairs_legacy_and_shadow;
    ]);
  ]
