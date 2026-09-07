(* Feature-boundary tests for static observation and the existing boxed
   execution path. The retained command tables are covered as policy; they
   are not a complete proof of every command option or configuration. *)

open Alcotest
open Masc

module Readonly = Keeper_gate_readonly

let is_static = function
  | Readonly.Static_observation -> true
  | Readonly.Needs_observation _ -> false
;;

let observation_only_request ~operation ~sandbox_profile ~input =
  Readonly.classify_request ~operation ~sandbox_profile ~input |> is_static
;;

let classification =
  testable
    (fun formatter value ->
      Format.pp_print_string formatter
        (Yojson.Safe.to_string (Readonly.classification_to_yojson value)))
    ( = )
;;

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

let passes label argv = check bool label true (Readonly.classify_argv argv |> is_static)
let requires_observation label argv = check bool label false (Readonly.classify_argv argv |> is_static)

let test_observation_table_is_fully_read () =
  passes "ls" [ "ls"; "-la" ];
  passes "cat" [ "cat"; "notes.txt" ];
  passes "head" [ "head"; "-n"; "5"; "f" ];
  passes "tail" [ "tail"; "-f"; "log" ];
  passes "wc" [ "wc"; "-l"; "f" ];
  passes "echo" [ "echo"; "hello"; "world" ];
  passes "printf" [ "printf"; "%s"; "x" ];
  passes "git status through -C" [ "git"; "-C"; "repos/masc"; "status"; "--short"; "--branch" ];
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
  requires_observation "sed needs execution evidence (script can write/exec)"
    [ "sed"; "-n"; "1,5p"; "f" ];
  passes "sort read" [ "sort"; "-u"; "f" ];
  passes "uniq one operand" [ "uniq"; "f" ];
  passes "date read" [ "date"; "-u" ];
  passes "hostname flag" [ "hostname"; "-f" ];
  passes "env bare" [ "env" ];
  passes "printenv bare" [ "printenv" ];
  passes "true closes an or-line" [ "true" ];
  passes "base64 decode" [ "base64"; "-d"; "blob.b64" ];
  passes "jq filter" [ "jq"; "-r"; ".files[].path"; "pr.json" ];
  passes "id" [ "id"; "-un" ];
  passes "uptime" [ "uptime" ];
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

let test_gh_write_shapes_require_observation () =
  requires_observation "pr merge" [ "gh"; "pr"; "merge"; "32891"; "--squash" ];
  requires_observation "pr create" [ "gh"; "pr"; "create"; "--title"; "x" ];
  requires_observation "pr comment" [ "gh"; "pr"; "comment"; "32891"; "--body"; "x" ];
  requires_observation "pr checkout writes the worktree" [ "gh"; "pr"; "checkout"; "32891" ];
  requires_observation "repo clone writes the worktree" [ "gh"; "repo"; "clone"; "jeong-sik/masc" ];
  requires_observation "auth login writes credentials" [ "gh"; "auth"; "login" ];
  requires_observation "an unlisted family" [ "gh"; "secret"; "list" ];
  requires_observation "an unlisted verb" [ "gh"; "pr"; "ready"; "32891" ];
  requires_observation "a bare family" [ "gh"; "pr" ];
  requires_observation "bare gh" [ "gh" ];
  (* --web opens a browser on the host, outside the guest. *)
  requires_observation "pr view --web" [ "gh"; "pr"; "view"; "1"; "--web" ];
  (* A field flag alone flips gh api to POST. *)
  requires_observation "api with a method" [ "gh"; "api"; "-X"; "POST"; "repos/x/y/issues" ];
  requires_observation "api with --method=" [ "gh"; "api"; "--method=DELETE"; "x" ];
  requires_observation "api with a field" [ "gh"; "api"; "repos/x/y/issues"; "-f"; "title=x" ];
  requires_observation "api with --field=" [ "gh"; "api"; "x"; "--field=a=b" ];
  requires_observation "api with an input file" [ "gh"; "api"; "x"; "--input"; "body.json" ];
  requires_observation "bare api" [ "gh"; "api" ]

