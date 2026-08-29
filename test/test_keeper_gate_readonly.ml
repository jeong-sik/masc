(* Closed-set tests for the observation-only gate fast-path. The argv tables
   are the whole safety surface, so every table entry and every guard is
   asserted — a table added without a test here should feel unfinished. *)

open Alcotest
open Masc

module Readonly = Keeper_gate_readonly

let gate_input argv =
  `Assoc
    [ "schema", `String "masc.keeper_gate.request.v1"
    ; "input", `Assoc [ "cwd", `String "/home/keeper/playground"; "argv", `List (List.map (fun s -> `String s) argv) ]
    ; "cwd", `String "/home/keeper/playground"
    ; "sandbox_profile", `String "docker"
    ; "sandbox_target", `String "docker:masc-keeper-sandbox:local"
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
  passes "git tag bare list" [ "git"; "tag" ];
  passes "git remote -v" [ "git"; "remote"; "-v" ];
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

let executes ~operation argv =
  Readonly.observation_only_request ~operation ~input:(gate_input argv)
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
    (Readonly.observation_only_request
       ~operation:"network_read"
       ~input:(network_input ~capability:"web_search"));
  check bool
    "web_fetch stays with the judge (caller-chosen address)"
    false
    (Readonly.observation_only_request
       ~operation:"network_read"
       ~input:(network_input ~capability:"web_fetch"));
  check bool
    "unknown capability never matches"
    false
    (Readonly.observation_only_request
       ~operation:"network_read"
       ~input:(network_input ~capability:"port_scan"));
  check bool
    "missing capability never matches"
    false
    (Readonly.observation_only_request
       ~operation:"network_read"
       ~input:(`Assoc [ "input", `Assoc [ "query", `String "x" ] ]));
  check bool
    "network arm ignores tool_execute shapes"
    false
    (Readonly.observation_only_request
       ~operation:"network_read"
       ~input:(gate_input [ "ls" ]));
  check
    (Alcotest.list Alcotest.string)
    "observation network set is closed at web_search"
    [ "web_search" ]
    Readonly.observation_network_capabilities
;;

let test_gate_shape_gates () =
  check bool "tool_execute docker ls" true (executes ~operation:"tool_execute" [ "ls" ]);
  check bool
    "non-tool_execute never matches"
    false
    (Readonly.observation_only_request ~operation:"slack_post" ~input:(gate_input [ "ls" ]));
  check bool
    "local sandbox profile never matches"
    false
    (Readonly.observation_only_request
       ~operation:"tool_execute"
       ~input:
         (`Assoc
            [ "schema", `String "masc.keeper_gate.request.v1"
            ; "input", `Assoc [ "argv", `List [ `String "ls" ] ]
            ; "sandbox_profile", `String "local"
            ; "sandbox_target", `String "local"
            ]));
  check bool
    "missing sandbox fields never matches"
    false
    (Readonly.observation_only_request ~operation:"tool_execute" ~input:(`Assoc [ "input", `Assoc [] ]));
  check bool
    "non-string argv entry never matches"
    false
    (Readonly.observation_only_request
       ~operation:"tool_execute"
       ~input:
         (`Assoc
            [ "input", `Assoc [ "argv", `List [ `String "ls"; `Int 3 ] ]
            ; "sandbox_profile", `String "docker"
            ; "sandbox_target", `String "docker:masc-keeper-sandbox:local"
            ]))
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

let gate_request base_path argv =
  { Keeper_gate.keeper_name = "sangsu"
  ; operation = "tool_execute"
  ; input = gate_input argv
  ; base_path
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

let test_auto_judge_allows_observation_without_queueing () =
  with_auto_judge @@ fun base_path ->
  match Keeper_gate.decide ~keeper_always_allow:false (gate_request base_path [ "ls"; "-la" ]) with
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

let test_auto_judge_still_defers_writes_to_the_judge () =
  with_auto_judge @@ fun base_path ->
  match Keeper_gate.decide ~keeper_always_allow:false (gate_request base_path [ "rm"; "-rf"; "out" ]) with
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
  match Keeper_gate.decide ~keeper_always_allow:false (gate_request base_path [ "ls" ]) with
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
        ; test_case "gate shape gates" `Quick test_gate_shape_gates
        ; test_case
            "network observation capabilities"
            `Quick
            test_network_observation_capabilities
        ] )
    ; ( "gate path"
      , [ test_case
            "auto_judge allows observation without queueing"
            `Quick
            test_auto_judge_allows_observation_without_queueing
        ; test_case
            "auto_judge still defers writes to the judge"
            `Quick
            test_auto_judge_still_defers_writes_to_the_judge
        ; test_case "manual mode still asks the human" `Quick test_manual_mode_still_asks_the_human
        ] )
    ]
;;
