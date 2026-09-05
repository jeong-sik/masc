(* Closed-set tests for the observation-only gate fast-path. The argv tables
   are the whole safety surface, so every table entry and every guard is
   asserted — a table added without a test here should feel unfinished. *)

open Alcotest
open Masc

module Readonly = Keeper_gate_readonly

(* The wire envelope still carries sandbox labels — producers emit them for
   display/audit. The classification must never read them: the typed
   [sandbox_profile] on the request is the only sandbox input. The
   [?profile]/[?target] labels exist so tests can pin that indifference by
   emitting contradictory labels. *)
let gate_input ?(profile = "docker") ?(target = "docker:masc-keeper-sandbox:local") argv =
  `Assoc
    [ "schema", `String "masc.keeper_gate.request.v1"
    ; "input", `Assoc [ "cwd", `String "/home/keeper/playground"; "argv", `List (List.map (fun s -> `String s) argv) ]
    ; "cwd", `String "/home/keeper/playground"
    ; "sandbox_profile", `String profile
    ; "sandbox_target", `String target
    ]
;;

let script_gate_input ?(profile = "docker") ?(target = "docker:masc-keeper-sandbox:local") script =
  `Assoc
    [ "schema", `String "masc.keeper_gate.request.v1"
    ; "input", `Assoc [ "cwd", `String "/home/keeper/playground"; "script", `String script ]
    ; "cwd", `String "/home/keeper/playground"
    ; "sandbox_profile", `String profile
    ; "sandbox_target", `String target
    ]
;;

let passes label argv = check bool label true (Readonly.classify_argv argv)
let blocked label argv = check bool label false (Readonly.classify_argv argv)

let test_observation_table_is_fully_read () =
  passes "ls" [ "ls"; "-la" ];
  passes "cat" [ "cat"; "notes.txt" ];
  passes "head" [ "head"; "-n"; "5"; "f" ];
  passes "tail" [ "tail"; "-f"; "log" ];
  passes "wc" [ "wc"; "-l"; "f" ];
  passes "echo" [ "echo"; "hello"; "world" ];
  passes "printf" [ "printf"; "%s"; "x" ];
  passes "git status through -C" [ "git"; "-C"; "repos/masc"; "status"; "--short"; "--branch" ];
  passes "git log" [ "git"; "log"; "--oneline"; "-5" ];
  passes "git diff with global -c" [ "git"; "-c"; "core.pager=cat"; "diff" ];
  passes "git branch listing" [ "git"; "branch"; "-a" ];
  passes "git rev-list count against upstream"
    [ "git"; "-C"; "clone-probe"; "rev-list"; "--count"; "HEAD..origin/main" ];
  passes "git merge-base" [ "git"; "merge-base"; "origin/main"; "HEAD" ];
  passes "git cherry" [ "git"; "cherry"; "-v"; "origin/main" ];
  passes "git tag bare list" [ "git"; "tag" ];
  passes "git remote -v" [ "git"; "remote"; "-v" ];
  passes "git ls-tree recursive" [ "git"; "ls-tree"; "-r"; "origin/main"; "--name-only" ];
  passes "git ls-tree through -C" [ "git"; "-C"; "masc"; "ls-tree"; "HEAD" ];
  passes "rg plain" [ "rg"; "-n"; "pattern"; "." ];
  passes "rg --pretty stays allowed" [ "rg"; "--pretty"; "x" ];
  passes "grep" [ "grep"; "-r"; "x"; "." ];
  passes "find read" [ "find"; "."; "-name"; "*.ml" ];
  passes "sed filter" [ "sed"; "-n"; "1,5p"; "f" ];
  passes "sort read" [ "sort"; "-u"; "f" ];
  passes "uniq one operand" [ "uniq"; "f" ];
  passes "date read" [ "date"; "-u" ];
  passes "hostname flag" [ "hostname"; "-f" ];
  passes "env bare" [ "env" ];
  passes "printenv bare" [ "printenv" ];
  List.iter (fun command -> passes ("table entry " ^ command) [ command ]) Readonly.observation_commands;
  List.iter
    (fun sub -> passes ("git table entry " ^ sub) [ "git"; sub ])
    Readonly.git_read_subcommands
;;

(* gh reads the same endpoints git ls-remote already reaches, with the same
   identity. What the judge decides is whether an effect lands; a listed verb
   lands none. Every verb that does — merge, create, comment, checkout, clone,
   auth login — is absent from the table and therefore judged. *)
let test_gh_read_verbs_pass () =
  passes "pr list" [ "gh"; "pr"; "list" ];
  passes "pr view with json" [ "gh"; "pr"; "view"; "32891"; "--json"; "state,title" ];
  passes "pr checks" [ "gh"; "pr"; "checks"; "32891" ];
  passes "pr diff" [ "gh"; "pr"; "diff"; "32891" ];
  passes "issue view in another repo" [ "gh"; "issue"; "view"; "-R"; "jeong-sik/masc"; "1" ];
  passes "run list" [ "gh"; "run"; "list"; "--limit"; "5" ];
  passes "search prs" [ "gh"; "search"; "prs"; "--state"; "open" ];
  passes "auth status" [ "gh"; "auth"; "status" ];
  passes "api get" [ "gh"; "api"; "repos/jeong-sik/masc" ];
  passes "api with an explicit jq" [ "gh"; "api"; "user"; "--jq"; ".login" ]

let test_gh_write_shapes_stay_blocked () =
  blocked "pr merge" [ "gh"; "pr"; "merge"; "32891"; "--squash" ];
  blocked "pr create" [ "gh"; "pr"; "create"; "--title"; "x" ];
  blocked "pr comment" [ "gh"; "pr"; "comment"; "32891"; "--body"; "x" ];
  blocked "pr checkout writes the worktree" [ "gh"; "pr"; "checkout"; "32891" ];
  blocked "repo clone writes the worktree" [ "gh"; "repo"; "clone"; "jeong-sik/masc" ];
  blocked "auth login writes credentials" [ "gh"; "auth"; "login" ];
  blocked "an unlisted family" [ "gh"; "secret"; "list" ];
  blocked "an unlisted verb" [ "gh"; "pr"; "ready"; "32891" ];
  blocked "a bare family" [ "gh"; "pr" ];
  blocked "bare gh" [ "gh" ];
  (* --web opens a browser on the host, outside the guest. *)
  blocked "pr view --web" [ "gh"; "pr"; "view"; "1"; "--web" ];
  (* A field flag alone flips gh api to POST. *)
  blocked "api with a method" [ "gh"; "api"; "-X"; "POST"; "repos/x/y/issues" ];
  blocked "api with --method=" [ "gh"; "api"; "--method=DELETE"; "x" ];
  blocked "api with a field" [ "gh"; "api"; "repos/x/y/issues"; "-f"; "title=x" ];
  blocked "api with --field=" [ "gh"; "api"; "x"; "--field=a=b" ];
  blocked "api with an input file" [ "gh"; "api"; "x"; "--input"; "body.json" ];
  blocked "bare api" [ "gh"; "api" ]

let test_write_shapes_stay_blocked () =
  blocked "empty argv" [];
  blocked "empty command" [ "" ];
  blocked "absolute path argv0" [ "/bin/rm"; "-rf"; "/" ];
  blocked "rm" [ "rm"; "f" ];
  blocked "mkdir" [ "mkdir"; "d" ];
  blocked "tee" [ "tee"; "f" ];
  blocked "chmod" [ "chmod"; "+x"; "f" ];
  blocked "awk" [ "awk"; "1"; "f" ];
  blocked "env prefixing a command" [ "env"; "rm"; "f" ];
  blocked "find -delete" [ "find"; "."; "-delete" ];
  blocked "find -exec" [ "find"; "."; "-exec"; "rm"; "{}"; ";" ];
  blocked "find -ok" [ "find"; "."; "-ok"; "rm"; "{}"; ";" ];
  blocked "find -fprint" [ "find"; "."; "-fprint"; "out" ];
  blocked "find -fls" [ "find"; "."; "-fls"; "out" ];
  blocked "sed in-place" [ "sed"; "-i"; "s/a/b/"; "f" ];
  blocked "sed in-place backup suffix" [ "sed"; "-i.bak"; "s/a/b/"; "f" ];
  blocked "sed --in-place" [ "sed"; "--in-place"; "s/a/b/"; "f" ];
  blocked "sort -o writes" [ "sort"; "-o"; "out"; "f" ];
  blocked "sort --output= writes" [ "sort"; "--output=out"; "f" ];
  blocked "diff -o writes" [ "diff"; "-o"; "out"; "a"; "b" ];
  blocked "rg --pre executes" [ "rg"; "--pre"; "cat"; "x" ];
  blocked "rg --pre-glob executes" [ "rg"; "--pre-glob"; "*.z"; "x" ];
  blocked "date sets clock" [ "date"; "-s"; "2026-01-01" ];
  blocked "date --set sets clock" [ "date"; "--set=2026-01-01" ];
  blocked "hostname sets name" [ "hostname"; "evil.example" ];
  blocked "uniq second operand writes" [ "uniq"; "a"; "b" ];
  blocked "git push" [ "git"; "push"; "origin"; "main" ];
  blocked "git config writes" [ "git"; "config"; "user.name"; "x" ];
  blocked "git checkout mutates" [ "git"; "checkout"; "-b"; "feature" ];
  blocked "git reset" [ "git"; "reset"; "--hard" ];
  blocked "git clean" [ "git"; "clean"; "-fd" ];
  blocked "git branch create" [ "git"; "branch"; "feature" ];
  blocked "git branch delete" [ "git"; "branch"; "-D"; "feature" ];
  blocked "git tag create" [ "git"; "tag"; "v1.0.0" ];
  blocked "git remote add" [ "git"; "remote"; "add"; "origin"; "x" ];
  blocked "git remote remove" [ "git"; "remote"; "remove"; "origin" ];
  blocked "git with no subcommand" [ "git" ]
;;


let executes ~operation ~sandbox_profile argv =
  Readonly.observation_only_request ~operation ~sandbox_profile ~input:(gate_input argv)
;;

let executes_script ~operation ~sandbox_profile script =
  Readonly.observation_only_request
    ~operation
    ~sandbox_profile
    ~input:(script_gate_input script)
;;

let script_gate_request ?profile ?target ~sandbox_profile base_path script =
  { Keeper_gate.keeper_name = "alpha"
  ; operation = "tool_execute"
  ; call_summary = None
  ; input = script_gate_input ?profile ?target script
  ; base_path
  ; sandbox_profile
  ; causal_context = None
  ; task_id = None
  ; continuation_channel = None
  }
;;


let docker = Some Keeper_types_profile_sandbox.Docker
let microvm = Some Keeper_types_profile_sandbox.Micro_vm
let remote_ssh = Some Keeper_types_profile_sandbox.Remote_ssh

let network_input ~capability =
  `Assoc
    [ "capability", `String capability
    ; "input", `Assoc [ "query", `String "ocaml eio"; "limit", `Int 3 ]
    ]
;;

let test_network_observation_capabilities () =
  check bool
    "web_search reads without judgment"
    true
    (Readonly.observation_only_request
       ~operation:"network_read"
       ~sandbox_profile:None
       ~input:(network_input ~capability:"web_search"));
  check bool
    "web_fetch reads without judgment (address boundary is the fetch's own)"
    true
    (Readonly.observation_only_request
       ~operation:"network_read"
       ~sandbox_profile:None
       ~input:(network_input ~capability:"web_fetch"));
  check bool
    "unknown capability never matches"
    false
    (Readonly.observation_only_request
       ~operation:"network_read"
       ~sandbox_profile:None
       ~input:(network_input ~capability:"port_scan"));
  check bool
    "missing capability never matches"
    false
    (Readonly.observation_only_request
       ~operation:"network_read"
       ~sandbox_profile:None
       ~input:(`Assoc [ "input", `Assoc [ "query", `String "x" ] ]));
  check bool
    "network arm ignores tool_execute shapes"
    false
    (Readonly.observation_only_request
       ~operation:"network_read"
       ~sandbox_profile:None
       ~input:(gate_input [ "ls" ]));
  check
    (Alcotest.list Alcotest.string)
    "observation network set is closed at web_search and web_fetch"
    [ "web_search"; "web_fetch" ]
    Readonly.observation_network_capabilities
;;

let test_gate_shape_gates () =
  check bool "tool_execute ls under Docker" true (executes ~operation:"tool_execute" ~sandbox_profile:docker [ "ls" ]);
  check bool
    "tool_execute ls under Micro_vm (the profile the fleet runs)"
    true
    (executes ~operation:"tool_execute" ~sandbox_profile:microvm [ "ls"; "-la" ]);
  check bool
    "Remote_ssh stays with the judge (transport-only, inherited network)"
    false
    (executes ~operation:"tool_execute" ~sandbox_profile:remote_ssh [ "ls" ]);
  check bool
    "no typed profile never matches"
    false
    (executes ~operation:"tool_execute" ~sandbox_profile:None [ "ls" ]);
  check bool
    "wire labels are not consulted: typed Micro_vm with nonsense labels still passes"
    true
    (Readonly.observation_only_request
       ~operation:"tool_execute"
       ~sandbox_profile:microvm
       ~input:(gate_input ~profile:"local" ~target:"local" [ "ls" ]));
  check bool
    "wire labels are not consulted: microvm labels without a typed profile never match"
    false
    (Readonly.observation_only_request
       ~operation:"tool_execute"
       ~sandbox_profile:None
       ~input:(gate_input ~profile:"microvm" ~target:"microvm:masc-keeper-sandbox:local" [ "ls" ]));
  check bool
    "non-tool_execute never matches"
    false
    (Readonly.observation_only_request ~operation:"slack_post" ~sandbox_profile:docker ~input:(gate_input [ "ls" ]));
  check bool
    "missing argv never matches"
    false
    (Readonly.observation_only_request
       ~operation:"tool_execute"
       ~sandbox_profile:docker
       ~input:(`Assoc [ "input", `Assoc [] ]));
  check bool
    "non-string argv entry never matches"
    false
    (Readonly.observation_only_request
       ~operation:"tool_execute"
       ~sandbox_profile:docker
       ~input:(`Assoc [ "input", `Assoc [ "argv", `List [ `String "ls"; `Int 3 ] ] ]))
;;

(* ── Gate-path integration: the fast-path must allow without deferring,
      leave write commands to the judge, and leave Manual mode untouched. ── *)

let temp_dir prefix =
  let path = Filename.temp_file prefix "" in
  Unix.unlink path;
  Unix.mkdir path 0o755;
  path
;;

let rec remove_tree path =
  if Sys.file_exists path
  then
    if Sys.is_directory path
    then (
      Sys.readdir path
      |> Array.iter (fun name -> remove_tree (Filename.concat path name));
      Unix.rmdir path)
    else Unix.unlink path
;;

let gate_request ?profile ?target ~sandbox_profile base_path argv =
  { Keeper_gate.keeper_name = "alpha"
  ; operation = "tool_execute"
  ; call_summary = None
  ; input = gate_input ?profile ?target argv
  ; base_path
  ; sandbox_profile
  ; causal_context = None
  ; task_id = None
  ; continuation_channel = None
  }
;;


let network_gate_request base_path ~capability =
  { Keeper_gate.keeper_name = "alpha"
  ; operation = "network_read"
  ; call_summary = None
  ; input =
      `Assoc
        [ "capability", `String capability
        ; "input", `Assoc [ "url", `String "https://example.com/page" ]
        ]
  ; base_path
  ; sandbox_profile = None
  ; causal_context = None
  ; task_id = None
  ; continuation_channel = None
  }