let test_write_shapes_require_observation () =
  requires_observation "empty argv" [];
  requires_observation "empty command" [ "" ];
  requires_observation "absolute path argv0" [ "/bin/rm"; "-rf"; "/" ];
  requires_observation "rm" [ "rm"; "f" ];
  requires_observation "mkdir" [ "mkdir"; "d" ];
  requires_observation "tee" [ "tee"; "f" ];
  requires_observation "chmod" [ "chmod"; "+x"; "f" ];
  requires_observation "awk" [ "awk"; "1"; "f" ];
  requires_observation "env prefixing a command" [ "env"; "rm"; "f" ];
  requires_observation "find -delete" [ "find"; "."; "-delete" ];
  requires_observation "find -exec" [ "find"; "."; "-exec"; "rm"; "{}"; ";" ];
  requires_observation "find -ok" [ "find"; "."; "-ok"; "rm"; "{}"; ";" ];
  requires_observation "find -fprint" [ "find"; "."; "-fprint"; "out" ];
  requires_observation "find -fls" [ "find"; "."; "-fls"; "out" ];
  requires_observation "sed in-place" [ "sed"; "-i"; "s/a/b/"; "f" ];
  requires_observation "sed in-place backup suffix" [ "sed"; "-i.bak"; "s/a/b/"; "f" ];
  requires_observation "sed --in-place" [ "sed"; "--in-place"; "s/a/b/"; "f" ];
  (* The write/exec verbs a flag denylist cannot see, which is why sed is not
     fast-pathed at all: [w] writes a file, [e] runs a shell -- neither is a
     flag, both without [-i]. *)
  requires_observation "sed script write verb" [ "sed"; "w /etc/passwd"; "f" ];
  requires_observation "sed script exec verb" [ "sed"; "s/a/b/e"; "f" ];
  requires_observation "sort -o writes" [ "sort"; "-o"; "out"; "f" ];
  requires_observation "sort --output= writes" [ "sort"; "--output=out"; "f" ];
  requires_observation "diff -o writes" [ "diff"; "-o"; "out"; "a"; "b" ];
  requires_observation "rg --pre executes" [ "rg"; "--pre"; "cat"; "x" ];
  requires_observation "rg --pre-glob executes" [ "rg"; "--pre-glob"; "*.z"; "x" ];
  requires_observation "date sets clock" [ "date"; "-s"; "2026-01-01" ];
  requires_observation "date --set sets clock" [ "date"; "--set=2026-01-01" ];
  requires_observation "hostname sets name" [ "hostname"; "evil.example" ];
  requires_observation "uniq second operand writes" [ "uniq"; "a"; "b" ];
  requires_observation "git push" [ "git"; "push"; "origin"; "main" ];
  requires_observation "git config writes" [ "git"; "config"; "user.name"; "x" ];
  requires_observation "git checkout mutates" [ "git"; "checkout"; "-b"; "feature" ];
  requires_observation "git reset" [ "git"; "reset"; "--hard" ];
  requires_observation "git clean" [ "git"; "clean"; "-fd" ];
  requires_observation "git branch create" [ "git"; "branch"; "feature" ];
  requires_observation "git branch delete" [ "git"; "branch"; "-D"; "feature" ];
  requires_observation "git tag create" [ "git"; "tag"; "v1.0.0" ];
  requires_observation "git remote add" [ "git"; "remote"; "add"; "origin"; "x" ];
  requires_observation "git remote remove" [ "git"; "remote"; "remove"; "origin" ];
  requires_observation "git with no subcommand" [ "git" ];
  (* Script-form inert prefixes are stripped; the argv form has no script
     to be equivalent to, so argv[0] stays unregistered. *)
  requires_observation "env assignment as argv form" [ "NO_COLOR=1"; "gh"; "pr"; "list" ];
  (* Read-only graphql queries ride a field flag, which flips the method
     to POST; the query text itself is never parsed for read-ness. *)
  requires_observation "graphql via field flag"
    [ "gh"; "api"; "graphql"; "-f"; "query={viewer{login}}" ]
