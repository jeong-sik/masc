(** A2 walker tests — Shell_ir -> Capability mapping.

    Walker is exhaustive over Shell_ir variants, so adding a new arm
    (say [Shell_ir.Group of t list] someday) forces a compile error in
    [capability_check.ml] first, then here when new tests are added. *)

open Masc_exec

let bin_ok name =
  match Exec_program.of_string name with
  | Ok b -> b
  | Error _ -> assert false

let simple ?(args = []) ?(env = []) ?(cwd = None) ?(redirects = [])
    ?(sandbox = Sandbox_target.host ()) bin
    : Shell_ir.simple =
  { bin; args; env; cwd; redirects; sandbox }

let lit s = Shell_ir.Lit (s, Shell_ir.default_meta)

let test_ls_emits_exec_bin () =
  let ir = Shell_ir.Simple (simple (bin_ok "ls")) in
  match Capability_check.of_ir ir with
  | [ Capability.Exec_program (b, []) ] ->
    assert (Exec_program.to_string b = "ls")
  | _ -> assert false

let test_git_status_classified_as_git_read () =
  let ir =
    Shell_ir.Simple (simple ~args:[ lit "status" ] (bin_ok "git"))
  in
  match Capability_check.of_ir ir with
  | [ Capability.Git (Git_op.Read `Status) ] -> ()
  | _ -> assert false

let test_git_status_with_cwd_flag_classified_as_git_read () =
  let ir =
    Shell_ir.Simple
      (simple ~args:[ lit "-C"; lit "/tmp/repo"; lit "status" ] (bin_ok "git"))
  in
  match Capability_check.of_ir ir with
  | [ Capability.Git (Git_op.Read `Status) ] -> ()
  | _ -> assert false

let test_git_push_force_destructive () =
  let ir =
    Shell_ir.Simple
      (simple
         ~args:[ lit "push"; lit "--force"; lit "origin"; lit "main" ]
         (bin_ok "git"))
  in
  match Capability_check.of_ir ir with
  | [ Capability.Git (Git_op.Destructive `Push_force) ] -> ()
  | _ -> assert false

let test_git_push_delete_destructive () =
  let ir =
    Shell_ir.Simple
      (simple
         ~args:[ lit "push"; lit "--delete"; lit "origin"; lit "feature-x" ]
         (bin_ok "git"))
  in
  match Capability_check.of_ir ir with
  | [ Capability.Git (Git_op.Destructive `Push_delete) ] -> ()
  | _ -> assert false

let test_git_push_delete_short_flag_destructive () =
  let ir =
    Shell_ir.Simple
      (simple
         ~args:[ lit "push"; lit "-d"; lit "origin"; lit "feature-x" ]
         (bin_ok "git"))
  in
  match Capability_check.of_ir ir with
  | [ Capability.Git (Git_op.Destructive `Push_delete) ] -> ()
  | _ -> assert false

let test_git_push_force_with_lease_destructive () =
  let ir =
    Shell_ir.Simple
      (simple
         ~args:[ lit "push"; lit "--force-with-lease=main"; lit "origin"; lit "main" ]
         (bin_ok "git"))
  in
  match Capability_check.of_ir ir with
  | [ Capability.Git (Git_op.Destructive `Push_force) ] -> ()
  | _ -> assert false

let test_git_push_mirror_destructive () =
  let ir =
    Shell_ir.Simple
      (simple ~args:[ lit "push"; lit "--mirror"; lit "origin" ] (bin_ok "git"))
  in
  match Capability_check.of_ir ir with
  | [ Capability.Git (Git_op.Destructive `Push_mirror) ] -> ()
  | _ -> assert false

let test_git_push_prune_destructive () =
  let ir =
    Shell_ir.Simple
      (simple
         ~args:[ lit "push"; lit "--prune"; lit "origin"; lit "main" ]
         (bin_ok "git"))
  in
  match Capability_check.of_ir ir with
  | [ Capability.Git (Git_op.Destructive `Push_delete) ] -> ()
  | _ -> assert false