;;

let select_workspace config mode =
  match Keeper_gate_mode.set config ~actor:"test" mode with
  | Ok _ -> ()
  | Error error -> fail ("failed to select workspace Gate mode: " ^ error)
;;

let with_auto_judge f =
  let base_path = temp_dir "keeper-gate-readonly" in
  Fun.protect
    ~finally:(fun () ->
      Keeper_approval_queue.For_testing.reset_runtime_state ();
      remove_tree base_path)
    @@ fun () ->
  (match Keeper_approval_queue.install_persistence ~base_path with
   | Ok _ -> ()
   | Error error -> fail ("failed to install approval queue persistence: " ^ Keeper_approval_queue.install_error_to_string error));
  let config = Workspace.default_config base_path in
  select_workspace config Keeper_gate_mode.Auto_judge;
  f base_path
;;

(* ── script classification through the shell IR (RFC-0421) ─────────── *)

let observation label script =
  check bool (label ^ " is observation") true (Readonly.classify_script script)
;;

let judged label script =
  check bool (label ^ " keeps the judge") false (Readonly.classify_script script)
;;

let test_script_classification_unit () =
  (* Every command the IR shows is judged by the argv tables. *)
  observation "bare ls" "ls";
  observation "ls with flags" "ls -la /tmp";
  observation "git status through -C" "git -C repos/masc status";
  observation "repeated spaces" "uname  -a";
  observation "a tab is a word boundary, like the shell reads it" "ls\t-la";
  observation "quoted argument" "grep 'x y' f";
  observation "double-quoted argument" "grep -n \"a b\" notes.txt";
  observation "pipeline of reads" "git show HEAD:f | sed -n '10,20p'";
  observation "pipeline with head" "ls repos | head -5";
  observation "cd before observing" "cd repos/masc && git log --oneline -3";
  observation "sequence of reads" "pwd; ls -la; echo ---";
  observation "newline-separated reads" "cat a\ncat b";
  observation "or-connector of reads" "ls /masc-work || echo none";
  observation "stderr joined to stdout" "ls x 2>&1 | head";
  observation "stderr discarded" "ls repos/_build 2>/dev/null | head -5";
  observation "stdin from a file" "wc -l < f";
  observation "tilde is a path the read resolves" "cat ~/notes";
  (* The tab cases RFC-0404 refused by character: the parser splits the
     flag out, so the guards see it. *)
  judged "tab splits the sed in-place flag out" "sed -e\t-i s/a/b/ f";
  judged "tab splits the rg preprocessor flag out" "rg --pre\trm x";
  judged "tab splits the sort output flag out" "sort -o\tout f";
  judged "tab splits the uniq second operand out" "uniq -c\ta b";
  (* Where the argv depends on the guest at run time. *)
  judged "glob" "ls *.ml";
  judged "bracket glob" "ls [a-z]*";
  judged "brace expansion" "cat {a,b}";
  judged "variable" "echo $HOME";
  judged "command substitution" "echo $(whoami)";
  judged "backtick" "echo `whoami`";
  judged "subshell" "(ls)";
  judged "environment prefix" "PAGER=cat git log";
  (* Effects, wherever they sit on the line. *)
  judged "write redirect" "cat f > out";
  judged "append redirect" "cat f >> out";
  judged "a write after a read" "ls; rm -rf /";
  judged "a write inside a pipeline" "cat f | tee out";
  judged "fetch behind cd" "cd repos/masc && git fetch origin main";
  judged "export then read" "export X=1; ls";
  judged "a command outside the table" "curl https://example.com";
  judged "a shell inside the script" "bash -c ls";
  judged "whitespace only" "   ";
  judged "empty" ""
