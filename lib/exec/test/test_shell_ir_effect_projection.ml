(* RFC-0208 P0: Shell IR Effect Projection golden tests.

   Guarantees: project_risk (extract ir) = classify ir
   for every command in the test corpus. *)

module IR = Masc_exec.Shell_ir
module Risk = Masc_exec.Shell_ir_risk
module Effect = Masc_exec.Exec_effect

let bin s = Result.get_ok (Masc_exec.Exec_program.of_string s)

let simple_ir bin_str args =
  IR.Simple
    { IR.bin = bin bin_str
    ; args = List.map (fun a -> IR.Lit (a, IR.default_meta)) args
    ; env = []
    ; cwd = None
    ; redirects = []
    ; sandbox = Masc_exec.Sandbox_target.host ()
    }

let pipeline_ir stages =
  IR.Pipeline (List.map (fun (b, a) -> simple_ir b a) stages)

(* --------------------------------------------------------------------------- *)
(** {1 Golden property: project_risk (extract ir) = classify ir} *)

let check_projection ir =
  let expected = (Risk.classify (Risk.undecided ir)).risk in
  let actual = Effect.project_risk (Effect.extract ir) in
  Alcotest.(check bool)
    (Format.asprintf "project_risk ≡ classify: expected %a, got %a"
       Risk.pp_risk_class expected Risk.pp_risk_class actual)
    true
    (expected = actual)

let test_golden_r0 () =
  let cmds =
    [ simple_ir "ls" []
    ; simple_ir "cat" [ "file.txt" ]
    ; simple_ir "rg" [ "pattern" ]
    ; simple_ir "git" [ "status" ]
    ; simple_ir "git" [ "log"; "--oneline" ]
    ; simple_ir "git" [ "branch"; "-a"; "--list"; "*20083*" ]
    ; simple_ir "git" [ "branch"; "--show-current" ]
    ; simple_ir "gh" [ "pr"; "view"; "123" ]
    ; simple_ir "gh" [ "issue"; "list" ]
    ; simple_ir "echo" [ "hello" ]
    ; simple_ir "pwd" []
    ; simple_ir "find" [ "."; "-name"; "*.ml" ]
    ; simple_ir "head" [ "-n"; "10"; "file.txt" ]
    ; simple_ir "grep" [ "foo"; "bar.txt" ]
    ]
  in
  List.iter check_projection cmds

let test_golden_r1 () =
  let cmds =
    [ simple_ir "git" [ "commit"; "-m"; "msg" ]
    ; simple_ir "git" [ "push" ]
    ; simple_ir "git" [ "checkout"; "-b"; "feature" ]
    ; simple_ir "git" [ "branch"; "new-branch" ]
    ; simple_ir "git" [ "branch"; "-d"; "old-branch" ]
    ; simple_ir "git" [ "branch"; "-m"; "old"; "new" ]
    ; simple_ir "npm" [ "install" ]
    ; simple_ir "mkdir" [ "dir" ]
    ; simple_ir "touch" [ "file" ]
    ; simple_ir "curl" [ "https://example.com" ]
    ; simple_ir "wget" [ "https://example.com/file" ]
    ; simple_ir "ssh" [ "host"; "uptime" ]
    ; simple_ir "scp" [ "file"; "host:/tmp/file" ]
    ; simple_ir "rsync" [ "-av"; "src/"; "host:/tmp/src/" ]
    ; simple_ir "cp" [ "a"; "b" ]
    ; simple_ir "mv" [ "a"; "b" ]
    ; simple_ir "sed" [ "-i"; "s/a/b/"; "file.txt" ]
    ]
  in
  List.iter check_projection cmds

let test_golden_r2 () =
  let cmds =
    [ simple_ir "rm" [ "file.txt" ]
    ; simple_ir "rm" [ "-r"; "dir" ]
    ; simple_ir "rmdir" [ "dir" ]
    ; simple_ir "git" [ "reset"; "--hard"; "HEAD~1" ]
    ; simple_ir "dd" [ "if=/dev/zero"; "of=/tmp/img"; "bs=1M"; "count=10" ]
    ]
  in
  List.iter check_projection cmds