let test_git_with_var_falls_back_to_exec_bin () =
  (* git ${REMOTE} push — can't classify statically, falls back. *)
  let ir =
    Shell_ir.Simple
      (simple ~args:[ Shell_ir.Var ("REMOTE", Shell_ir.default_meta); lit "push" ] (bin_ok "git"))
  in
  match Capability_check.of_ir ir with
  | [ Capability.Exec_program (b, _) ] ->
    assert (Exec_program.to_string b = "git")
  | _ -> assert false

let test_env_set_prefix_emitted_first () =
  let ir =
    Shell_ir.Simple
      (simple
         ~env:[ ("FOO", lit "bar"); ("BAZ", lit "qux") ]
         (bin_ok "ls"))
  in
  match Capability_check.of_ir ir with
  | [ Capability.Env_set ("FOO", _); Capability.Env_set ("BAZ", _);
      Capability.Exec_program _ ] -> ()
  | _ -> assert false

let test_redirect_write_becomes_write_path () =
  let p = Path_scope.classify ~raw:"/tmp/out.log" ~cwd:"/tmp" in
  let redir =
    Redirect_scope.File { fd = 1; target = p; mode = Redirect_scope.Write }
  in
  let ir =
    Shell_ir.Simple (simple ~redirects:[ redir ] (bin_ok "echo"))
  in
  match Capability_check.of_ir ir with
  | [ Capability.Exec_program _; Capability.Write_path (_, Redirect_scope.Write) ]
    -> ()
  | _ -> assert false

let test_redirect_read_becomes_read_path () =
  let p = Path_scope.classify ~raw:"/etc/passwd" ~cwd:"/tmp" in
  let redir =
    Redirect_scope.File { fd = 0; target = p; mode = Redirect_scope.Read }
  in
  let ir =
    Shell_ir.Simple (simple ~redirects:[ redir ] (bin_ok "cat"))
  in
  match Capability_check.of_ir ir with
  | [ Capability.Exec_program _; Capability.Read_path _ ] -> ()
  | _ -> assert false

let test_fd_dup_emits_no_path_cap () =
  let redir = Redirect_scope.Fd_to_fd { src = 2; dst = 1 } in
  let ir =
    Shell_ir.Simple (simple ~redirects:[ redir ] (bin_ok "ls"))
  in
  match Capability_check.of_ir ir with
  | [ Capability.Exec_program _ ] -> ()
  | _ -> assert false

let test_pipeline_folds_caps () =
  let stage1 = Shell_ir.Simple (simple (bin_ok "ls")) in
  let stage2 = Shell_ir.Simple (simple (bin_ok "cat")) in
  let ir = Shell_ir.Pipeline [ stage1; stage2 ] in
  match Capability_check.of_ir ir with
  | [ Capability.Pipeline_fold inner ] ->
    assert (List.length inner = 2);
    (match inner with
     | [ Capability.Exec_program (b1, _); Capability.Exec_program (b2, _) ] ->
       assert (Exec_program.to_string b1 = "ls");
       assert (Exec_program.to_string b2 = "cat")
     | _ -> assert false)
  | _ -> assert false

let () =
  test_ls_emits_exec_bin ();
  test_git_status_classified_as_git_read ();
  test_git_status_with_cwd_flag_classified_as_git_read ();
  test_git_push_force_destructive ();
  test_git_push_delete_destructive ();
  test_git_push_delete_short_flag_destructive ();
  test_git_push_force_with_lease_destructive ();
  test_git_push_mirror_destructive ();
  test_git_push_prune_destructive ();
  test_git_with_var_falls_back_to_exec_bin ();
  test_env_set_prefix_emitted_first ();
  test_redirect_write_becomes_write_path ();
  test_redirect_read_becomes_read_path ();
  test_fd_dup_emits_no_path_cap ();
  test_pipeline_folds_caps ();
  print_endline "[test_capability_check] all tests passed"