;;

let test_observation_scripts_pass_the_table () =
  check bool
    "observation script under Docker reads without judgment"
    true
    (executes_script ~operation:"tool_execute" ~sandbox_profile:docker "ls -la /home/keeper");
  check bool
    "git status script under microvm reads without judgment"
    true
    (executes_script ~operation:"tool_execute" ~sandbox_profile:microvm "git -C repos/masc status");
  check bool
    "same script under remote_ssh still faces the judge"
    false
    (executes_script ~operation:"tool_execute" ~sandbox_profile:remote_ssh "ls -la");
  check bool
    "compound script still faces the judge"
    false
    (executes_script ~operation:"tool_execute" ~sandbox_profile:docker "uname -a && id && pwd");
  check bool
    "command outside the table still faces the judge"
    false
    (executes_script ~operation:"tool_execute" ~sandbox_profile:docker "curl https://example.com");
  check bool
    "quoted observation reads without judgment"
    true
    (executes_script ~operation:"tool_execute" ~sandbox_profile:docker "grep 'pattern' notes.txt");
  check bool
    "argv costume of an observation reads without judgment"
    true
    (executes ~operation:"tool_execute" ~sandbox_profile:microvm [ "bash"; "-lc"; "ls -la repos" ]);
  check bool
    "argv costume of a write still faces the judge"
    false
    (executes ~operation:"tool_execute" ~sandbox_profile:microvm [ "bash"; "-c"; "ls && rm -rf repos" ]);
  check bool
    "pipeline script under remote_ssh still faces the judge"
    false
    (executes_script ~operation:"tool_execute" ~sandbox_profile:remote_ssh "cd repos && git log | head");
  check bool
    "empty script never matches"
    false
    (executes_script ~operation:"tool_execute" ~sandbox_profile:docker "  ")