let test_golden_destructive () =
  let cmds =
    [ simple_ir "git" [ "push"; "--force"; "origin"; "main" ]
    ; simple_ir "git" [ "push"; "--force-with-lease"; "origin"; "main" ]
    ; simple_ir "bash" [ "-c"; "echo x > /tmp/x" ]
    ; simple_ir "sh" [ "-c"; "echo x > /tmp/x" ]
    ; simple_ir "python3" [ "-c"; "open('x','w').write('1')" ]
    ; simple_ir "node" [ "-e"; "require('fs').writeFileSync('x','1')" ]
    ; simple_ir "sudo" [ "rm"; "file.txt" ]
    ; simple_ir "rm" [ "-rf"; "/tmp/dir" ]
    ]
  in
  List.iter check_projection cmds

let test_golden_pipeline () =
  let cmds =
    [ pipeline_ir [ "cat", [ "file.txt" ]; "grep", [ "pattern" ] ]
    ; pipeline_ir [ "echo", [ "x" ]; "tee", [ "file.txt" ] ]
    ; pipeline_ir [ "ls", []; "sort", [] ]
    ; pipeline_ir [ "cat", [ "f" ]; "bash", [ "-c"; "cat > /dev/null" ] ]
    ]
  in
  List.iter check_projection cmds

(* --------------------------------------------------------------------------- *)
(** {1 Effect-level risk floor tests} *)

let test_effect_kind_floor () =
  Alcotest.(check bool)
    "Fs_read → R0"
    true
    (Effect.effect_kind_floor Fs_read = Risk.R0_Read);
  Alcotest.(check bool)
    "Fs_write → R1"
    true
    (Effect.effect_kind_floor Fs_write = Risk.R1_Reversible_mutation);
  Alcotest.(check bool)
    "Fs_delete → R2"
    true
    (Effect.effect_kind_floor Fs_delete = Risk.R2_Irreversible);
  Alcotest.(check bool)
    "Shell_interpreter → Destructive_protected"
    true
    (Effect.effect_kind_floor Shell_interpreter = Risk.Destructive_protected);
  Alcotest.(check bool)
    "Net_egress → R1"
    true
    (Effect.effect_kind_floor Net_egress = Risk.R1_Reversible_mutation);
  Alcotest.(check bool)
    "Credential_use → R1"
    true
    (Effect.effect_kind_floor Credential_use = Risk.R1_Reversible_mutation);
  Alcotest.(check bool)
    "External_mutation → R1"
    true
    (Effect.effect_kind_floor External_mutation = Risk.R1_Reversible_mutation);
  Alcotest.(check bool)
    "Process_spawn → R1"
    true
    (Effect.effect_kind_floor Process_spawn = Risk.R1_Reversible_mutation)

(* --------------------------------------------------------------------------- *)
(** {1 Extract shape tests} *)

let test_extract_non_empty () =
  let ir = simple_ir "ls" [] in
  let effects = Effect.extract ir in
  Alcotest.(check bool) "extract returns at least one effect" true (List.length effects >= 1)

let test_extract_scope_populated () =
  let ir = simple_ir "cat" [ "file.txt" ] in
  let effects = Effect.extract ir in
  Alcotest.(check int) "extract scope is populated" 1 (List.length effects);
  let e = List.hd effects in
  Alcotest.(check bool) "scope contains path" true (List.mem "file.txt" e.scope)

(* --------------------------------------------------------------------------- *)
(** {1 Alcotest entrypoint} *)

let () =
  Alcotest.run
    "shell_ir_effect_projection"
    [ ( "golden.r0"
      , [ Alcotest.test_case "project_risk ≡ classify (R0 corpus)" `Quick test_golden_r0 ]
      )
    ; ( "golden.r1"
      , [ Alcotest.test_case "project_risk ≡ classify (R1 corpus)" `Quick test_golden_r1 ]
      )
    ; ( "golden.r2"
      , [ Alcotest.test_case "project_risk ≡ classify (R2 corpus)" `Quick test_golden_r2 ]
      )
    ; ( "golden.destructive"
      , [ Alcotest.test_case
            "project_risk ≡ classify (Destructive corpus)"
            `Quick
            test_golden_destructive
        ]
      )
    ; ( "golden.pipeline"
      , [ Alcotest.test_case
            "project_risk ≡ classify (Pipeline corpus)"
            `Quick
            test_golden_pipeline
        ]
      )
    ; ( "effect_kind_floor"
      , [ Alcotest.test_case "effect_kind_floor mapping" `Quick test_effect_kind_floor ]
      )
    ; ( "extract.shape"
      , [ Alcotest.test_case "extract returns non-empty" `Quick test_extract_non_empty
        ; Alcotest.test_case "extract scope populated" `Quick test_extract_scope_populated
        ]
      )
    ]
;;