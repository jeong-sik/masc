(** A0 smoke tests — variant surface sanity only.

    Exhaustiveness of walkers/policies is enforced later (A2) because
    the walker does not exist yet.  These tests fail if someone
    accidentally breaks the public shape of a typed IR module. *)

open Masc_exec

let test_bin_safe () =
  match Bin.of_string "ls" with
  | Ok b ->
      assert (Bin.risk_class b = `Safe);
      assert (Bin.to_string b = "ls")
  | Error _ -> assert false

let test_bin_unknown_is_privileged () =
  match Bin.of_string "wibble" with
  | Ok b -> assert (Bin.risk_class b = `Privileged)
  | Error _ -> assert false

let test_bin_empty_rejected () =
  match Bin.of_string "" with
  | Ok _ -> assert false
  | Error (`Unknown _) -> ()

let test_git_op_destructive_detection () =
  match Git_op.of_argv [ "git"; "push"; "--force"; "origin"; "main" ] with
  | Ok (Git_op.Destructive _) -> ()
  | Ok _ -> assert false
  | Error _ -> assert false

let test_git_op_read () =
  match Git_op.of_argv [ "git"; "status" ] with
  | Ok (Git_op.Read _) -> ()
  | _ -> assert false

let test_git_op_read_with_cwd_flag () =
  match Git_op.of_argv [ "git"; "-C"; "/tmp/repo"; "status" ] with
  | Ok (Git_op.Read _) -> ()
  | _ -> assert false

let test_git_op_unknown () =
  match Git_op.of_argv [ "git"; "exotic-subcmd" ] with
  | Error (`Unknown_subcmd _) -> ()
  | _ -> assert false

let test_parsed_polymorphic () =
  let p : int Parsed.t = Parsed.Parsed 42 in
  let too_complex : int Parsed.t = Parsed.Too_complex `Heredoc in
  let aborted : int Parsed.t = Parsed.Parse_aborted `Timeout_50ms in
  match p, too_complex, aborted with
  | Parsed 42, Too_complex `Heredoc, Parse_aborted `Timeout_50ms -> ()
  | _ -> assert false

let test_path_scope_classify () =
  let ps = Path_scope.classify ~raw:"/etc/passwd" ~cwd:"/tmp" in
  assert (Path_scope.raw ps = "/etc/passwd");
  match Path_scope.scope ps with
  | Absolute_unknown _ -> ()
  | _ -> assert false

let test_verdict_trusted_argv_smart_ctor () =
  match Bin.of_string "ls" with
  | Error _ -> assert false
  | Ok bin ->
      let simple : Shell_ir.simple =
        { bin; args = []; env = []; cwd = None; redirects = [] }
      in
      let t = Verdict.trust ~caps:[] simple in
      assert (Verdict.Trusted_argv.bin t = bin);
      assert (Verdict.Trusted_argv.args t = [])

let test_verdict_three_way () =
  let _ = Verdict.Deny { caps = []; reason = Parse_failed } in
  let _ =
    Verdict.Ask
      { caps = []; summary = "x"; bin =
          (match Bin.of_string "ls" with
           | Ok b -> b
           | Error _ -> assert false);
        raw_source = "ls" }
  in
  ()

let () =
  test_bin_safe ();
  test_bin_unknown_is_privileged ();
  test_bin_empty_rejected ();
  test_git_op_destructive_detection ();
  test_git_op_read ();
  test_git_op_read_with_cwd_flag ();
  test_git_op_unknown ();
  test_parsed_polymorphic ();
  test_path_scope_classify ();
  test_verdict_trusted_argv_smart_ctor ();
  test_verdict_three_way ();
  print_endline "[test_exec_types] all tests passed"
