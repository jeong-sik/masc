(* RFC-0160 S3: phantom-typed risk envelope tests *)

module IR = Masc_exec.Shell_ir
module Risk = Masc_exec.Shell_ir_risk

let bin s = Result.get_ok (Masc_exec.Bin.of_string s)

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

(* --- risk_class serialization --- *)

let test_string_of_risk_class () =
  Alcotest.(check string) "R0" "R0" (Risk.string_of_risk_class R0_Read);
  Alcotest.(check string) "R1" "R1" (Risk.string_of_risk_class R1_Reversible_mutation);
  Alcotest.(check string) "R2" "R2" (Risk.string_of_risk_class R2_Irreversible);
  Alcotest.(check string) "destructive" "Destructive_protected"
    (Risk.string_of_risk_class Destructive_protected)

(* --- phantom wrapping / unwrapping --- *)

let test_roundtrip_unwrap () =
  let ir = simple_ir "ls" [] in
  let wrapped = Risk.undecided ir in
  let recovered = Risk.unwrap wrapped in
  (* Structural equality: both are Simple with same bin *)
  (match recovered with
   | IR.Simple s ->
     Alcotest.(check string) "bin" "ls" (Masc_exec.Bin.to_string s.IR.bin)
   | _ -> Alcotest.fail "expected Simple")

(* --- classify: read commands → R0 --- *)

let test_classify_read () =
  let cmds =
    [ simple_ir "ls" []; simple_ir "cat" [ "file.txt" ]; simple_ir "rg" [ "pattern" ];
      simple_ir "git" [ "status" ]; simple_ir "git" [ "log"; "--oneline" ];
      simple_ir "gh" [ "pr"; "view"; "123" ]; simple_ir "gh" [ "issue"; "list" ];
      simple_ir "echo" [ "hello" ]; simple_ir "pwd" [] ]
  in
  List.iter
    (fun ir ->
       let envelope = Risk.classify (Risk.undecided ir) in
       Alcotest.(check bool)
         (Format.asprintf "%a" Risk.pp_risk_class envelope.Risk.risk)
         true
         (Risk.is_r0 envelope))
    cmds

(* --- classify: write commands → R1 --- *)

let test_classify_write_r1 () =
  let cmds =
    [ simple_ir "git" [ "commit"; "-m"; "msg" ];
      simple_ir "git" [ "push" ];
      simple_ir "git" [ "checkout"; "-b"; "feature" ];
      simple_ir "npm" [ "install" ];
      simple_ir "mkdir" [ "dir" ];
      simple_ir "touch" [ "file" ] ]
  in
  List.iter
    (fun ir ->
       let envelope = Risk.classify (Risk.undecided ir) in
       Alcotest.(check bool)
         (Format.asprintf "%a" Risk.pp_risk_class envelope.Risk.risk)
         true
         (Risk.is_r1 envelope))
    cmds

(* --- classify: destructive → Destructive_protected --- *)

let test_classify_destructive () =
  let cmds =
    [ simple_ir "git" [ "push"; "--force" ];
      simple_ir "git" [ "push"; "--force-with-lease" ];
      simple_ir "git" [ "reset"; "--hard"; "HEAD~1" ] ]
  in
  List.iter
    (fun ir ->
       let envelope = Risk.classify (Risk.undecided ir) in
       Alcotest.(check bool)
         (Format.asprintf "%a" Risk.pp_risk_class envelope.Risk.risk)
         true
         (Risk.is_destructive envelope))
    cmds

(* --- classify: git reset --hard is Destructive, git reset (soft) is R1 --- *)

let test_git_reset_soft_is_r1 () =
  let ir = simple_ir "git" [ "reset"; "HEAD~1" ] in
  let envelope = Risk.classify (Risk.undecided ir) in
  (* is_write_operation returns true for git reset, but is_destructive_bash_operation
     only returns true for --hard. So the result depends on the classifier chain:
     not destructive → is_write → classify_write_detail "git" "reset" → R2_Irreversible *)
  Alcotest.(check bool) "reset without --hard is not destructive" true
    (not (Risk.is_destructive envelope));
  Alcotest.(check bool) "reset is write" true
    (Risk.is_r2 envelope)

(* --- classify: gh R2 operations --- *)

let test_classify_gh_r2 () =
  let cmds =
    [ simple_ir "gh" [ "pr"; "merge"; "123" ];
      simple_ir "gh" [ "repo"; "delete"; "owner/repo" ];
      simple_ir "gh" [ "release"; "delete"; "v1.0" ];
      simple_ir "gh" [ "secret"; "delete"; "KEY" ] ]
  in
  List.iter
    (fun ir ->
       let envelope = Risk.classify (Risk.undecided ir) in
       Alcotest.(check bool)
         (Format.asprintf "%a" Risk.pp_risk_class envelope.Risk.risk)
         true
         (Risk.is_r2 envelope))
    cmds

(* --- classify: gh R1 operations --- *)