;;

let test_auto_judge_allows_script_observation_without_queueing () =
  with_auto_judge @@ fun base_path ->
  match
    Keeper_gate.decide
      ~keeper_always_allow:false
      (script_gate_request ~sandbox_profile:docker base_path "ls -la /home/keeper/playground")
  with
  | Keeper_gate.Allow { source = Readonly_sandbox; _ } -> ()
  | Keeper_gate.Allow { source; _ } ->
    failf "script observation allowed through the wrong source: %s"
      (Keeper_gate.authorization_source_to_string source)
  | Keeper_gate.Deferred { reason; _ } ->
    failf "script observation was deferred instead of fast-pathed: %s"
      (match reason with
       | Keeper_gate.Human_requested -> "human_requested"
       | Keeper_gate.Judge_requested -> "judge_requested"
       | Keeper_gate.Auto_judge_unavailable detail -> "auto_judge_unavailable: " ^ detail
       | Keeper_gate.Mode_state_invalid detail -> "mode_state_invalid: " ^ detail)
  | Keeper_gate.Unavailable _ -> fail "script observation made the queue unavailable"
;;

let test_auto_judge_allows_observation_without_queueing () =
  with_auto_judge @@ fun base_path ->
  match
    Keeper_gate.decide
      ~keeper_always_allow:false
      (gate_request ~sandbox_profile:docker base_path [ "ls"; "-la" ])
  with
  | Keeper_gate.Allow { source = Readonly_sandbox; _ } -> ()
  | Keeper_gate.Allow { source; _ } ->
    failf "observation request allowed through the wrong source: %s"
      (Keeper_gate.authorization_source_to_string source)
  | Keeper_gate.Deferred { reason; _ } ->
    failf "observation request was deferred instead of fast-pathed: %s"
      (match reason with
       | Keeper_gate.Human_requested -> "human_requested"
       | Keeper_gate.Judge_requested -> "judge_requested"
       | Keeper_gate.Auto_judge_unavailable detail -> "auto_judge_unavailable: " ^ detail
       | Keeper_gate.Mode_state_invalid detail -> "mode_state_invalid: " ^ detail)
  | Keeper_gate.Unavailable _ -> fail "observation request made the queue unavailable"
