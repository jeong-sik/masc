(* Goal task-634 / issue #26289 regression: the script lane's destination
   paths must be nameable by the same closed vocabulary the gate speaks.
   [Execute_script_paths.script_destinations] names what it can speak and
   leaves everything else to the box (Outside_vocabulary — see the
   module header for why that is fail-OPEN, not fail-closed): naming is
   partial, but every destination it DOES name is handed to the same
   judge the execute path already uses for cwd and redirects
   ([Exec_policy.validate_shell_ir_paths]'s own [validate_path_value]). *)

let raws = function
  | Execute_script_paths.Destinations ds -> Some (List.map (fun d -> d.Execute_script_paths.raw) ds)
  | Outside_vocabulary -> None
;;

let dest_test name expected text =
  Alcotest.test_case name `Quick (fun () ->
      match Execute_script_paths.script_destinations ~limit:8 text with
      | Destinations ds ->
        Alcotest.(check (option (list string)))
          name (Some expected) (Some (List.map (fun d -> d.Execute_script_paths.raw) ds))
      | Outside_vocabulary ->
        Alcotest.failf "%s: expected destinations %s, got Outside_vocabulary" name
          (String.concat ", " expected))
;;

let outside_test name text =
  Alcotest.test_case name `Quick (fun () ->
      match Execute_script_paths.script_destinations ~limit:8 text with
      | Destinations ds ->
        Alcotest.failf "%s: expected Outside_vocabulary, got [%s]" name
          (String.concat "; " (List.map (fun d -> d.Execute_script_paths.raw) ds))
      | Outside_vocabulary -> ())
;;

let empty_test name text =
  Alcotest.test_case name `Quick (fun () ->
      match Execute_script_paths.script_destinations ~limit:8 text with
      | Destinations ds -> Alcotest.(check int) name 0 (List.length ds)
      | Outside_vocabulary ->
        Alcotest.fail (name ^ ": expected zero destinations, got Outside_vocabulary"))
;;

let is_cd_test name expected text =
  Alcotest.test_case name `Quick (fun () ->
      match Execute_script_paths.script_destinations ~limit:8 text with
      | Destinations [ d ] ->
        Alcotest.(check bool) name expected d.Execute_script_paths.is_cd
      | Destinations ds ->
        Alcotest.failf "%s: expected exactly one destination, got %d" name (List.length ds)
      | Outside_vocabulary -> Alcotest.fail (name ^ ": expected a destination, got Outside_vocabulary"))
;;

let suite =
  [ dest_test "cd literal target" [ "/tmp/t634/wt" ] "cd /tmp/t634/wt && dune build @runtest"
  ; dest_test "cd relative target" [ "/tmp/rel" ] "cd /tmp/rel && ls"
  ; is_cd_test "cd target is flagged is_cd" true "cd /tmp/t634/wt && ls"
  ; is_cd_test "mkdir target is not flagged is_cd" false "mkdir -p /tmp/t634/wt"
  ; outside_test "chained cd refused" "cd /tmp/a && cd /tmp/b && ls"
  ; outside_test "variable cd refused" "cd $HOME && ls"
  ; outside_test "concat destination refused" "cd /tmp/$x && ls"
  ; outside_test "substitution destination refused" "cd $(dirname /tmp/a/b) && ls"
  ; dest_test "git -C target" [ "/tmp/wt" ] "git -C /tmp/wt status --short"
  ; dest_test "git worktree add target" [ "/tmp/wt" ] "git worktree add /tmp/wt"
  ; dest_test "git worktree add target ignores the trailing commit-ish" [ "/tmp/wt" ]
      "git worktree add /tmp/wt my-branch"
  ; empty_test "git without -C or worktree-add owns nothing" "git status --short"
  ; outside_test "git worktree add via variable refused" "git worktree add $DEST"
  ; dest_test "mkdir literal targets" [ "/tmp/a"; "/tmp/b" ] "mkdir -p /tmp/a /tmp/b"
  ; dest_test "rm flags skipped" [ "/tmp/a" ] "rm -rf /tmp/a"
  ; dest_test "cp both operands" [ "/tmp/a"; "/tmp/b" ] "cp /tmp/a /tmp/b"
  ; dest_test "mv both operands" [ "/tmp/a"; "/tmp/b" ] "mv /tmp/a /tmp/b"
  ; outside_test "glob destination refused" "mkdir /tmp/t634-*"
  ; outside_test "variable in mkdir refused" "mkdir -p /tmp/$x"
  ; Alcotest.test_case "limit exceeded is a refusal, not truncation" `Quick (fun () ->
        match Execute_script_paths.script_destinations ~limit:1 "mkdir -p /a /b" with
        | Destinations _ -> Alcotest.fail "limit 1 must refuse two destinations"
        | Outside_vocabulary -> ())
  ; empty_test "non-owning commands own nothing" "echo hi | sort"
  ; empty_test "pipeline of non-owners" "printf 'x\\n' | grep x"
  ; empty_test "sequence of non-owners" "dune build @check; echo done"
  ]
;;

(* judge_operands: the naming pass wired to a fake judge, so the pass
   itself (walking argv/sh-costumed/pipeline/sequence IR, calling the
   judge on every named destination and requiring [is_cd] to flip
   [requires_existing_dir]) is exercised without touching the real
   filesystem whitelist. *)
let fake_judge ~allowed_prefix ~requires_existing_dir:_ path =
  if String.length path >= String.length allowed_prefix
     && String.sub path 0 (String.length allowed_prefix) = allowed_prefix
  then Ok ()
  else Error ("outside: " ^ path)
;;

let judge_test name ~expect_ok text =
  Alcotest.test_case name `Quick (fun () ->
      match Masc_exec_bash_parser.Bash.parse_string text with
      | Masc_exec.Parsed.Parsed ir ->
        let result =
          Execute_script_paths.judge_operands
            ~judge:(fake_judge ~allowed_prefix:"/tmp/")
            ~limit:8
            ir
        in
        (match result, expect_ok with
         | Ok (), true | Error _, false -> ()
         | Ok (), false -> Alcotest.fail (name ^ ": expected a rejection, got Ok")
         | Error detail, true -> Alcotest.failf "%s: expected Ok, got Error %s" name detail)
      | Masc_exec.Parsed.Too_complex _ | Masc_exec.Parsed.Parse_error _
      | Masc_exec.Parsed.Parse_aborted _ -> Alcotest.fail (name ^ ": text did not parse"))
;;

let judge_suite =
  [ judge_test "argv git worktree add inside allowed prefix" ~expect_ok:true
      "git worktree add /tmp/wt"
  ; judge_test "argv git worktree add outside allowed prefix is rejected" ~expect_ok:false
      "git worktree add /etc/wt"
  ; judge_test "argv mkdir outside allowed prefix is rejected" ~expect_ok:false "mkdir /etc/x"
  ; judge_test "unnameable operand (glob) is left to the box, not rejected" ~expect_ok:true
      "mkdir /tmp/t634-*"
  ; judge_test "non-owning command is left alone" ~expect_ok:true "echo /etc/passwd"
  ]
;;

(* ------------------------------------------------------------------ *)
(* The coupling pass (task-1565): the same judge validate_shell_ir_paths *)
(* itself uses, on the real allowlist, with workdir=None — the plain    *)
(* argv path that was a total no-op before 644c0ea.  Before that       *)
(* commit every one of the rejected cases below returned Ok () because  *)
(* the match on workdir short-circuited to Ok before any operand was    *)
(* named.  These tests pin the after side of that before/after table:   *)
(* a closed-table argv operand outside the allowlist (/tmp, the         *)
(* process cwd, the sandbox workspace root) is rejected by the same     *)
(* judge and the same message vocabulary as cwd and redirects.          *)
(* ------------------------------------------------------------------ *)

let program bin =
  match Masc_exec.Exec_program.of_string bin with
  | Ok p -> p
  | Error _ -> Alcotest.failf "literal %s executable must parse" bin
;;

let lit_arg value = Masc_exec.Shell_ir.Lit (value, Masc_exec.Shell_ir.default_meta) ;;

let argv_ir bin args =
  Masc_exec.Shell_ir.Simple
    { bin = program bin
    ; args = List.map lit_arg args
    ; env = []
    ; cwd = None
    ; redirects = []
    ; sandbox = Masc_exec.Sandbox_target.host ()
    }
;;

(* A real /tmp directory this suite creates, so the is_cd existence half
   of the judge is exercised against ground truth rather than assumed. *)
let with_tmp_scratch f =
  let root = Filename.temp_dir "masc_t1565" "" in
  Fun.protect ~finally:(fun () ->
      let rec rm_rf path =
        match Sys.is_directory path with
        | true ->
          Array.iter (fun e -> rm_rf (Filename.concat path e)) (Sys.readdir path);
          (try Sys.rmdir path with Sys_error _ -> ())
        | false -> (try Sys.remove path with Sys_error _ -> ())
        | exception Sys_error _ -> ()
      in
      rm_rf root)
    (fun () -> f root)
;;

let coupling_test name ?workdir ~expect_ok ir =
  Alcotest.test_case name `Quick (fun () ->
      match Exec_policy.validate_shell_ir_paths ?workdir ir with
      | Ok () -> if not expect_ok then Alcotest.fail (name ^ ": expected a rejection, got Ok")
      | Error msg ->
        if expect_ok then Alcotest.failf "%s: expected Ok, got Error %s" name msg)
;;

let coupling_suite =
  [ coupling_test "plain argv git -C outside allowlist is judged (workdir=None)"
      ~expect_ok:false
      (argv_ir "git" [ "-C"; "/etc"; "status" ])
  ; coupling_test "plain argv mkdir outside allowlist is judged (workdir=None)"
      ~expect_ok:false
      (argv_ir "mkdir" [ "/etc/never" ])
  ; coupling_test "plain argv cd outside allowlist is judged (workdir=None)"
      ~expect_ok:false
      (argv_ir "cd" [ "/etc" ])
  ; coupling_test "plain argv cd to a missing /tmp directory is cwd_not_directory"
      ~expect_ok:false
      (argv_ir "cd" [ "/tmp/masc-t1565-must-not-exist" ])
  ; coupling_test "plain argv cd to an existing /tmp directory passes (workdir=None)"
      ~expect_ok:true
      (argv_ir "cd" [ "/tmp" ])
  ; (* The script lane answers the same judge through the re-opened
       subscript — the cd_promote half of the coupling. *)
    Alcotest.test_case
      "sh -c cd outside allowlist is judged through the re-opened script (workdir=None)"
      `Quick
      (fun () ->
        match
          Exec_policy.validate_shell_ir_paths (argv_ir "sh" [ "-c"; "cd /etc && ls" ])
        with
        | Ok () -> Alcotest.fail "re-opened cd /etc must be rejected"
        | Error _ -> ())
  ; coupling_test "non-owning plain argv stays opaque (workdir=None)"
      ~expect_ok:true
      (argv_ir "cat" [ "/etc/passwd" ])
  ; coupling_test "unnameable operand (variable) is left to the box (workdir=None)"
      ~expect_ok:true
      (argv_ir "mkdir" [ "/tmp/$x" ])
  ]
;;

let scratch_suite =
  [ Alcotest.test_case
      "cd to a suite-created /tmp directory passes the existence half"
      `Quick
      (fun () ->
        with_tmp_scratch (fun root ->
            match Exec_policy.validate_shell_ir_paths (argv_ir "cd" [ root ]) with
            | Ok () -> ()
            | Error msg -> Alcotest.failf "cd %s must pass, got: %s" root msg))
  ; Alcotest.test_case
      "mkdir destination under a suite-created /tmp directory is named and allowed"
      `Quick
      (fun () ->
        with_tmp_scratch (fun root ->
            let target = Filename.concat root "wt" in
            match
              Exec_policy.validate_shell_ir_paths (argv_ir "mkdir" [ target ])
            with
            | Ok () -> ()
            | Error msg -> Alcotest.failf "mkdir %s must pass, got: %s" target msg))
  ]
;;

let () =
  Alcotest.run "keeper_tool_execute_script_paths"
    [ "destinations", suite
    ; "judge_operands", judge_suite
    ; "coupling", coupling_suite
    ; "tmp scratch", scratch_suite
    ]
;;
