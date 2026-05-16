(* Tick 12 (P5 reduced): shadow AST parse observation.

   These tests pin the parse-outcome taxonomy that telemetry will
   histogram during the prod-observation window before the regex
   allowlist is actually replaced.  They do NOT assert any
   behavioural gate — the legacy regex is still the authoritative
   path. *)

open Alcotest

module W = Masc_mcp.Worker_dev_tools
module G = Masc_mcp.Gate_diff_types

let kind cmd = W.shadow_parse_outcome_kind cmd

let test_simple_ls_parses () =
  match kind "ls" with
  | G.Parsed_simple -> ()
  | other ->
    fail ("expected Parsed_simple, got " ^ G.parse_outcome_kind_to_tag other)

let test_simple_bin_with_arg_parses () =
  match kind "ls -l" with
  | G.Parsed_simple -> ()
  | other ->
    fail ("expected Parsed_simple, got " ^ G.parse_outcome_kind_to_tag other)

let test_empty_command_is_parse_error () =
  (* An empty string does not match the grammar start symbol, so the
     parser surfaces it as Parse_error.  Regex allowlist would reject
     it earlier, but telemetry still captures the outcome. *)
  match kind "" with
  | G.Parse_error -> ()
  | other ->
    fail ("expected Parse_error, got " ^ G.parse_outcome_kind_to_tag other)

let is_non_simple = function
  | G.Parsed_simple -> false
  | G.Parse_error | G.Parse_aborted _ | G.Too_complex _ -> true

let test_shell_chain_marks_unsupported () =
  (* [a && b] is definitely not simple-command.  The parser either
     surfaces Parse_error or Too_complex _ — both are valid signals
     that the string falls outside the current AST gate's coverage.
     We accept either kind so the test does not fight parser-coverage
     upgrades (A1-PR-N) that may reclassify constructs. *)
  let k = kind "ls && rm -rf /" in
  if not (is_non_simple k) then
    fail ("unexpected kind: " ^ G.parse_outcome_kind_to_tag k)

let test_pipe_parses () =
  match kind "ls | wc -l" with
  | G.Parsed_simple -> ()
  | other ->
    fail ("expected Parsed_simple, got " ^ G.parse_outcome_kind_to_tag other)

let () =
  run "shadow_parse" [
    ("tagging", [
      test_case "simple ls" `Quick test_simple_ls_parses;
      test_case "simple bin with arg" `Quick test_simple_bin_with_arg_parses;
      test_case "empty command kind" `Quick test_empty_command_is_parse_error;
      test_case "shell chain unsupported" `Quick
        test_shell_chain_marks_unsupported;
      test_case "pipe parses" `Quick test_pipe_parses;
    ]);
  ]
