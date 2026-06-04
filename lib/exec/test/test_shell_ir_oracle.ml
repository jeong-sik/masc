module IR = Masc_exec.Shell_ir
module Oracle = Masc_exec.Shell_ir_oracle
module Risk = Masc_exec.Shell_ir_risk

let fixture_path name =
  let rel = "fixtures/shell_ir_oracle/" ^ name ^ ".json" in
  if Sys.file_exists rel then rel else "lib/exec/test/" ^ rel
;;

let load name =
  match Yojson.Safe.from_file (fixture_path name) |> Oracle.of_yojson with
  | Ok facts -> facts
  | Error msg -> Alcotest.failf "%s: %s" name msg
;;

let contains_substring haystack needle =
  let hay_len = String.length haystack in
  let needle_len = String.length needle in
  let rec loop i =
    if i + needle_len > hay_len then false
    else if String.sub haystack i needle_len = needle then true
    else loop (i + 1)
  in
  needle_len = 0 || loop 0
;;

let bin s = Result.get_ok (Masc_exec.Exec_program.of_string s)
let lit s = IR.Lit (s, IR.default_meta)

let simple ?(redirects = []) bin_str args =
  IR.Simple
    { IR.bin = bin bin_str
    ; args = List.map lit args
    ; env = []
    ; cwd = None
    ; redirects
    ; sandbox = Masc_exec.Sandbox_target.host ()
    }
;;

let write_redirect raw =
  let target = Masc_exec.Path_scope.classify ~raw ~cwd:"/tmp" in
  Masc_exec.Redirect_scope.File
    { fd = 1; target; mode = Masc_exec.Redirect_scope.Write }
;;

let test_simple_fixture () =
  let facts = load "simple" in
  Alcotest.(check int) "schema" 1 facts.Oracle.schema_version;
  Alcotest.(check string) "command" "echo hello" facts.command;
  Alcotest.(check string) "status" "ok"
    (Oracle.string_of_parse_status facts.parse_status);
  Alcotest.(check (list string)) "features" [] (Oracle.feature_names facts);
  Alcotest.(check string) "syntax floor" "R0"
    (Risk.string_of_risk_class (Oracle.syntax_floor facts));
  Alcotest.(check bool) "read-only compatible" true
    (Result.is_ok (Oracle.read_only_descriptor_compatible facts));
  match facts.commands with
  | [ cmd ] ->
    Alcotest.(check string) "name" "echo" cmd.Oracle.name;
    Alcotest.(check (list string)) "argv" [ "echo"; "hello" ] cmd.argv
  | _ -> Alcotest.fail "expected one command"
;;

let test_pipeline_fixture () =
  let facts = load "pipeline" in
  Alcotest.(check (list string)) "features" [ "pipeline" ] (Oracle.feature_names facts);
  Alcotest.(check string) "syntax floor" "R0"
    (Risk.string_of_risk_class (Oracle.syntax_floor facts));
  Alcotest.(check bool) "pipeline alone is read-only compatible" true
    (Result.is_ok (Oracle.read_only_descriptor_compatible facts))
;;

let test_redirect_fixture_blocks_read_only () =
  let facts = load "redirect_write" in
  Alcotest.(check (list string)) "features" [ "redirect" ] (Oracle.feature_names facts);
  Alcotest.(check string) "syntax floor" "R1"
    (Risk.string_of_risk_class (Oracle.syntax_floor facts));
  match Oracle.read_only_descriptor_compatible facts with
  | Ok () -> Alcotest.fail "redirect must block read-only descriptor parity"
  | Error msg ->
    Alcotest.(check bool) "mentions redirect" true (contains_substring msg "redirect")
;;

let test_heredoc_fixture_blocks_read_only () =
  let facts = load "heredoc" in
  Alcotest.(check (list string)) "features" [ "heredoc" ] (Oracle.feature_names facts);
  Alcotest.(check string) "syntax floor" "R1"
    (Risk.string_of_risk_class (Oracle.syntax_floor facts));
  match Oracle.read_only_descriptor_compatible facts with
  | Ok () -> Alcotest.fail "heredoc must block read-only descriptor parity"
  | Error msg ->
    Alcotest.(check bool) "mentions heredoc" true (contains_substring msg "heredoc")
;;

let test_parse_error_fixture_fails_closed () =
  let facts = load "parse_error" in
  Alcotest.(check string) "status" "parse_error"
    (Oracle.string_of_parse_status facts.parse_status);
  Alcotest.(check string) "syntax floor" "Destructive_protected"
    (Risk.string_of_risk_class (Oracle.syntax_floor facts));
  match Oracle.read_only_descriptor_compatible facts with
  | Ok () -> Alcotest.fail "parse error must fail closed"
  | Error msg ->
    Alcotest.(check bool) "mentions status" true (contains_substring msg "parse_status")
;;

let test_unknown_feature_fails_closed () =
  let facts = load "unknown_feature" in
  Alcotest.(check (list string)) "features" [ "unknown:future_feature" ]
    (Oracle.feature_names facts);
  match Oracle.read_only_descriptor_compatible facts with
  | Ok () -> Alcotest.fail "unknown enabled feature must fail closed"
  | Error msg ->
    Alcotest.(check bool) "mentions unknown" true
      (contains_substring msg "unknown:future_feature")
;;

let test_write_redirect_adds_shell_ir_risk_floor () =
  let ir = simple ~redirects:[ write_redirect "out.txt" ] "echo" [ "hello" ] in
  let decided = Risk.classify (Risk.undecided ir) in
  Alcotest.(check string) "echo > file is R1" "R1"
    (Risk.string_of_risk_class decided.Risk.risk)
;;

let test_read_redirect_stays_r0 () =
  let target = Masc_exec.Path_scope.classify ~raw:"in.txt" ~cwd:"/tmp" in
  let redirect =
    Masc_exec.Redirect_scope.File
      { fd = 0; target; mode = Masc_exec.Redirect_scope.Read }
  in
  let ir = simple ~redirects:[ redirect ] "cat" [] in
  let decided = Risk.classify (Risk.undecided ir) in
  Alcotest.(check string) "cat < file stays R0" "R0"
    (Risk.string_of_risk_class decided.Risk.risk)
;;

let () =
  test_simple_fixture ();
  test_pipeline_fixture ();
  test_redirect_fixture_blocks_read_only ();
  test_heredoc_fixture_blocks_read_only ();
  test_parse_error_fixture_fails_closed ();
  test_unknown_feature_fails_closed ();
  test_write_redirect_adds_shell_ir_risk_floor ();
  test_read_redirect_stays_r0 ();
  print_endline "test_shell_ir_oracle: oracle contract passed"
;;