;;

(* Same end-to-end allow for the profile the fleet actually runs: after the
   2026-09-02 switch all keepers dispatch under microvm, and this path must
   not fall through to the judge. The wire labels deliberately contradict the
   typed profile — the decision reads only the typed field. *)
let test_auto_judge_allows_microvm_observation_without_queueing () =
  with_auto_judge @@ fun base_path ->
  match
    Keeper_gate.decide
      ~keeper_always_allow:false
      (gate_request
         ~profile:"local"
         ~target:"local"
         ~sandbox_profile:microvm
         base_path
         [ "ls"; "-la" ])
  with
  | Keeper_gate.Allow { source = Readonly_sandbox; _ } -> ()
  | Keeper_gate.Allow { source; _ } ->
    failf "microvm observation request allowed through the wrong source: %s"
      (Keeper_gate.authorization_source_to_string source)
  | Keeper_gate.Deferred _ -> fail "microvm observation request was deferred instead of fast-pathed"
  | Keeper_gate.Unavailable _ -> fail "microvm observation request made the queue unavailable"
;;

(* Remote_ssh is transport-only and inherits the host network, so even an
   observation-shaped command stays with the judge end to end. *)
let test_auto_judge_defers_remote_ssh_observation_to_the_judge () =
  with_auto_judge @@ fun base_path ->
  match
    Keeper_gate.decide
      ~keeper_always_allow:false
      (gate_request ~sandbox_profile:remote_ssh base_path [ "ls"; "-la" ])
  with
  | Keeper_gate.Deferred { reason = Judge_requested; _ }
  | Keeper_gate.Deferred { reason = Auto_judge_unavailable _; _ } -> ()
  | Keeper_gate.Allow _ -> fail "a remote_ssh observation was allowed without judgment"
  | Keeper_gate.Deferred { reason = Human_requested; _ } ->
    fail "remote_ssh observation went to the human queue, not the judge lane"
  | Keeper_gate.Deferred { reason = Mode_state_invalid detail; _ } ->
    fail ("mode_state_invalid: " ^ detail)
  | Keeper_gate.Unavailable _ -> fail "remote_ssh observation made the queue unavailable"