;;


let executes ~operation ~sandbox_profile argv =
  observation_only_request ~operation ~sandbox_profile ~input:(gate_input argv)
;;

let executes_script ~operation ~sandbox_profile script =
  observation_only_request
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

let git_execution_cases =
  [ Readonly.Diff, [ "git"; "diff"; "--output=changes.patch" ]
  ; Readonly.Log, [ "git"; "log"; "--output=history.txt" ]
  ; Readonly.Show, [ "git"; "show"; "--output=commit.txt" ]
  ; Readonly.Grep, [ "git"; "grep"; "--open-files-in-pager=cat"; "needle" ]
  ; Readonly.Reflog, [ "git"; "reflog"; "delete"; "HEAD@{0}" ]
  ; Readonly.Reflog, [ "git"; "reflog"; "expire"; "--all" ]
  ; Readonly.Whatchanged, [ "git"; "whatchanged"; "--output=history.txt" ]
  ; Readonly.Blame, [ "git"; "blame"; "--textconv"; "notes.txt" ]
  ; Readonly.Annotate, [ "git"; "annotate"; "--textconv"; "notes.txt" ]
  ]
;;

let test_git_effects_require_execution_evidence () =
  List.iter
    (fun (command, argv) ->
      let expected = Readonly.Needs_observation (Git_command_requires_execution command) in
      check classification "output/helper/mutation options require execution"
        expected (Readonly.classify_argv argv);
      (* A repository can configure helpers even when the caller supplies no
         such option, so stripping the options must not restore static proof. *)
      match argv with
      | git :: subcommand :: _ ->
        check classification "plain command preserves configuration uncertainty"
          expected (Readonly.classify_argv [ git; subcommand ])
      | _ -> fail "invalid Git scenario fixture")
    git_execution_cases
;;

let test_git_global_configuration_uses_exact_syntax () =
  let override = Readonly.Needs_observation Readonly.Git_configuration_override in
  List.iter
    (fun argv ->
      check classification "global override requires execution" override
        (Readonly.classify_argv argv))
    [ [ "git"; "-c"; "core.fsmonitor=helper"; "status" ]
    ; [ "git"; "--no-pager"; "-C"; "repo"; "-c"; "core.pager=cat"; "rev-parse"; "HEAD" ]
    ; [ "git"; "--config-env=core.fsmonitor=MONITOR"; "status" ]
    ];
  check classification "log -c is the subcommand's combined-diff option"
    (Readonly.Needs_observation (Git_command_requires_execution Log))
    (Readonly.classify_argv [ "git"; "log"; "-c" ]);
  check classification "-C consumes a directory that happens to spell -c"
    Readonly.Static_observation
    (Readonly.classify_argv [ "git"; "-C"; "-c"; "rev-parse"; "HEAD" ]);
  List.iter
    (fun argv ->
      check classification "unknown spelling remains unproven"
        (Readonly.Needs_observation Unproven_request)
        (Readonly.classify_argv argv))
    [ [ "git"; "-ccore.pager=cat"; "status" ]
    ; [ "git"; "--config-env-extra=core.pager=VALUE"; "status" ]
    ; [ "git"; "-C" ]
    ];
  passes "Git words in another command's data are not Git syntax"
    [ "echo"; "git diff --output=out -c core.pager=helper" ]
;;

