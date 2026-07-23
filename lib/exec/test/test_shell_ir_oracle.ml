module Oracle = Masc_exec.Shell_ir_oracle

let fixture_path name =
  let rel = "fixtures/shell_ir_oracle/" ^ name ^ ".json" in
  if Sys.file_exists rel then rel else "lib/exec/test/" ^ rel
;;

let load name =
  match Yojson.Safe.from_file (fixture_path name) |> Oracle.of_yojson with
  | Ok facts -> facts
  | Error message -> Alcotest.failf "%s: %s" name message
;;

let contains_substring haystack needle =
  let hay_len = String.length haystack in
  let needle_len = String.length needle in
  let rec loop index =
    if index + needle_len > hay_len
    then false
    else if String.sub haystack index needle_len = needle
    then true
    else loop (index + 1)
  in
  needle_len = 0 || loop 0
;;

let test_simple_fixture () =
  let facts = load "simple" in
  Alcotest.(check int) "schema" 1 facts.Oracle.schema_version;
  Alcotest.(check string) "command" "echo hello" facts.command;
  Alcotest.(check string) "status" "ok"
    (Oracle.string_of_parse_status facts.parse_status);
  Alcotest.(check (list string)) "features" [] (Oracle.feature_names facts);
  Alcotest.(check (list string)) "blockers" [] (Oracle.structural_blockers facts);
  Alcotest.(check bool) "compatible" true
    (Result.is_ok (Oracle.structurally_compatible facts));
  match facts.commands with
  | [ command ] ->
    Alcotest.(check string) "name" "echo" command.Oracle.name;
    Alcotest.(check (list string)) "argv" [ "echo"; "hello" ] command.argv
  | _ -> Alcotest.fail "expected one command"
;;

let test_pipeline_fixture () =
  let facts = load "pipeline" in
  Alcotest.(check (list string)) "features" [ "pipeline" ] (Oracle.feature_names facts);
  Alcotest.(check (list string)) "blockers" [] (Oracle.structural_blockers facts);
  Alcotest.(check bool) "compatible" true
    (Result.is_ok (Oracle.structurally_compatible facts))
;;

let assert_incompatible name feature =
  let facts = load name in
  match Oracle.structurally_compatible facts with
  | Ok () -> Alcotest.failf "%s must be structurally incompatible" name
  | Error message ->
    Alcotest.(check bool) ("mentions " ^ feature) true
      (contains_substring message feature)
;;

let test_redirect_fixture () =
  let facts = load "redirect_write" in
  Alcotest.(check (list string)) "features" [ "redirect" ] (Oracle.feature_names facts);
  assert_incompatible "redirect_write" "redirect"
;;

let test_heredoc_fixture () =
  let facts = load "heredoc" in
  Alcotest.(check (list string)) "features" [ "heredoc" ] (Oracle.feature_names facts);
  assert_incompatible "heredoc" "heredoc"
;;

let test_parse_error_fixture () =
  let facts = load "parse_error" in
  Alcotest.(check string) "status" "parse_error"
    (Oracle.string_of_parse_status facts.parse_status);
  assert_incompatible "parse_error" "parse_status"
;;

let test_unknown_feature_fixture () =
  let facts = load "unknown_feature" in
  Alcotest.(check (list string)) "features" [ "unknown:future_feature" ]
    (Oracle.feature_names facts);
  assert_incompatible "unknown_feature" "unknown:future_feature"
;;

let () =
  test_simple_fixture ();
  test_pipeline_fixture ();
  test_redirect_fixture ();
  test_heredoc_fixture ();
  test_parse_error_fixture ();
  test_unknown_feature_fixture ();
  print_endline "test_shell_ir_oracle: parser fact contract passed"
;;
