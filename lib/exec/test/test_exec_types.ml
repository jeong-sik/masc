(** A0 smoke tests — variant surface sanity only.

    Exhaustiveness of walkers/policies is enforced later (A2) because
    the walker does not exist yet.  These tests fail if someone
    accidentally breaks the public shape of a typed IR module. *)

open Masc_exec

let test_exec_program_safe () =
  match Exec_program.of_string "ls" with
  | Ok b ->
    assert (Exec_program.risk_class b = `Safe);
    assert (Exec_program.to_string b = "ls")
  | Error _ -> assert false
;;

let test_exec_program_of_known () =
  let ls = Exec_program.of_known Exec_program.Ls in
  assert (Exec_program.risk_class ls = `Safe);
  assert (Exec_program.kind ls = `Safe_program);
  assert (Exec_program.to_string ls = "ls");
  assert (Exec_program.known ls = Some Exec_program.Ls);
  let git = Exec_program.of_known Exec_program.Git in
  assert (Exec_program.risk_class git = `Audited);
  assert (Exec_program.kind git = `Git);
  assert (Exec_program.known git = Some Exec_program.Git);
  let sudo = Exec_program.of_known Exec_program.Sudo in
  assert (Exec_program.risk_class sudo = `Privileged);
  assert (Exec_program.kind sudo = `Privileged_program);
  assert (Exec_program.known sudo = Some Exec_program.Sudo)
;;

let test_exec_program_name_of_known () =
  assert (Exec_program.name_of_known Exec_program.Ls = "ls");
  assert (Exec_program.name_of_known Exec_program.Git = "git");
  assert (Exec_program.name_of_known Exec_program.Grep = "grep");
  assert (Exec_program.name_of_known Exec_program.Curl = "curl");
  assert (Exec_program.name_of_known Exec_program.Rm = "rm");
  assert (Exec_program.name_of_known Exec_program.Sudo = "sudo")
;;

let test_exec_program_risk_of_known () =
  assert (Exec_program.risk_of_known Exec_program.Ls = `Safe);
  assert (Exec_program.risk_of_known Exec_program.Rg = `Safe);
  assert (Exec_program.risk_of_known Exec_program.Grep = `Safe);
  assert (Exec_program.risk_of_known Exec_program.Git = `Audited);
  assert (Exec_program.risk_of_known Exec_program.Docker = `Audited);
  assert (Exec_program.risk_of_known Exec_program.Sudo = `Privileged);
  assert (Exec_program.risk_of_known Exec_program.Rm = `Privileged)
;;

let test_exec_program_all_known_metadata_roundtrips () =
  let seen_names = Hashtbl.create 128 in
  List.iter
    (fun known ->
       let name = Exec_program.name_of_known known in
       assert (not (String.equal name ""));
       assert (not (Hashtbl.mem seen_names name));
       Hashtbl.add seen_names name ();
       match Exec_program.of_string name with
       | Ok bin ->
         assert (Exec_program.to_string bin = name);
         assert (Exec_program.known bin = Some known);
         assert (Exec_program.risk_class bin = Exec_program.risk_of_known known);
         assert (Exec_program.kind bin = Exec_program.kind_of_known known)
       | Error _ -> assert false)
    Exec_program.all_known
;;

let test_exec_program_known_roundtrip () =
  match Exec_program.of_string "git" with
  | Ok b ->
    (match Exec_program.known b with
     | Some k -> assert (Exec_program.name_of_known k = "git")
     | None -> assert false)
  | Error _ -> assert false
;;

let test_exec_program_unknown_has_no_known () =
  match Exec_program.of_string "wibble" with
  | Ok b -> assert (Exec_program.known b = None)
  | Error _ -> assert false
;;

let test_exec_program_unknown_is_privileged () =
  match Exec_program.of_string "wibble" with
  | Ok b -> assert (Exec_program.risk_class b = `Privileged)
  | Error _ -> assert false
;;

let test_grep_is_known_safe_exec_program () =
  match Exec_program.of_string "grep" with
  | Ok b ->
    assert (Exec_program.known b = Some Exec_program.Grep);
    assert (Exec_program.risk_class b = `Safe)
  | Error _ -> assert false
;;

let test_exec_program_empty_rejected () =
  match Exec_program.of_string "" with
  | Ok _ -> assert false
  | Error (`Unknown _) -> ()
;;

let test_git_op_destructive_detection () =
  match Git_op.of_argv [ "git"; "push"; "--force"; "origin"; "main" ] with
  | Ok (Git_op.Destructive _) -> ()
  | Ok _ -> assert false
  | Error _ -> assert false
;;

(* Refspec-borne destructiveness: the danger is in a positional token, not a
   flag. [:dst] (empty source) deletes the remote ref; [+ref] force-overwrites
   it. Without refspec parsing these graded as an ordinary [Mutating Push]. *)
let test_git_op_push_delete_refspec () =
  match Git_op.of_argv [ "git"; "push"; "origin"; ":refs/heads/main" ] with
  | Ok (Git_op.Destructive `Push_delete) -> ()
  | _ -> assert false
;;

let test_git_op_push_force_refspec () =
  match Git_op.of_argv [ "git"; "push"; "origin"; "+refs/heads/main" ] with
  | Ok (Git_op.Destructive `Push_force) -> ()
  | _ -> assert false
;;

let test_git_op_push_prune_destructive () =
  match Git_op.of_argv [ "git"; "push"; "--prune"; "origin"; "main" ] with
  | Ok (Git_op.Destructive `Push_delete) -> ()
  | _ -> assert false
;;

(* Guard against over-blocking: a plain [src:dst] refspec (no [+]/[:] marker)
   is an ordinary push, not destructive. *)
let test_git_op_push_plain_refspec_not_destructive () =
  match Git_op.of_argv [ "git"; "push"; "origin"; "main:main" ] with
  | Ok (Git_op.Mutating `Push) -> ()
  | _ -> assert false
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
  | Outside_workspace _ -> ()
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
  match Exec_program.of_string "ls" with
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
          (match Exec_program.of_string "ls" with
           | Ok b -> b
           | Error _ -> assert false)
      ; raw_source = "ls"
      }
  in
  let bin =
    match Exec_program.of_string "ls" with
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
  test_exec_program_safe ();
  test_exec_program_of_known ();
  test_exec_program_name_of_known ();
  test_exec_program_risk_of_known ();
  test_exec_program_all_known_metadata_roundtrips ();
  test_exec_program_known_roundtrip ();
  test_exec_program_unknown_has_no_known ();
  test_exec_program_unknown_is_privileged ();
  test_grep_is_known_safe_exec_program ();
  test_exec_program_empty_rejected ();
  test_git_op_destructive_detection ();
  test_git_op_push_delete_refspec ();
  test_git_op_push_force_refspec ();
  test_git_op_push_prune_destructive ();
  test_git_op_push_plain_refspec_not_destructive ();
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