let test_git_reasons_survive_the_request_projection () =
  let diff = Readonly.Needs_observation (Git_command_requires_execution Diff) in
  let script = "pwd && git diff --output=changes.patch | head" in
  check classification "pipeline and sequence retain the Git reason"
    diff (Readonly.classify_script script);
  List.iter
    (fun input ->
      check classification "argv/script/shell costume retain the Git reason"
        diff (Readonly.classify_request ~operation:"tool_execute"
                ~sandbox_profile:microvm ~input))
    [ gate_input [ "git"; "diff"; "--output=changes.patch" ]
    ; script_gate_input script
    ; gate_input [ "sh"; "-c"; script ]
    ];
  check classification "unsupported profile does not erase the command reason"
    diff (Readonly.classify_request ~operation:"tool_execute"
            ~sandbox_profile:remote_ssh ~input:(script_gate_input script));
  check classification "configuration reason survives Shell IR"
    (Readonly.Needs_observation Git_configuration_override)
    (Readonly.classify_script "git -c core.fsmonitor=helper status && pwd");
  check classification "unknown first stage remains explicitly unproven"
    (Readonly.Needs_observation Unproven_request)
    (Readonly.classify_script "unknown-command && git diff")
;;

let test_git_classification_projection_contains_no_arguments () =
  let encoded argv =
    Readonly.classify_argv argv |> Readonly.classification_to_yojson
    |> Yojson.Safe.to_string
  in
  check string "configuration values are not copied to the reason"
    {|{"kind":"needs_observation","reason":{"kind":"git_configuration_override"}}|}
    (encoded [ "git"; "-c"; "http.extraHeader=Authorization: secret"; "status" ]);
  check string "command reason contains only the typed name"
    {|{"kind":"needs_observation","reason":{"kind":"git_command_requires_execution","command":"diff"}}|}
    (encoded [ "git"; "diff"; "--output=private-path.patch" ])
