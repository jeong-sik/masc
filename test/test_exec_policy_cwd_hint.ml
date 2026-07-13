(** Explicit Shell IR path-scope contract.

    [Exec_policy] validates typed [cwd] and redirect targets. Positional argv
    remains opaque application data: command names, flags, and token shapes do
    not create an inferred filesystem authorization boundary.

    The suite also pins the filesystem-grounded hint that
    [Exec_policy.existing_sibling_dirs_hint] fills into a [Cwd_not_directory]
    error.

    The hint must come from real directory entries read via [Sys.readdir],
    never from a hardcoded rename table or a substring/similarity match.
    A stale "repos/masc-mcp" path must surface the real "repos/" entries so
    the caller self-corrects from ground truth. *)

let rec mkdir_p path =
  if not (Sys.file_exists path)
  then (
    mkdir_p (Filename.dirname path);
    try Sys.mkdir path 0o755 with Sys_error _ -> ())
;;

let rec rm_rf path =
  match Sys.is_directory path with
  | true ->
    Array.iter (fun e -> rm_rf (Filename.concat path e)) (Sys.readdir path);
    (try Sys.rmdir path with Sys_error _ -> ())
  | false -> (try Sys.remove path with Sys_error _ -> ())
  | exception Sys_error _ -> ()
;;

let with_temp_tree f =
  let root = Filename.temp_dir "masc_cwd_hint" "" in
  Fun.protect ~finally:(fun () -> rm_rf root) (fun () -> f root)
;;

let test_lists_existing_sibling_dirs () =
  with_temp_tree (fun root ->
    mkdir_p (Filename.concat root "repos/masc");
    mkdir_p (Filename.concat root "repos/oas");
    let hint = Exec_policy.existing_sibling_dirs_hint ~workdir:root "repos/masc-mcp" in
    Alcotest.(check (option string))
      "stale repos/masc-mcp surfaces the real repos/ entries (sorted, no rename table)"
      (Some "(existing directories under repos/: masc, oas)")
      hint)
;;

let test_none_when_ancestor_has_no_subdirs () =
  with_temp_tree (fun root ->
    let hint = Exec_policy.existing_sibling_dirs_hint ~workdir:root "nope/missing" in
    Alcotest.(check (option string))
      "no child directories under nearest existing ancestor -> None"
      None
      hint)
;;

let test_ignores_plain_files () =
  with_temp_tree (fun root ->
    mkdir_p (Filename.concat root "repos/masc");
    (* a plain file sibling must NOT appear in the directory listing *)
    let oc = open_out (Filename.concat root "repos/README.md") in
    close_out oc;
    let hint = Exec_policy.existing_sibling_dirs_hint ~workdir:root "repos/gone" in
    Alcotest.(check (option string))
      "plain files are excluded; only real directories are listed"
      (Some "(existing directories under repos/: masc)")
      hint)
;;

let lit value = Masc_exec.Shell_ir.Lit (value, Masc_exec.Shell_ir.default_meta)

let shell_ir ?cwd ?(redirects = []) ~workdir args =
  let cwd =
    Option.map (fun raw -> Masc_exec.Path_scope.classify ~raw ~cwd:workdir) cwd
  in
  let bin =
    match Masc_exec.Exec_program.of_string "cat" with
    | Ok bin -> bin
    | Error _ -> Alcotest.fail "literal cat executable must be non-empty"
  in
  Masc_exec.Shell_ir.Simple
    { bin
    ; args = List.map lit args
    ; env = []
    ; cwd
    ; redirects
    ; sandbox = Masc_exec.Sandbox_target.host ()
    }
;;

let test_positional_argv_is_not_inferred_as_path () =
  with_temp_tree (fun workdir ->
    let ir = shell_ir ~workdir [ "/etc/passwd"; "../../opaque-token" ] in
    Alcotest.(check bool)
      "argv is opaque to exec policy"
      true
      (Result.is_ok (Exec_policy.validate_shell_ir_paths ~workdir ir)))
;;

let test_explicit_cwd_outside_workdir_is_rejected () =
  with_temp_tree (fun workdir ->
    let ir = shell_ir ~cwd:"/etc" ~workdir [] in
    Alcotest.(check bool)
      "typed cwd remains contained"
      true
      (Result.is_error (Exec_policy.validate_shell_ir_paths ~workdir ir)))
;;

let test_explicit_redirect_outside_workdir_is_rejected () =
  with_temp_tree (fun workdir ->
    let target = Masc_exec.Path_scope.classify ~raw:"/etc/passwd" ~cwd:workdir in
    let redirect =
      Masc_exec.Redirect_scope.File
        { fd = 1; target; mode = Masc_exec.Redirect_scope.Write }
    in
    let ir = shell_ir ~redirects:[ redirect ] ~workdir [] in
    Alcotest.(check bool)
      "typed redirect remains contained"
      true
      (Result.is_error (Exec_policy.validate_shell_ir_paths ~workdir ir)))
;;

let () =
  Alcotest.run
    "exec_policy_cwd_hint"
    [ ( "existing_sibling_dirs_hint"
      , [ Alcotest.test_case "lists existing sibling dirs" `Quick test_lists_existing_sibling_dirs
        ; Alcotest.test_case "none when no subdirs" `Quick test_none_when_ancestor_has_no_subdirs
        ; Alcotest.test_case "ignores plain files" `Quick test_ignores_plain_files
        ] )
    ; ( "explicit path scopes"
      , [ Alcotest.test_case
            "positional argv is opaque"
            `Quick
            test_positional_argv_is_not_inferred_as_path
        ; Alcotest.test_case
            "cwd outside workdir is rejected"
            `Quick
            test_explicit_cwd_outside_workdir_is_rejected
        ; Alcotest.test_case
            "redirect outside workdir is rejected"
            `Quick
            test_explicit_redirect_outside_workdir_is_rejected
        ] )
    ]
;;