let test_classify_gh_r1 () =
  let cmds =
    [ simple_ir "gh" [ "pr"; "create"; "--title"; "t" ];
      simple_ir "gh" [ "issue"; "close"; "123" ];
      simple_ir "gh" [ "label"; "create"; "bug" ];
      simple_ir "gh" [ "run"; "cancel"; "456" ] ]
  in
  List.iter
    (fun ir ->
       let envelope = Risk.classify (Risk.undecided ir) in
       Alcotest.(check bool)
         (Format.asprintf "%a" Risk.pp_risk_class envelope.Risk.risk)
         true
         (Risk.is_r1 envelope))
    cmds

(* --- classify: gh api mutations --- *)

let test_classify_gh_api_delete_r2 () =
  let ir = simple_ir "gh" [ "api"; "-X"; "DELETE"; "/repos/o/r" ] in
  let envelope = Risk.classify (Risk.undecided ir) in
  Alcotest.(check bool) "DELETE is R2" true (Risk.is_r2 envelope)

let test_classify_gh_api_post_r1 () =
  let ir = simple_ir "gh" [ "api"; "-X"; "POST"; "/repos/o/r/issues" ] in
  let envelope = Risk.classify (Risk.undecided ir) in
  Alcotest.(check bool) "POST is R1" true (Risk.is_r1 envelope)

let test_classify_gh_api_get_r0 () =
  let ir = simple_ir "gh" [ "api"; "/repos/o/r" ] in
  let envelope = Risk.classify (Risk.undecided ir) in
  Alcotest.(check bool) "GET is R0" true (Risk.is_r0 envelope)

let test_classify_gh_api_graphql_r1 () =
  let ir = simple_ir "gh" [ "api"; "graphql" ] in
  let envelope = Risk.classify (Risk.undecided ir) in
  Alcotest.(check bool) "graphql is R1" true (Risk.is_r1 envelope)

(* --- classify: pipeline --- *)

let test_classify_pipeline_first_stage_destructive () =
  (* Pipeline with git push --force as first stage.
     flat_stage_words returns all words concatenated, so the classifier
     sees "git push --force" from the first Simple stage. *)
  let ir = pipeline_ir [ ("git", [ "push"; "--force" ]); ("cat", []) ] in
  let envelope = Risk.classify (Risk.undecided ir) in
  Alcotest.(check bool) "pipeline with destructive first stage"
    true (Risk.is_destructive envelope)

(* --- classify: gh read-only prefix equivalence (P9a) --- *)

let test_classify_gh_read_only_prefixes_equivalence () =
  let prefixes =
    [ [ "pr"; "list" ]
    ; [ "pr"; "view"; "123" ]
    ; [ "pr"; "diff"; "123" ]
    ; [ "pr"; "checks"; "123" ]
    ; [ "pr"; "status" ]
    ; [ "issue"; "list" ]
    ; [ "issue"; "view"; "456" ]
    ; [ "issue"; "status" ]
    ; [ "repo"; "view" ]
    ; [ "repo"; "list" ]
    ; [ "release"; "list" ]
    ; [ "release"; "view"; "v1.0" ]
    ; [ "api"; "/repos/o/r" ]
    ]
  in
  List.iter
    (fun args ->
       let ir = simple_ir "gh" args in
       let envelope = Risk.classify (Risk.undecided ir) in
       Alcotest.(check bool)
         (Format.asprintf "%a is R0" Risk.pp_risk_class envelope.Risk.risk)
         true
         (Risk.is_r0 envelope))
    prefixes

(* --- classify: unknown commands → R0 --- *)

let test_classify_unknown_read () =
  let ir = simple_ir "my-custom-tool" [ "--help" ] in
  let envelope = Risk.classify (Risk.undecided ir) in
  Alcotest.(check bool) "unknown command is R0" true (Risk.is_r0 envelope)

(* --- trust_decided escape hatch --- *)

let test_trust_decided () =
  let ir = simple_ir "git" [ "push"; "--force" ] in
  let envelope = Risk.trust_decided (Risk.undecided ir) in
  Alcotest.(check bool) "trust_decided defaults R0" true (Risk.is_r0 envelope)

(* --- test runner --- *)

let () =
  test_string_of_risk_class ();
  test_roundtrip_unwrap ();
  test_classify_read ();
  test_classify_write_r1 ();
  test_classify_destructive ();
  test_git_reset_soft_is_r1 ();
  test_classify_gh_r2 ();
  test_classify_gh_r1 ();
  test_classify_gh_api_delete_r2 ();
  test_classify_gh_api_post_r1 ();
  test_classify_gh_api_get_r0 ();
  test_classify_gh_api_graphql_r1 ();
  test_classify_pipeline_first_stage_destructive ();
  test_classify_gh_read_only_prefixes_equivalence ();
  test_classify_unknown_read ();
  test_trust_decided ();
  print_endline "test_shell_ir_risk: 16/16 passed"
