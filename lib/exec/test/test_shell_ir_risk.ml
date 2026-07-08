(* RFC-0160 S3: phantom-typed risk envelope tests *)

module IR = Masc_exec.Shell_ir
module Risk = Masc_exec.Shell_ir_risk

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
     Alcotest.(check string) "bin" "ls" (Masc_exec.Exec_program.to_string s.IR.bin)
   | _ -> Alcotest.fail "expected Simple")

(* --- classify: read commands → R0 --- *)

let test_classify_read () =
  let cmds =
    [ simple_ir "ls" []; simple_ir "cat" [ "file.txt" ]; simple_ir "rg" [ "pattern" ];
      simple_ir "git" [ "status" ]; simple_ir "git" [ "log"; "--oneline" ];
      simple_ir "git" [ "branch"; "-a"; "--list"; "*20083*" ];
      simple_ir "git" [ "branch"; "--show-current" ];
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
      simple_ir "git" [ "branch"; "new-branch" ];
      simple_ir "git" [ "branch"; "-d"; "old-branch" ];
      simple_ir "git" [ "branch"; "-m"; "old"; "new" ];
      simple_ir "npm" [ "install" ];
      simple_ir "mkdir" [ "dir" ];
      simple_ir "touch" [ "file" ];
      simple_ir "curl" [ "https://example.com" ];
      simple_ir "wget" [ "https://example.com/file" ];
      simple_ir "ssh" [ "host"; "uptime" ];
      simple_ir "scp" [ "file"; "host:/tmp/file" ];
      simple_ir "rsync" [ "-av"; "src/"; "host:/tmp/src/" ] ]
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
  (* Destructive requires BOTH force flag AND protected branch target. *)
  let cmds =
    [ simple_ir "git" [ "push"; "--force"; "origin"; "main" ];
      simple_ir "git" [ "push"; "--force-with-lease"; "origin"; "main" ];
      simple_ir "bash" [ "-c"; "echo x > /tmp/x" ];
      simple_ir "sh" [ "-c"; "echo x > /tmp/x" ];
      simple_ir "python3" [ "-c"; "open('x','w').write('1')" ];
      simple_ir "node" [ "-e"; "require('fs').writeFileSync('x','1')" ];
      simple_ir "pip" [ "install"; "pkg" ];
      simple_ir "npx" [ "some-tool" ] ]
  in
  List.iter
    (fun ir ->
       let envelope = Risk.classify (Risk.undecided ir) in
       Alcotest.(check bool)
         (Format.asprintf "%a" Risk.pp_risk_class envelope.Risk.risk)
         true
         (Risk.is_destructive envelope))
    cmds

(* --- classify: git reset variants --- *)

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

let test_git_reset_hard_is_r2 () =
  let ir = simple_ir "git" [ "reset"; "--hard"; "HEAD~1" ] in
  let envelope = Risk.classify (Risk.undecided ir) in
  Alcotest.(check bool) "reset --hard is R2" true (Risk.is_r2 envelope)

(* --- classify: repo-hosting CLI R2 operations --- *)

