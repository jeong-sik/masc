(** A2 walker tests — Shell_ir -> Capability mapping.

    Walker is exhaustive over Shell_ir variants, so adding a new arm
    (say [Shell_ir.Group of t list] someday) forces a compile error in
    [capability_check.ml] first, then here when new tests are added. *)

open Masc_exec

let bin_ok name =
  match Bin.of_string name with
  | Ok b -> b
  | Error _ -> failwith ("bin must classify: " ^ name)

let simple ?(args = []) ?(env = []) ?(cwd = None) ?(redirects = []) bin
    : Shell_ir.simple =
  { bin; args; env; cwd; redirects }

let lit s = Shell_ir.Lit s

let test_ls_emits_exec_bin () =
  let ir = Shell_ir.Simple (simple (bin_ok "ls")) in
  match Capability_check.of_ir ir with
  | [ Capability.Exec_bin (b, []) ] ->
    assert (Bin.to_string b = "ls")
  | _ -> failwith "ls must produce single Exec_bin cap"

let test_git_status_classified_as_git_read () =
  let ir =
    Shell_ir.Simple (simple ~args:[ lit "status" ] (bin_ok "git"))
  in
  match Capability_check.of_ir ir with
  | [ Capability.Git (Git_op.Read `Status) ] -> ()
  | _ -> failwith "git status must produce Git (Read Status)"

let test_git_push_force_destructive () =
  let ir =
    Shell_ir.Simple
      (simple
         ~args:[ lit "push"; lit "--force"; lit "origin"; lit "main" ]
         (bin_ok "git"))
  in
  match Capability_check.of_ir ir with
  | [ Capability.Git (Git_op.Destructive `Push_force) ] -> ()
  | _ -> failwith "git push --force must produce Destructive Push_force"

let test_git_with_var_falls_back_to_exec_bin () =
  (* git ${REMOTE} push — can't classify statically, falls back. *)
  let ir =
    Shell_ir.Simple
      (simple ~args:[ Shell_ir.Var "REMOTE"; lit "push" ] (bin_ok "git"))
  in
  match Capability_check.of_ir ir with
  | [ Capability.Exec_bin (b, _) ] ->
    assert (Bin.to_string b = "git")
  | _ -> failwith "git with Var arg must fall back to Exec_bin"

let test_env_set_prefix_emitted_first () =
  let ir =
    Shell_ir.Simple
      (simple
         ~env:[ ("FOO", lit "bar"); ("BAZ", lit "qux") ]
         (bin_ok "ls"))
  in
  match Capability_check.of_ir ir with
  | [ Capability.Env_set ("FOO", _); Capability.Env_set ("BAZ", _);
      Capability.Exec_bin _ ] -> ()
  | _ -> failwith "env prefix caps must precede head cap in order"

let test_redirect_write_becomes_write_path () =
  let p = Path_scope.classify ~raw:"/tmp/out.log" ~cwd:"/tmp" in
  let redir =
    Redirect_scope.File { fd = 1; target = p; mode = Redirect_scope.Write }
  in
  let ir =
    Shell_ir.Simple (simple ~redirects:[ redir ] (bin_ok "echo"))
  in
  match Capability_check.of_ir ir with
  | [ Capability.Exec_bin _; Capability.Write_path (_, Redirect_scope.Write) ]
    -> ()
  | _ -> failwith "> redirect must produce Write_path after Exec_bin"

let test_redirect_read_becomes_read_path () =
  let p = Path_scope.classify ~raw:"/etc/passwd" ~cwd:"/tmp" in
  let redir =
    Redirect_scope.File { fd = 0; target = p; mode = Redirect_scope.Read }
  in
  let ir =
    Shell_ir.Simple (simple ~redirects:[ redir ] (bin_ok "cat"))
  in
  match Capability_check.of_ir ir with
  | [ Capability.Exec_bin _; Capability.Read_path _ ] -> ()
  | _ -> failwith "< redirect must produce Read_path"

let test_fd_dup_emits_no_path_cap () =
  let redir = Redirect_scope.Fd_to_fd { src = 2; dst = 1 } in
  let ir =
    Shell_ir.Simple (simple ~redirects:[ redir ] (bin_ok "ls"))
  in
  match Capability_check.of_ir ir with
  | [ Capability.Exec_bin _ ] -> ()
  | _ -> failwith "2>&1 must emit no path cap, only head cap"

let test_pipeline_folds_caps () =
  let stage1 = Shell_ir.Simple (simple (bin_ok "ls")) in
  let stage2 = Shell_ir.Simple (simple (bin_ok "cat")) in
  let ir = Shell_ir.Pipeline [ stage1; stage2 ] in
  match Capability_check.of_ir ir with
  | [ Capability.Pipeline_fold inner ] ->
    assert (List.length inner = 2);
    (match inner with
     | [ Capability.Exec_bin (b1, _); Capability.Exec_bin (b2, _) ] ->
       assert (Bin.to_string b1 = "ls");
       assert (Bin.to_string b2 = "cat")
     | _ -> failwith "pipeline inner caps wrong shape")
  | _ -> failwith "Pipeline must produce single Pipeline_fold"

let () =
  test_ls_emits_exec_bin ();
  test_git_status_classified_as_git_read ();
  test_git_push_force_destructive ();
  test_git_with_var_falls_back_to_exec_bin ();
  test_env_set_prefix_emitted_first ();
  test_redirect_write_becomes_write_path ();
  test_redirect_read_becomes_read_path ();
  test_fd_dup_emits_no_path_cap ();
  test_pipeline_folds_caps ();
  print_endline "[test_capability_check] all tests passed"
