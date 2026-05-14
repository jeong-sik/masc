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
;;

let test_bin_of_known () =
  let ls = Bin.of_known Bin.Ls in
  assert (Bin.risk_class ls = `Safe);
  assert (Bin.kind ls = `Safe_bin);
  assert (Bin.to_string ls = "ls");
  assert (Bin.known ls = Some Bin.Ls);
  let git = Bin.of_known Bin.Git in
  assert (Bin.risk_class git = `Audited);
  assert (Bin.kind git = `Git);
  assert (Bin.known git = Some Bin.Git);
  let sudo = Bin.of_known Bin.Sudo in
  assert (Bin.risk_class sudo = `Privileged);
  assert (Bin.kind sudo = `Privileged_bin);
  assert (Bin.known sudo = Some Bin.Sudo)
;;

let test_bin_name_of_known () =
  assert (Bin.name_of_known Bin.Ls = "ls");
  assert (Bin.name_of_known Bin.Git = "git");
  assert (Bin.name_of_known Bin.Curl = "curl");
  assert (Bin.name_of_known Bin.Rm = "rm");
  assert (Bin.name_of_known Bin.Sudo = "sudo")
;;

let test_bin_risk_of_known () =
  assert (Bin.risk_of_known Bin.Ls = `Safe);
  assert (Bin.risk_of_known Bin.Rg = `Safe);
  assert (Bin.risk_of_known Bin.Git = `Audited);
  assert (Bin.risk_of_known Bin.Docker = `Audited);
  assert (Bin.risk_of_known Bin.Sudo = `Privileged);
  assert (Bin.risk_of_known Bin.Rm = `Privileged)
;;

let test_bin_known_roundtrip () =
  match Bin.of_string "git" with
  | Ok b ->
    (match Bin.known b with
     | Some k -> assert (Bin.name_of_known k = "git")
     | None -> assert false)
  | Error _ -> assert false
;;

let test_bin_unknown_has_no_known () =
  match Bin.of_string "wibble" with
  | Ok b -> assert (Bin.known b = None)
  | Error _ -> assert false
;;

let test_bin_unknown_is_privileged () =
  match Bin.of_string "wibble" with
  | Ok b -> assert (Bin.risk_class b = `Privileged)
  | Error _ -> assert false
;;

let test_bin_empty_rejected () =
  match Bin.of_string "" with
  | Ok _ -> assert false
  | Error (`Unknown _) -> ()
;;

let test_git_op_destructive_detection () =
  match Git_op.of_argv [ "git"; "push"; "--force"; "origin"; "main" ] with
  | Ok (Git_op.Destructive _) -> ()
  | Ok _ -> assert false
  | Error _ -> assert false
;;

let test_git_op_read () =
  match Git_op.of_argv [ "git"; "status" ] with
  | Ok (Git_op.Read _) -> ()
  | _ -> assert false
;;

let test_git_op_read_with_cwd_flag () =
  match Git_op.of_argv [ "git"; "-C"; "/tmp/repo"; "status" ] with
  | Ok (Git_op.Read _) -> ()
  | _ -> assert false
;;

let test_git_op_unknown () =
  match Git_op.of_argv [ "git"; "exotic-subcmd" ] with
  | Error (`Unknown_subcmd _) -> ()
  | _ -> assert false
;;

let test_parsed_polymorphic () =
  let p : int Parsed.t = Parsed.Parsed 42 in
  let too_complex : int Parsed.t = Parsed.Too_complex `Heredoc in
  let aborted : int Parsed.t = Parsed.Parse_aborted `Timeout_50ms in
  match p, too_complex, aborted with
  | Parsed 42, Too_complex `Heredoc, Parse_aborted `Timeout_50ms -> ()
  | _ -> assert false
;;

let test_path_scope_classify () =
  let ps = Path_scope.classify ~raw:"/etc/passwd" ~cwd:"/tmp" in
  assert (Path_scope.raw ps = "/etc/passwd");
  match Path_scope.scope ps with
  | Outside_worktree _ -> ()
  | _ -> assert false
;;

let test_path_scope_classify_sandbox () =
  let ps = Path_scope.classify ~raw:"/tmp/masc-keeper-xyz/foo" ~cwd:"/tmp" in
  match Path_scope.scope ps with
  | Inside_sandbox _ -> ()
  | _ -> assert false
;;

let test_path_scope_classify_sandbox_escape () =
  let ps = Path_scope.classify ~raw:"/tmp/masc-keeper-xyz/../../etc/passwd" ~cwd:"/tmp" in
  match Path_scope.scope ps with
  | Absolute_unknown _ -> ()
  | _ -> assert false
;;

let test_path_scope_classify_unresolvable () =
  (* parent dir does not exist on disk → fail-closed. *)
  let ps = Path_scope.classify ~raw:"/__nonexistent_root_xyz_42/foo" ~cwd:"/tmp" in
  match Path_scope.scope ps with
  | Absolute_unknown _ -> ()
  | _ -> assert false
;;

let test_verdict_trusted_argv_smart_ctor () =
  match Bin.of_string "ls" with
  | Error _ -> assert false
  | Ok bin ->
    let simple : Shell_ir.simple =
      { bin
      ; args = []
      ; env = []
      ; cwd = None
      ; redirects = []
      ; sandbox = Sandbox_target.host ()
      }
    in
    let t = Verdict.trust ~caps:[] simple in
    assert (Verdict.Trusted_argv.bin t = bin);
    assert (Verdict.Trusted_argv.args t = [])
;;

let test_verdict_four_way () =
  let _ = Verdict.Deny { caps = []; reason = Parse_failed } in
  let _ =
    Verdict.Ask
      { caps = []
      ; summary = "x"
      ; bin =
          (match Bin.of_string "ls" with
           | Ok b -> b
           | Error _ -> assert false)
      ; raw_source = "ls"
      }
  in
  let bin =
    match Bin.of_string "ls" with
    | Ok b -> b
    | Error _ -> assert false
  in
  let simple : Shell_ir.simple =
    { bin
    ; args = []
    ; env = []
    ; cwd = None
    ; redirects = []
    ; sandbox = Sandbox_target.host ()
    }
  in
  let _ =
    Verdict.Suggest_confirm
      (Verdict.trust ~caps:[] simple, { Verdict.risk_class = `Safe; ttl_sec = 60.0 })
  in
  ()
;;

let () =
  test_bin_safe ();
  test_bin_of_known ();
  test_bin_name_of_known ();
  test_bin_risk_of_known ();
  test_bin_known_roundtrip ();
  test_bin_unknown_has_no_known ();
  test_bin_unknown_is_privileged ();
  test_bin_empty_rejected ();
  test_git_op_destructive_detection ();
  test_git_op_read ();
  test_git_op_read_with_cwd_flag ();
  test_git_op_unknown ();
  test_parsed_polymorphic ();
  test_path_scope_classify ();
  test_path_scope_classify_sandbox ();
  test_path_scope_classify_sandbox_escape ();
  test_path_scope_classify_unresolvable ();
  test_verdict_trusted_argv_smart_ctor ();
  test_verdict_four_way ();
  print_endline "[test_exec_types] all tests passed"
;;