;;

(* The whole gate path, not the classifier alone: a web_fetch under
   Auto Judge comes back allowed with the observation source, without a
   queue entry. Defined after [with_auto_judge], which it uses. *)
let test_auto_judge_allows_web_fetch_without_queueing () =
  with_auto_judge @@ fun base_path ->
  match
    Keeper_gate.decide
      ~keeper_always_allow:false
      (network_gate_request base_path ~capability:"web_fetch")
  with
  | Keeper_gate.Allow { source = Readonly_sandbox; _ } -> ()
  | Keeper_gate.Allow { source; _ } ->
    failf "web_fetch allowed through the wrong source: %s"
      (Keeper_gate.authorization_source_to_string source)
  | Keeper_gate.Deferred _ -> fail "web_fetch was deferred instead of fast-pathed"
  | Keeper_gate.Unavailable _ -> fail "web_fetch made the queue unavailable"
;;

let test_auto_judge_still_defers_writes_to_the_judge () =
  with_auto_judge @@ fun base_path ->
  match
    Keeper_gate.decide
      ~keeper_always_allow:false
      (gate_request ~sandbox_profile:docker base_path [ "rm"; "-rf"; "out" ])
  with
  (* A bare test process has no auto-judge worker installed, so the judge
     lane reports unavailable instead of queued — both mean the request was
     NOT allowed without judgment, which is the assertion. *)
  | Keeper_gate.Deferred { reason = Judge_requested; _ }
  | Keeper_gate.Deferred { reason = Auto_judge_unavailable _; _ } -> ()
  | Keeper_gate.Allow _ -> fail "a write command was allowed without judgment"
  | Keeper_gate.Deferred { reason = Human_requested; _ } ->
    fail "write command went to the human queue, not the judge lane"
  | Keeper_gate.Deferred { reason = Mode_state_invalid detail; _ } ->
    fail ("mode_state_invalid: " ^ detail)
  | Keeper_gate.Unavailable _ -> fail "write command made the queue unavailable"