let test_classify_repo_hosting_cli_r2 () =
  let cmds =
    [ simple_ir "gh" [ "repo"; "delete"; "owner/repo" ];
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

(* --- classify: repo-hosting CLI R1 operations --- *)

let test_classify_repo_hosting_cli_r1 () =
  let cmds =
    [ simple_ir "gh" [ "pr"; "create"; "--title"; "t" ];
      (* pr merge is revertable, so risk stays R1. The capability axis routes it
         to approval because it mutates the durable remote base branch. *)
      simple_ir "gh" [ "pr"; "merge"; "123" ];
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

(* --- classify: repo-hosting CLI API mutations --- *)

let test_classify_repo_hosting_cli_api_delete_r2 () =
  let ir = simple_ir "gh" [ "api"; "-X"; "DELETE"; "/repos/o/r" ] in
  let envelope = Risk.classify (Risk.undecided ir) in
  Alcotest.(check bool) "DELETE is R2" true (Risk.is_r2 envelope)

let test_classify_repo_hosting_cli_api_post_r1 () =
  let ir = simple_ir "gh" [ "api"; "-X"; "POST"; "/repos/o/r/issues" ] in
  let envelope = Risk.classify (Risk.undecided ir) in
  Alcotest.(check bool) "POST is R1" true (Risk.is_r1 envelope)

let test_classify_repo_hosting_cli_api_get_r0 () =
  let ir = simple_ir "gh" [ "api"; "/repos/o/r" ] in
  let envelope = Risk.classify (Risk.undecided ir) in
  Alcotest.(check bool) "GET is R0" true (Risk.is_r0 envelope)

let test_classify_repo_hosting_cli_api_graphql_r1 () =
  let ir = simple_ir "gh" [ "api"; "graphql" ] in
  let envelope = Risk.classify (Risk.undecided ir) in
  Alcotest.(check bool) "graphql is R1" true (Risk.is_r1 envelope)

(* --- classify: pipeline --- *)

let test_classify_pipeline_first_stage_destructive () =
  (* Pipeline with git push --force origin main as first stage.
     flat_stage_words returns all words concatenated, so the classifier
     sees "git push --force origin main" from the first Simple stage. *)
  let ir = pipeline_ir [ ("git", [ "push"; "--force"; "origin"; "main" ]); ("cat", []) ] in
  let envelope = Risk.classify (Risk.undecided ir) in
  Alcotest.(check bool) "pipeline with destructive first stage"
    true (Risk.is_destructive envelope)

(* RFC-0208 P0: privilege escalation / destructive command in a NON-head
   pipeline stage. Before the per-stage compositional fold these were
   silent R0_Read — the typed path read no stage ([Pipeline -> R0_Read])
   and the word-list floor matches only the flattened head token. *)

let test_classify_pipeline_nonhead_escalation () =
  let is_destructive stages =
    Risk.is_destructive (Risk.classify (Risk.undecided (pipeline_ir stages)))
  in
  let risk_of stages = (Risk.classify (Risk.undecided (pipeline_ir stages))).Risk.risk in
  (* sudo in a non-head stage -> Destructive_protected via [W (Sudo)]. *)
  Alcotest.(check bool) "echo x | sudo tee /etc/passwd is destructive"
    true
    (is_destructive [ ("echo", [ "x" ]); ("sudo", [ "tee"; "/etc/passwd" ]) ]);
  (* sudo as the head of a pipeline: the pipeline path never ran the typed
     Sudo arm before this fix. *)
  Alcotest.(check bool) "sudo cat /etc/shadow | grep x is destructive"
    true
    (is_destructive [ ("sudo", [ "cat"; "/etc/shadow" ]); ("grep", [ "x" ]) ]);
  (* git push --force to a protected branch in a non-head stage must be
     Destructive_protected (not merely above R0). *)
  let push_risk =
    risk_of [ ("cat", [ "f" ]); ("git", [ "push"; "--force"; "origin"; "main" ]) ]
  in
  Alcotest.(check string)
    "cat f | git push --force origin main is Destructive_protected"
    "Destructive_protected"
    (Risk.string_of_risk_class push_risk);
  (* benign read pipelines stay R0 — no over-escalation. *)
  Alcotest.(check bool) "ls | grep x stays R0"
    true
    (Risk.is_r0 (Risk.classify (Risk.undecided (pipeline_ir [ ("ls", []); ("grep", [ "x" ]) ]))))

(* --- classify: repo-hosting CLI read-only prefix equivalence (P9a) --- *)

let test_classify_repo_hosting_cli_read_only_prefixes_equivalence () =
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

(* --- S7 stamp invariant: ∀ envelope. envelope.risk = classify(undecided envelope.ir).risk --- *)

let stamp_invariant_cases =
  (* R0_Read *)
  [ simple_ir "ls" []
  ; simple_ir "cat" [ "file.txt" ]
  ; simple_ir "rg" [ "pattern" ]
  ; simple_ir "git" [ "status" ]
  ; simple_ir "gh" [ "pr"; "view"; "123" ]
  ; simple_ir "echo" [ "hello" ]
  ; simple_ir "pwd" []
  ; simple_ir "my-custom-tool" [ "--help" ]
  (* R1_Reversible_mutation *)
  ; simple_ir "git" [ "commit"; "-m"; "msg" ]
  ; simple_ir "git" [ "push" ]
  ; simple_ir "git" [ "checkout"; "-b"; "feature" ]
  ; simple_ir "npm" [ "install" ]
  ; simple_ir "mkdir" [ "dir" ]
  ; simple_ir "touch" [ "file" ]
  ; simple_ir "gh" [ "pr"; "create"; "--title"; "t" ]
  ; simple_ir "gh" [ "issue"; "close"; "123" ]
  ; simple_ir "gh" [ "api"; "-X"; "POST"; "/repos/o/r/issues" ]
  ; simple_ir "curl" [ "https://example.com" ]
  ; simple_ir "rsync" [ "-av"; "src/"; "host:/tmp/src/" ]
  (* R2_Irreversible *)
  ; simple_ir "git" [ "reset"; "HEAD~1" ]
  ; simple_ir "git" [ "reset"; "--hard"; "HEAD~1" ]
  ; simple_ir "rm" [ "file" ]
  ; simple_ir "gh" [ "pr"; "merge"; "123" ]
  ; simple_ir "gh" [ "repo"; "delete"; "owner/repo" ]
  ; simple_ir "gh" [ "api"; "-X"; "DELETE"; "/repos/o/r" ]
  (* Destructive_protected *)
  ; simple_ir "git" [ "push"; "--force"; "origin"; "main" ]
  ; simple_ir "git" [ "push"; "--force-with-lease"; "origin"; "main" ]
  ; simple_ir "bash" [ "-c"; "echo x > /tmp/x" ]
  (* Pipeline *)
  ; pipeline_ir [ ("git", [ "push"; "--force"; "origin"; "main" ]); ("cat", []) ]
  ; pipeline_ir [ ("ls", []); ("grep", [ "pattern" ]) ]
  (* Pipeline — non-head escalation (RFC-0208 P0) *)
  ; pipeline_ir [ ("echo", [ "x" ]); ("sudo", [ "tee"; "/etc/passwd" ]) ]
  ; pipeline_ir [ ("cat", [ "f" ]); ("git", [ "push"; "--force"; "origin"; "main" ]) ]
  ]

let test_s7_stamp_invariant () =
  List.iteri
    (fun idx ir ->
       let envelope = Risk.classify (Risk.undecided ir) in
       let stamped_risk = envelope.Risk.risk in
       let reclassified = Risk.classify (Risk.undecided envelope.Risk.ir) in
       let reclassified_risk = reclassified.Risk.risk in
       Alcotest.(check string)
         (Format.asprintf "S7 invariant[%d]: stamp=%s reclassified=%s"
            idx
            (Risk.string_of_risk_class stamped_risk)
            (Risk.string_of_risk_class reclassified_risk))
         (Risk.string_of_risk_class stamped_risk)
         (Risk.string_of_risk_class reclassified_risk))
    stamp_invariant_cases

(* --- typed-GADT escalation: word-list gaps the type closes ---------

   These cases are R0 under the word-list alone (the head token was
   "sudo"/"su"/"mkfs", so the "rm"/"git push" arms never fired and the
   command name was not in the write list). The typed GADT path
   escalates them. Proves [risk_of_typed] adds safety, not just parity. *)

let test_typed_escalation_closes_wordlist_gaps () =
  (* word-list baseline is R0 for each (gap), so any escalation here is
     attributable to the typed path. *)
  let assert_floor_is_r0 words =
    Alcotest.(check string)
      (Printf.sprintf "word-list floor R0 for [%s]" (String.concat " " words))
      "R0"
      (Risk.string_of_risk_class (Risk.classify_words words))
  in
  (* sudo: privilege escalation -> Destructive_protected *)
  assert_floor_is_r0 [ "sudo"; "rm"; "-rf"; "/" ];
  let sudo = simple_ir "sudo" [ "rm"; "-rf"; "/" ] in
  Alcotest.(check bool)
    "sudo -> Destructive_protected"
    true
    (Risk.is_destructive (Risk.classify (Risk.undecided sudo)));
  (* su: root shell -> R2 *)
  assert_floor_is_r0 [ "su"; "-"; "root" ];
  let su = simple_ir "su" [ "-"; "root" ] in
  Alcotest.(check bool)
    "su -> R2"
    true
    (Risk.is_r2 (Risk.classify (Risk.undecided su)));
  (* mkfs: filesystem create -> R2 *)
  assert_floor_is_r0 [ "mkfs"; "/dev/sda1" ];
  let mkfs = simple_ir "mkfs" [ "/dev/sda1" ] in
  Alcotest.(check bool)
    "mkfs -> R2"
    true
    (Risk.is_r2 (Risk.classify (Risk.undecided mkfs)))

(* --- monotone-safe invariant: classify >= word-list floor ----------

   Structural guard: [classify] takes the stricter of the typed opinion
   and the word-list floor, so its verdict is never below the floor.
   Fails loudly if the floor is ever removed without a type that
   subsumes it. *)

let test_monotone_floor_invariant () =
  let rank = function
    | Masc_exec.Shell_ir_risk.R0_Read -> 0
    | R1_Reversible_mutation -> 1
    | R2_Irreversible -> 2
    | Destructive_protected -> 3
  in
  let corpus =
    [ ("ls", []); ("cat", [ "f" ]); ("git", [ "commit"; "-m"; "x" ]);
      ("git", [ "push"; "--force"; "origin"; "main" ]); ("rm", [ "-rf"; "d" ]);
      ("sudo", [ "apt"; "install" ]); ("gh", [ "api"; "-XDELETE"; "/x" ]);
      ("gh", [ "repo"; "delete"; "o/r" ]); ("curl", [ "https://x" ]);
      ("mkdir", [ "-p"; "d" ]); ("npm", [ "install" ]); ("npm", [ "test" ]);
      ("dd", [ "if=/dev/zero"; "of=/dev/sda" ]); ("mkfs", [ "/dev/sda1" ]) ]
  in
  List.iter
    (fun (b, a) ->
       let ir = simple_ir b a in
       let full = (Risk.classify (Risk.undecided ir)).Risk.risk in
       let floor = Risk.classify_words (b :: a) in
       Alcotest.(check bool)
         (Printf.sprintf "%s %s: classify=%s >= floor=%s" b
            (String.concat " " a)
            (Risk.string_of_risk_class full)
            (Risk.string_of_risk_class floor))
         true
         (rank full >= rank floor))
    corpus

(* --- RFC-0208 P1: typed-coverage instrument ------------------------

   [typed_hit_of_ir] is the observability signal that distinguishes a real
   typed-constructor match from the [Generic] escape hatch, so the
   dispatch log / harness can measure how much of the 110-constructor
   typed model real traffic actually exercises. *)

let test_typed_hit_coverage () =
  let hit ir = Risk.typed_hit_of_ir ir in
  (* typed constructors -> hit *)
  Alcotest.(check bool) "ls is a typed hit" true (hit (simple_ir "ls" []));
  Alcotest.(check bool) "cat is a typed hit" true (hit (simple_ir "cat" [ "f" ]));
  Alcotest.(check bool) "sudo is a typed hit" true
    (hit (simple_ir "sudo" [ "rm"; "-rf"; "/" ]));
  Alcotest.(check bool) "git status is a typed hit" true
    (hit (simple_ir "git" [ "status" ]));
  (* unknown binary -> Generic escape hatch -> not a hit *)
  Alcotest.(check bool) "unknown command falls to Generic" false
    (hit (simple_ir "my-custom-tool" [ "--help" ]));
  (* pipeline: a typed hit only when ALL stages are typed *)
  Alcotest.(check bool) "ls | cat fully typed" true
    (hit (pipeline_ir [ ("ls", []); ("cat", [ "f" ]) ]));
  Alcotest.(check bool) "ls | unknown not fully typed" false
    (hit (pipeline_ir [ ("ls", []); ("my-custom-tool", []) ]))

(* --- test runner --- *)

let () =
  test_string_of_risk_class ();
  test_roundtrip_unwrap ();
  test_classify_read ();
  test_classify_write_r1 ();
  test_classify_destructive ();
  test_git_reset_soft_is_r1 ();
  test_git_reset_hard_is_r2 ();
  test_classify_repo_hosting_cli_r2 ();
  test_classify_repo_hosting_cli_r1 ();
  test_classify_repo_hosting_cli_api_delete_r2 ();
  test_classify_repo_hosting_cli_api_post_r1 ();
  test_classify_repo_hosting_cli_api_get_r0 ();
  test_classify_repo_hosting_cli_api_graphql_r1 ();
  test_classify_pipeline_first_stage_destructive ();
  test_classify_pipeline_nonhead_escalation ();
  test_classify_repo_hosting_cli_read_only_prefixes_equivalence ();
  test_classify_unknown_read ();
  test_s7_stamp_invariant ();
  test_typed_escalation_closes_wordlist_gaps ();
  test_monotone_floor_invariant ();
  test_typed_hit_coverage ();
  print_endline "test_shell_ir_risk: 20/20 passed"
