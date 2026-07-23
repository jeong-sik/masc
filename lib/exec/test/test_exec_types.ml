(** Objective executable-name, parser-result, and path-scope smoke tests. *)

open Masc_exec

let test_exec_program_of_string () =
  match Exec_program.of_string "ls" with
  | Ok bin ->
    assert (Exec_program.to_string bin = "ls")
  | Error _ -> assert false
;;

let test_exec_program_preserves_exact_path () =
  match Exec_program.of_string "/opt/tools/wibble" with
  | Ok bin -> assert (Exec_program.to_string bin = "/opt/tools/wibble")
  | Error _ -> assert false
;;

let test_exec_program_empty_rejected () =
  match Exec_program.of_string "" with
  | Ok _ -> assert false
  | Error (`Unknown "") -> ()
  | Error (`Unknown _) -> assert false
;;

let test_parsed_polymorphic () =
  let parsed : int Parsed.t = Parsed.Parsed 42 in
  let too_complex : int Parsed.t = Parsed.Too_complex `Heredoc in
  let aborted : int Parsed.t = Parsed.Parse_aborted `Timeout_50ms in
  match parsed, too_complex, aborted with
  | Parsed 42, Too_complex `Heredoc, Parse_aborted `Timeout_50ms -> ()
  | _ -> assert false
;;

let test_path_scope_classify () =
  let scope = Path_scope.classify ~raw:"/etc/passwd" ~cwd:"/tmp" in
  assert (Path_scope.raw scope = "/etc/passwd");
  match Path_scope.scope scope with
  | Outside_workspace _ -> ()
  | _ -> assert false
;;

let test_path_scope_classify_sandbox () =
  let scope = Path_scope.classify ~raw:"/tmp/masc-keeper-xyz/foo" ~cwd:"/tmp" in
  match Path_scope.scope scope with
  | Inside_sandbox _ -> ()
  | _ -> assert false
;;

let test_path_scope_classify_sandbox_escape () =
  let scope =
    Path_scope.classify ~raw:"/tmp/masc-keeper-xyz/../../etc/passwd" ~cwd:"/tmp"
  in
  match Path_scope.scope scope with
  | Absolute_unknown _ -> ()
  | _ -> assert false
;;

let test_path_scope_classify_unresolvable () =
  let scope = Path_scope.classify ~raw:"/__nonexistent_root_xyz_42/foo" ~cwd:"/tmp" in
  match Path_scope.scope scope with
  | Absolute_unknown _ -> ()
  | _ -> assert false
;;

let () =
  test_exec_program_of_string ();
  test_exec_program_preserves_exact_path ();
  test_exec_program_empty_rejected ();
  test_parsed_polymorphic ();
  test_path_scope_classify ();
  test_path_scope_classify_sandbox ();
  test_path_scope_classify_sandbox_escape ();
  test_path_scope_classify_unresolvable ();
  print_endline "[test_exec_types] all tests passed"
;;