;;

let test_manual_mode_still_asks_the_human () =
  with_auto_judge @@ fun base_path ->
  let config = Workspace.default_config base_path in
  select_workspace config Keeper_gate_mode.Manual;
  match
    Keeper_gate.decide
      ~keeper_always_allow:false
      (gate_request ~sandbox_profile:docker base_path [ "ls" ])
  with
  | Keeper_gate.Deferred { reason = Human_requested; _ } -> ()
  | Keeper_gate.Allow _ -> fail "Manual mode must still see even observation requests"
  | Keeper_gate.Deferred _ -> fail "Manual mode deferred for a non-human reason"
  | Keeper_gate.Unavailable _ -> fail "Manual mode made the queue unavailable"
;;

let () =
  run "Keeper gate readonly"
    [ ( "argv classification"
      , [ test_case "observation table is fully read" `Quick test_observation_table_is_fully_read
        ; test_case "write shapes stay blocked" `Quick test_write_shapes_stay_blocked
        ; test_case "gh read verbs pass" `Quick test_gh_read_verbs_pass
        ; test_case "gh write shapes stay blocked" `Quick test_gh_write_shapes_stay_blocked
        ; test_case "gate shape gates" `Quick test_gate_shape_gates
        ; test_case
            "network observation capabilities"
            `Quick
            test_network_observation_capabilities
        ] )
    ; ( "script classification"
      , [ test_case "classification unit" `Quick test_script_classification_unit
        ; test_case
            "observation scripts pass the table"
            `Quick
            test_observation_scripts_pass_the_table
        ; test_case
            "auto_judge allows script observation without queueing"
            `Quick
            test_auto_judge_allows_script_observation_without_queueing
        ] )
    ; ( "gate path"
      , [ test_case
            "auto_judge allows observation without queueing"
            `Quick
            test_auto_judge_allows_observation_without_queueing
        ; test_case
            "auto_judge allows microvm observation without queueing"
            `Quick
            test_auto_judge_allows_microvm_observation_without_queueing
        ; test_case
            "auto_judge defers remote_ssh observation to the judge"
            `Quick
            test_auto_judge_defers_remote_ssh_observation_to_the_judge
        ; test_case
            "auto_judge allows web_fetch without queueing"
            `Quick
            test_auto_judge_allows_web_fetch_without_queueing
        ; test_case
            "auto_judge still defers writes to the judge"
            `Quick
            test_auto_judge_still_defers_writes_to_the_judge
        ; test_case "manual mode still asks the human" `Quick test_manual_mode_still_asks_the_human
        ] )
    ]
;;