;;

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
    (observation_only_request
       ~operation:"network_read"
       ~sandbox_profile:None
       ~input:(network_input ~capability:"web_search"));
  check bool
    "web_fetch reads without judgment (address boundary is the fetch's own)"
    true
    (observation_only_request
       ~operation:"network_read"
       ~sandbox_profile:None
       ~input:(network_input ~capability:"web_fetch"));
  check bool
    "unknown capability never matches"
    false
    (observation_only_request
       ~operation:"network_read"
       ~sandbox_profile:None
       ~input:(network_input ~capability:"port_scan"));
  check bool
    "missing capability never matches"
    false
    (observation_only_request
       ~operation:"network_read"
       ~sandbox_profile:None
       ~input:(`Assoc [ "input", `Assoc [ "query", `String "x" ] ]));
  check bool
    "network arm ignores tool_execute shapes"
    false
    (observation_only_request
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
    (observation_only_request
       ~operation:"tool_execute"
       ~sandbox_profile:microvm
       ~input:(gate_input ~profile:"local" ~target:"local" [ "ls" ]));
  check bool
    "wire labels are not consulted: microvm labels without a typed profile never match"
    false
    (observation_only_request
       ~operation:"tool_execute"
       ~sandbox_profile:None
       ~input:(gate_input ~profile:"microvm" ~target:"microvm:masc-keeper-sandbox:local" [ "ls" ]));
  check bool
    "non-tool_execute never matches"
    false
    (observation_only_request ~operation:"slack_post" ~sandbox_profile:docker ~input:(gate_input [ "ls" ]));
  check bool
    "missing argv never matches"
    false
    (observation_only_request
       ~operation:"tool_execute"
       ~sandbox_profile:docker
       ~input:(`Assoc [ "input", `Assoc [] ]));
  check bool
    "non-string argv entry never matches"
    false
    (observation_only_request
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
  check bool (label ^ " is observation") true (Readonly.classify_script script |> is_static)
;;

let script_requires_observation label script =
  check bool (label ^ " requires execution evidence") false (Readonly.classify_script script |> is_static)
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
  script_requires_observation "pipeline of reads" "git show HEAD:f | sed -n '10,20p'";
  observation "pipeline with head" "ls repos | head -5";
  observation "cd before observing" "cd repos/masc && git rev-parse HEAD";
  observation "sequence of reads" "pwd; ls -la; echo ---";
  observation "newline-separated reads" "cat a\ncat b";
  observation "or-connector of reads" "ls /masc-work || echo none";
  observation "stderr joined to stdout" "ls x 2>&1 | head";
  observation "stderr discarded" "ls repos/_build 2>/dev/null | head -5";
  observation "stdin from a file" "wc -l < f";
  observation "tilde is a path the read resolves" "cat ~/notes";
  (* The tab cases RFC-0404 refused by character: the parser splits the
     flag out, so the guards see it. *)
  script_requires_observation "tab splits the sed in-place flag out" "sed -e\t-i s/a/b/ f";
  script_requires_observation "tab splits the rg preprocessor flag out" "rg --pre\trm x";
  script_requires_observation "tab splits the sort output flag out" "sort -o\tout f";
  script_requires_observation "tab splits the uniq second operand out" "uniq -c\ta b";
  (* Where the argv depends on the guest at run time. *)
  script_requires_observation "glob" "ls *.ml";
  script_requires_observation "bracket glob" "ls [a-z]*";
  script_requires_observation "brace expansion" "cat {a,b}";
  script_requires_observation "variable" "echo $HOME";
  script_requires_observation "command substitution" "echo $(whoami)";
  script_requires_observation "backtick" "echo `whoami`";
  script_requires_observation "subshell" "(ls)";
  script_requires_observation "environment prefix" "PAGER=cat git log";
  (* Effects, wherever they sit on the line. *)
  script_requires_observation "write redirect" "cat f > out";
  script_requires_observation "append redirect" "cat f >> out";
  script_requires_observation "a write after a read" "ls; rm -rf /";
  script_requires_observation "a write inside a pipeline" "cat f | tee out";
  script_requires_observation "fetch behind cd" "cd repos/masc && git fetch origin main";
  script_requires_observation "export then read" "export X=1; ls";
  script_requires_observation "a command outside the table" "curl https://example.com";
  script_requires_observation "a shell inside the script" "bash -c ls";
  script_requires_observation "whitespace only" "   ";
  script_requires_observation "empty" "";
  (* Leading environment assignments the IR separates into simple.Ir.env:
     the closed inert list decides which ones keep the observation fast
     path, every other name keeps its judge turn (task-1348). *)
  observation "inert NO_COLOR prefix" "NO_COLOR=1 gh pr list";
  observation "stacked inert prefixes" "TZ=UTC LANG=C git rev-parse HEAD";
  observation "inert prefix keeps flags" "NO_COLOR=1 CLICOLOR=0 gh run list";
  observation "assignment-looking argument is not a prefix" "echo NO_COLOR=1";
  script_requires_observation "unknown assignment name" "FOO=1 gh pr list";
  script_requires_observation "PATH assignment" "PATH=. ls";
  script_requires_observation "git external diff assignment" "GIT_EXTERNAL_DIFF=cat git diff";
  script_requires_observation "inert assignments alone are not a command" "NO_COLOR=1";
  (* [TZ] whose value could name a tzfile is not inert: glibc opens a
     value starting with [:] (or containing [/]) as a timezone file, so
     [TZ=:/etc/passwd git rev-parse HEAD] would be a file-existence oracle riding
     the observation fast path. The value guard sends it to the judge
     (code-reviewer HOLD, 2026-09-05). *)
  script_requires_observation "TZ tzfile reference via colon" "TZ=:/etc/passwd git rev-parse HEAD";
  script_requires_observation "TZ tzfile reference via slash" "TZ=/etc/localtime git rev-parse HEAD";
  observation "TZ zone abbreviation stays inert" "TZ=UTC git rev-parse HEAD"
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
    "compound script of reads passes (id joined the table)"
    true
    (executes_script ~operation:"tool_execute" ~sandbox_profile:docker "uname -a && id && pwd");
  check bool
    "compound script with one write still faces the judge"
    false
    (executes_script ~operation:"tool_execute" ~sandbox_profile:docker "uname -a && id && rm -rf x");
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
    (executes_script ~operation:"tool_execute" ~sandbox_profile:docker "  ");
  check bool
    "inert env prefix keeps an observation script judgment-free"
    true
    (executes_script ~operation:"tool_execute" ~sandbox_profile:docker
       "NO_COLOR=1 gh pr list");
  check bool
    "non-inert env prefix still faces the judge"
    false
    (executes_script ~operation:"tool_execute" ~sandbox_profile:docker
       "FOO=1 gh pr list")
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

(* ── the box between the tables and the judge (RFC-0422) ──────────────── *)

(* An argv the tables do not answer, on the profile the fleet runs. *)
let boxed_request base_path =
  gate_request ~sandbox_profile:microvm base_path [ "python3"; "-c"; "print(1)" ]
;;

let deferred_to_the_judge label = function
  | Keeper_gate.Deferred { reason = Judge_requested; _ }
  | Keeper_gate.Deferred { reason = Auto_judge_unavailable _; _ } -> ()
  | Keeper_gate.Allow { source; _ } ->
    failf "%s was allowed through %s" label (Keeper_gate.authorization_source_to_string source)
  | Keeper_gate.Deferred { reason = Human_requested; _ } ->
    failf "%s went to the human queue, not the judge lane" label
  | Keeper_gate.Deferred { reason = Mode_state_invalid detail; _ } ->
    failf "%s: mode_state_invalid: %s" label detail
  | Keeper_gate.Unavailable _ -> failf "%s made the queue unavailable" label
;;

(* Exit 0 in the box is the whole criterion: the kernel refused every write
   outside the scratch and every socket, so the run left nothing behind and
   its output is the answer. No queue entry, and the source says the box. *)
let test_auto_judge_allows_a_clean_observe_run () =
  with_auto_judge @@ fun base_path ->
  let asked = ref 0 in
  match
    Keeper_gate.decide
      ~keeper_always_allow:false
      ~observe:(fun () ->
        incr asked;
        Keeper_gate.Observed_result
          { run = Keeper_types_profile_sandbox.Observe
          ; result = { Masc_exec.Exec_dispatch.status = Unix.WEXITED 0; stdout = "1\n"; stderr = "" }
          })
      (boxed_request base_path)
  with
  | Keeper_gate.Allow
      { source = Observed_in_box { run = Keeper_types_profile_sandbox.Observe; _ }; _ } ->
    check int "the box was asked exactly once" 1 !asked
  | Keeper_gate.Allow { source; _ } ->
    failf "a clean observe run was allowed through the wrong source: %s"
      (Keeper_gate.authorization_source_to_string source)
  | Keeper_gate.Deferred _ -> fail "a clean observe run was deferred"
  | Keeper_gate.Unavailable _ -> fail "a clean observe run made the queue unavailable"
;;

let pending_count base_path =
  match Keeper_approval_queue.pending_count_for_keeper_in_workspace
          ~base_path ~keeper_name:"alpha" with
  | Ok count -> count
  | Error error -> fail (Keeper_approval_queue.storage_error_to_string error)
;;

let test_git_observation_returns_without_judge_queueing () =
  with_auto_judge @@ fun base_path ->
  List.iter
    (fun (_, argv) ->
      let asked = ref 0 in
      let stdout = "the box's Git output\n" in
      let decision =
        Keeper_gate.decide
          ~keeper_always_allow:false
          ~observe:(fun () ->
            incr asked;
            Keeper_gate.Observed_result
              { run = Keeper_types_profile_sandbox.Observe
              ; result = { Masc_exec.Exec_dispatch.status = Unix.WEXITED 0; stdout; stderr = "" }
              })
          (gate_request ~sandbox_profile:microvm base_path argv)
      in
      (match decision with
       | Keeper_gate.Allow
           { source = Observed_in_box { run = Keeper_types_profile_sandbox.Observe; result }; _ } ->
         check string "the captured result is returned" stdout result.stdout
       | Keeper_gate.Allow { source; _ } ->
         failf "Git required observation but used %s"
           (Keeper_gate.authorization_source_to_string source)
       | Keeper_gate.Deferred _ -> fail "successful Git observation queued a Judge"
       | Keeper_gate.Unavailable _ -> fail "successful Git observation made Gate unavailable");
      check int "the box executed once" 1 !asked;
      check int "no Judge request was created" 0 (pending_count base_path))
    git_execution_cases
;;

let test_git_without_a_box_uses_the_configured_judge () =
  with_auto_judge @@ fun base_path ->
  let asked = ref 0 in
  let decision =
    Keeper_gate.decide
      ~keeper_always_allow:false
      ~observe:(fun () ->
        incr asked;
        Keeper_gate.Observation_unavailable "no_box")
      (gate_request ~sandbox_profile:docker base_path
         [ "git"; "-c"; "core.fsmonitor=helper"; "status" ])
  in
  deferred_to_the_judge "Git whose configuration needs a box" decision;
  check int "the available execution path was consulted once" 1 !asked;
  check int "the existing Judge request was created" 1 (pending_count base_path)
;;

let test_git_refusal_reaches_the_judge_with_the_original_status () =
  with_auto_judge @@ fun base_path ->
  let asked = ref 0 in
  let stderr = "Git helper could not write its output\n" in
  let decision =
    Keeper_gate.decide
      ~keeper_always_allow:false
      ~observe:(fun () ->
        incr asked;
        Keeper_gate.Observed_refused { status = Unix.WEXITED 23; stderr })
      (script_gate_request ~sandbox_profile:microvm base_path
         "git diff --output=changes.patch")
  in
  deferred_to_the_judge "refused Git observation" decision;
  check int "the refused run was attempted once" 1 !asked;
  check int "one Judge request was created" 1 (pending_count base_path);
  match decision with
  | Keeper_gate.Deferred { approval_id; _ } ->
    (match Keeper_approval_queue.get_pending_entry_for_workspace ~base_path ~id:approval_id with
     | Ok (Some { observation = Some refusal; _ }) ->
       check bool "original exit status" true
         (refusal.observed_status = Keeper_approval_queue_rules_types.Observed_exit 23);
       check string "original stderr" stderr refusal.observed_stderr
     | Ok _ -> fail "the Git refusal was not recorded on the Judge request"
     | Error error -> fail (Keeper_approval_queue.storage_error_to_string error))
  | Keeper_gate.Allow _ | Keeper_gate.Unavailable _ -> ()
;;

(* A write the box refused ends non-zero. That is not an effect, and it is
   not an answer either: the request keeps the judge it would have had. *)
let test_auto_judge_defers_a_refused_observe_run () =
  with_auto_judge @@ fun base_path ->
  let stderr = "sh: 1: cannot create w: Permission denied" in
  let decision =
    Keeper_gate.decide
      ~keeper_always_allow:false
      ~observe:(fun () ->
        Keeper_gate.Observed_refused { status = Unix.WEXITED 2; stderr })
      (boxed_request base_path)
  in
  deferred_to_the_judge "a refused observe run" decision;
  (* And the judge is shown what the box refused: the row the deferral wrote
     carries the status and the program's own stderr (RFC-0422 §3.3). *)
  match decision with
  | Keeper_gate.Deferred { approval_id; _ } ->
    (match Keeper_approval_queue.get_pending_entry_for_workspace ~base_path ~id:approval_id with
     | Ok (Some { observation = Some refusal; _ }) ->
       check bool "exit 2 on the row" true
         (refusal.observed_status = Keeper_approval_queue_rules_types.Observed_exit 2);
       check string "the program's stderr on the row" stderr refusal.observed_stderr;
       check int "nothing cut at this size" 0 refusal.observed_stderr_omitted_bytes
     | Ok (Some { observation = None; _ }) -> fail "the row carries no observation"
     | Ok None -> fail "the deferral wrote no row"
     | Error error -> fail (Keeper_approval_queue.storage_error_to_string error))
  | Keeper_gate.Allow _ | Keeper_gate.Unavailable _ -> ()
;;

(* No box -- a Docker guest, a shim that predates it -- is the world before
   this stage: the judge, never an unboxed run. *)
let test_auto_judge_defers_when_no_box_can_be_built () =
  with_auto_judge @@ fun base_path ->
  Keeper_gate.decide
    ~keeper_always_allow:false
    ~observe:(fun () ->
      Keeper_gate.Observation_unavailable
        "docker_observe_unsupported: a Docker guest runs no masc-exec-shim")
    (boxed_request base_path)
  |> deferred_to_the_judge "a request with no box"
;;

(* The order is the point. A table answer costs nothing and comes first; an
   always-allowed keeper never pays a box run at all. *)
let test_the_box_is_asked_only_after_the_tables_decline () =
  with_auto_judge @@ fun base_path ->
  let never () = fail "the box was asked for a request the tables already answered" in
  (match
     Keeper_gate.decide
       ~keeper_always_allow:false
       ~observe:never
       (gate_request ~sandbox_profile:microvm base_path [ "ls"; "-la" ])
   with
   | Keeper_gate.Allow { source = Readonly_sandbox; _ } -> ()
   | Keeper_gate.Allow { source; _ } ->
     failf "table observation allowed through %s" (Keeper_gate.authorization_source_to_string source)
   | Keeper_gate.Deferred _ -> fail "table observation was deferred"
   | Keeper_gate.Unavailable _ -> fail "table observation made the queue unavailable");
  match
    Keeper_gate.decide ~keeper_always_allow:true ~observe:never (boxed_request base_path)
  with
  | Keeper_gate.Allow { source = Keeper_always_allow; _ } -> ()
  | Keeper_gate.Allow { source; _ } ->
    failf "an always-allowed keeper was allowed through %s"
      (Keeper_gate.authorization_source_to_string source)
  | Keeper_gate.Deferred _ -> fail "an always-allowed keeper was deferred"
  | Keeper_gate.Unavailable _ -> fail "an always-allowed keeper made the queue unavailable"
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
        ; test_case "write shapes require observation" `Quick test_write_shapes_require_observation
        ; test_case "gh read verbs pass" `Quick test_gh_read_verbs_pass
        ; test_case "gh write shapes require observation" `Quick test_gh_write_shapes_require_observation
        ; test_case "Git effects need execution evidence" `Quick test_git_effects_require_execution_evidence
        ; test_case "Git global configuration follows exact syntax" `Quick test_git_global_configuration_uses_exact_syntax
        ; test_case "Git reasons survive request projection" `Quick test_git_reasons_survive_the_request_projection
        ; test_case "Git classification omits raw arguments" `Quick test_git_classification_projection_contains_no_arguments
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
            "auto_judge allows a clean observe run"
            `Quick
            test_auto_judge_allows_a_clean_observe_run
        ; test_case
            "Git observation returns without Judge queueing"
            `Quick
            test_git_observation_returns_without_judge_queueing
        ; test_case
            "Git without a box uses the configured Judge"
            `Quick
            test_git_without_a_box_uses_the_configured_judge
        ; test_case
            "Git refusal preserves status for the Judge"
            `Quick
            test_git_refusal_reaches_the_judge_with_the_original_status
        ; test_case
            "auto_judge defers a refused observe run"
            `Quick
            test_auto_judge_defers_a_refused_observe_run
        ; test_case
            "auto_judge defers when no box can be built"
            `Quick
            test_auto_judge_defers_when_no_box_can_be_built
        ; test_case
            "the box is asked only after the tables decline"
            `Quick
            test_the_box_is_asked_only_after_the_tables_decline
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
