(** Tests for command_descriptor — deterministic PR event detection. *)

open Alcotest

module Desc = Command_descriptor
module Execute_runtime = Masc.Keeper_tool_execute_runtime.For_testing
module Metrics = Masc.Otel_metric_store

let with_temp_dir f =
  let dir = Filename.temp_file "cmd_desc_test" "" in
  Sys.remove dir;
  Unix.mkdir dir 0o755;
  (try f dir with exn ->
     ignore (Sys.command (Printf.sprintf "rm -rf %s" dir));
     raise exn);
  ignore (Sys.command (Printf.sprintf "rm -rf %s" dir))
;;

(** Helper: parse command string to Shell_ir.t via Exec_policy. *)
let parse_ir cmd =
  match Exec_policy.parse_string_to_ir ~mode:Exec_policy.Strict cmd with
  | Ok ir -> ir
  | Error reason -> failf "parse failed: %s" (Exec_policy.block_reason_to_string reason)
;;

(** {1 Gh PR operations} *)

let test_gh_pr_create () =
  let ir = parse_ir "gh pr create --title 'feat: add tests' --base main" in
  match Desc.compute ir with
  | Ide_event_types.Gh_pr_create { title; base; draft } ->
    check string "title" "feat: add tests" title;
    check string "base" "main" base;
    check bool "draft" false draft
  | other -> failf "expected Gh_pr_create, got %s" (Yojson.Safe.to_string (Ide_event_types.command_descriptor_to_json other))
;;

let test_gh_pr_create_draft () =
  let ir = parse_ir "gh pr create --title wip --draft" in
  match Desc.compute ir with
  | Ide_event_types.Gh_pr_create { draft; _ } ->
    check bool "draft" true draft
  | other -> failf "expected Gh_pr_create, got %s" (Yojson.Safe.to_string (Ide_event_types.command_descriptor_to_json other))
;;

let test_gh_pr_create_base_eq () =
  (* --base is consumed by the GADT parser and discarded (not in rest).
     So base defaults to "main". This is a known limitation. *)
  let ir = parse_ir "gh pr create --title feat --base=develop" in
  match Desc.compute ir with
  | Ide_event_types.Gh_pr_create { base; _ } ->
    check string "base defaults to main" "main" base
  | other -> failf "expected Gh_pr_create, got %s" (Yojson.Safe.to_string (Ide_event_types.command_descriptor_to_json other))
;;

let test_gh_pr_create_base_short () =
  (* -B is consumed by the GADT parser and discarded (not in rest).
     So base defaults to "main". This is a known limitation. *)
  let ir = parse_ir "gh pr create --title feat -B develop" in
  match Desc.compute ir with
  | Ide_event_types.Gh_pr_create { base; _ } ->
    check string "base defaults to main" "main" base
  | other -> failf "expected Gh_pr_create, got %s" (Yojson.Safe.to_string (Ide_event_types.command_descriptor_to_json other))
;;

let test_gh_pr_search () =
  let ir = parse_ir "gh pr list --search 'task-1814' --state all" in
  match Desc.compute ir with
  | Ide_event_types.Gh_pr_search { query; state } ->
    check string "query" "task-1814" query;
    check (option string) "state" (Some "all") state
  | other ->
    failf
      "expected Gh_pr_search, got %s"
      (Yojson.Safe.to_string
         (Ide_event_types.command_descriptor_to_json other))
;;

let test_gh_pr_list_without_search_is_generic () =
  let ir = parse_ir "gh pr list --state all" in
  match Desc.compute ir with
  | Ide_event_types.Generic -> ()
  | other ->
    failf
      "expected Generic, got %s"
      (Yojson.Safe.to_string
         (Ide_event_types.command_descriptor_to_json other))
;;

let test_gh_pr_merge () =
  let ir = parse_ir "gh pr merge 123 --squash" in
  match Desc.compute ir with
  | Ide_event_types.Gh_pr_merge { pr_number; squash } ->
    check int "pr_number" 123 pr_number;
    check bool "squash" true squash
  | other -> failf "expected Gh_pr_merge, got %s" (Yojson.Safe.to_string (Ide_event_types.command_descriptor_to_json other))
;;

let test_gh_pr_comment () =
  let ir = parse_ir "gh pr comment 456 --body LGTM" in
  match Desc.compute ir with
  | Ide_event_types.Gh_pr_comment { pr_number; body } ->
    check int "pr_number" 456 pr_number;
    check string "body" "LGTM" body
  | other -> failf "expected Gh_pr_comment, got %s" (Yojson.Safe.to_string (Ide_event_types.command_descriptor_to_json other))
;;

let test_gh_pr_close () =
  let ir = parse_ir "gh pr close 789" in
  match Desc.compute ir with
  | Ide_event_types.Gh_pr_close { pr_number } ->
    check int "pr_number" 789 pr_number
  | other -> failf "expected Gh_pr_close, got %s" (Yojson.Safe.to_string (Ide_event_types.command_descriptor_to_json other))
;;

let test_gh_pr_review () =
  let ir = parse_ir "gh pr review 321" in
  match Desc.compute ir with
  | Ide_event_types.Gh_pr_review { pr_number } ->
    check int "pr_number" 321 pr_number
  | other -> failf "expected Gh_pr_review, got %s" (Yojson.Safe.to_string (Ide_event_types.command_descriptor_to_json other))
;;

(** {1 Gh Issue operations} *)

let test_gh_issue_create () =
  let ir = parse_ir "gh issue create --title 'bug: crash' --body details" in
  match Desc.compute ir with
  | Ide_event_types.Gh_issue_create { title; body } ->
    check string "title" "bug: crash" title;
    check string "body" "details" body
  | other -> failf "expected Gh_issue_create, got %s" (Yojson.Safe.to_string (Ide_event_types.command_descriptor_to_json other))
;;

let test_gh_issue_close () =
  let ir = parse_ir "gh issue close 100" in
  match Desc.compute ir with
  | Ide_event_types.Gh_issue_close { issue_number } ->
    check int "issue_number" 100 issue_number
  | other -> failf "expected Gh_issue_close, got %s" (Yojson.Safe.to_string (Ide_event_types.command_descriptor_to_json other))
;;

(** {1 Git operations} *)

let test_git_push () =
  let ir = parse_ir "git push origin main --force" in
  match Desc.compute ir with
  | Ide_event_types.Git_push { remote; branch; force } ->
    check string "remote" "origin" remote;
    check string "branch" "main" branch;
    check bool "force" true force
  | other -> failf "expected Git_push, got %s" (Yojson.Safe.to_string (Ide_event_types.command_descriptor_to_json other))
;;

let test_git_push_force_with_lease () =
  let ir = parse_ir "git push origin main --force-with-lease" in
  match Desc.compute ir with
  | Ide_event_types.Git_push { force; _ } ->
    check bool "force" true force
  | other -> failf "expected Git_push, got %s" (Yojson.Safe.to_string (Ide_event_types.command_descriptor_to_json other))
;;

let test_git_commit () =
  let ir = parse_ir "git commit -m 'fix: bug'" in
  match Desc.compute ir with
  | Ide_event_types.Git_commit { message } ->
    check string "message" "fix: bug" message
  | other -> failf "expected Git_commit, got %s" (Yojson.Safe.to_string (Ide_event_types.command_descriptor_to_json other))
;;

let test_git_commit_amend () =
  let ir = parse_ir "git commit --amend -m 'fix: updated'" in
  match Desc.compute ir with
  | Ide_event_types.Git_commit { message } ->
    check bool "contains amend" true (String.contains message '(')
  | other -> failf "expected Git_commit, got %s" (Yojson.Safe.to_string (Ide_event_types.command_descriptor_to_json other))
;;

(** {1 Generic / edge cases} *)

let test_generic_unknown () =
  let ir = parse_ir "ls -la" in
  match Desc.compute ir with
  | Ide_event_types.Generic -> ()
  | other -> failf "expected Generic, got %s" (Yojson.Safe.to_string (Ide_event_types.command_descriptor_to_json other))
;;

let test_generic_pipeline () =
  let ir = parse_ir "cat file.txt | grep pattern" in
  match Desc.compute ir with
  | Ide_event_types.Pipe_chain { first_cmd; last_cmd; length } ->
    check string "first_cmd" "cat" first_cmd;
    check string "last_cmd" "grep" last_cmd;
    check int "length" 2 length
  | other -> failf "expected Pipe_chain, got %s" (Yojson.Safe.to_string (Ide_event_types.command_descriptor_to_json other))
;;

(** {1 Pipe chain classification} *)

let test_pipe_chain_rg_grep_head () =
  let ir = parse_ir "rg foo | grep bar | head" in
  match Desc.compute ir with
  | Ide_event_types.Pipe_chain { first_cmd; last_cmd; length } ->
    check string "first_cmd" "rg" first_cmd;
    check string "last_cmd" "head" last_cmd;
    check int "length" 3 length
  | other -> failf "expected Pipe_chain, got %s" (Yojson.Safe.to_string (Ide_event_types.command_descriptor_to_json other))
;;

let test_pipe_chain_gh_in_last () =
  (* When the last command is gh, the pipeline should resolve to the gh descriptor *)
  let ir = parse_ir "cat file.txt | gh pr create --title test" in
  match Desc.compute ir with
  | Ide_event_types.Gh_pr_create { title; _ } ->
    check string "title" "test" title
  | other -> failf "expected Gh_pr_create, got %s" (Yojson.Safe.to_string (Ide_event_types.command_descriptor_to_json other))
;;

let test_pipe_chain_git_push () =
  (* When the last command is git push, use that directly *)
  let ir = parse_ir "echo pushing | git push origin main" in
  match Desc.compute ir with
  | Ide_event_types.Git_push { remote; branch; _ } ->
    check string "remote" "origin" remote;
    check string "branch" "main" branch
  | other -> failf "expected Git_push, got %s" (Yojson.Safe.to_string (Ide_event_types.command_descriptor_to_json other))
;;

(** {1 PR action metrics} *)

let single_pr_action_labels ir =
  match Desc.pr_action_events_of_ir ir with
  | [ event ] ->
    ( Desc.pr_action_surface_to_string event.surface
    , Desc.pr_action_to_string event.action )
  | events -> failf "expected one PR action event, got %d" (List.length events)
;;

let test_pr_action_projection_uses_typed_gh_only () =
  let surface, action =
    parse_ir "gh pr create --title 'feat: metrics' --draft"
    |> single_pr_action_labels
  in
  check string "surface" "gh_cli" surface;
  check string "action" "create" action;
  let pipeline_surface, pipeline_action =
    parse_ir "cat body.md | gh pr comment 123 --body LGTM"
    |> single_pr_action_labels
  in
  check string "pipeline surface" "gh_cli" pipeline_surface;
  check string "pipeline action" "comment" pipeline_action;
  let search_surface, search_action =
    parse_ir "gh pr list --search 'task-1814' --state all"
    |> single_pr_action_labels
  in
  check string "search surface" "gh_cli" search_surface;
  check string "search action" "search" search_action;
  let git_merge_ir = parse_ir "git merge feature-branch --squash" in
  check int "git merge is not gh PR action" 0
    (List.length (Desc.pr_action_events_of_ir git_merge_ir))
  ;
  let plain_list_ir = parse_ir "gh pr list --state all" in
  check int "plain gh pr list is not duplicate-search evidence" 0
    (List.length (Desc.pr_action_events_of_ir plain_list_ir))
;;

let test_tool_execute_pr_action_metric_labels () =
  let ir = parse_ir "gh pr create --title 'feat: metrics' --draft" in
  let metric = Keeper_metrics.(to_string ToolExecutePrActionTotal) in
  let keeper_name = "test-pr-action-metric" in
  let labels =
    [ "keeper", keeper_name
    ; "surface", "gh_cli"
    ; "action", "create"
    ; "status", "success"
    ; "risk_class", "R1"
    ]
  in
  let before = Metrics.metric_value_or_zero metric ~labels () in
  Execute_runtime.record_pr_action_metric
    ~keeper_name
    ~risk_class:Masc_exec.Shell_ir_risk.R1_Reversible_mutation
    ~status:(Unix.WEXITED 0)
    ir;
  let after = Metrics.metric_value_or_zero metric ~labels () in
  check bool "success metric increments" true (after >= before +. 1.0);
  let failed_labels =
    [ "keeper", keeper_name
    ; "surface", "gh_cli"
    ; "action", "create"
    ; "status", "exit_nonzero"
    ; "risk_class", "R1"
    ]
  in
  let failed_before =
    Metrics.metric_value_or_zero metric ~labels:failed_labels ()
  in
  Execute_runtime.record_pr_action_metric
    ~keeper_name
    ~risk_class:Masc_exec.Shell_ir_risk.R1_Reversible_mutation
    ~status:(Unix.WEXITED 1)
    ir;
  let failed_after =
    Metrics.metric_value_or_zero metric ~labels:failed_labels ()
  in
  check bool "failed attempt metric increments" true
    (failed_after >= failed_before +. 1.0);
  let search_ir = parse_ir "gh pr list --search 'task-1814' --state all" in
  let search_labels =
    [ "keeper", keeper_name
    ; "surface", "gh_cli"
    ; "action", "search"
    ; "status", "success"
    ; "risk_class", "R0"
    ]
  in
  let search_before =
    Metrics.metric_value_or_zero metric ~labels:search_labels ()
  in
  Execute_runtime.record_pr_action_metric
    ~keeper_name
    ~risk_class:Masc_exec.Shell_ir_risk.R0_Read
    ~status:(Unix.WEXITED 0)
    search_ir;
  let search_after =
    Metrics.metric_value_or_zero metric ~labels:search_labels ()
  in
  check bool "search metric increments" true
    (search_after >= search_before +. 1.0);
  let total_before = Metrics.metric_total metric in
  Execute_runtime.record_pr_action_metric
    ~keeper_name
    ~risk_class:Masc_exec.Shell_ir_risk.R1_Reversible_mutation
    ~status:(Unix.WEXITED 0)
    (parse_ir "git merge feature-branch --squash");
  let total_after = Metrics.metric_total metric in
  check (float 0.0) "non-gh command does not increment" total_before total_after
;;

(** {1 Exit code semantics} *)

let test_exit_code_grep_no_match () =
  match Ide_event_types.interpret_exit_code ~cmd_name:"grep" ~exit_code:1 with
  | Ide_event_types.No_matches -> ()
  | other -> failf "expected No_matches, got different"

let test_exit_code_grep_error () =
  match Ide_event_types.interpret_exit_code ~cmd_name:"grep" ~exit_code:2 with
  | Ide_event_types.Error _ -> ()
  | _ -> failf "expected Error"

let test_exit_code_diff_files_differ () =
  match Ide_event_types.interpret_exit_code ~cmd_name:"diff" ~exit_code:1 with
  | Ide_event_types.Files_differ -> ()
  | _ -> failf "expected Files_differ"

let test_exit_code_general_success () =
  match Ide_event_types.interpret_exit_code ~cmd_name:"ls" ~exit_code:0 with
  | Ide_event_types.Success -> ()
  | _ -> failf "expected Success"

let test_exit_code_general_error () =
  match Ide_event_types.interpret_exit_code ~cmd_name:"ls" ~exit_code:1 with
  | Ide_event_types.Error _ -> ()
  | _ -> failf "expected Error"

(** {1 Command category classification} *)

let test_category_search () =
  match Ide_event_types.classify_cmd_category ~cmd_name:"rg" with
  | Ide_event_types.Search_cmd -> ()
  | _ -> failf "expected Search_cmd"

let test_category_read () =
  match Ide_event_types.classify_cmd_category ~cmd_name:"cat" with
  | Ide_event_types.Read_cmd -> ()
  | _ -> failf "expected Read_cmd"

let test_category_list () =
  match Ide_event_types.classify_cmd_category ~cmd_name:"ls" with
  | Ide_event_types.List_cmd -> ()
  | _ -> failf "expected List_cmd"

let test_category_silent () =
  match Ide_event_types.classify_cmd_category ~cmd_name:"mv" with
  | Ide_event_types.Silent_cmd -> ()
  | _ -> failf "expected Silent_cmd"

let test_category_write () =
  match Ide_event_types.classify_cmd_category ~cmd_name:"dune" with
  | Ide_event_types.Write_cmd -> ()
  | _ -> failf "expected Write_cmd"

(** {1 Bridge integration} *)

let test_extract_descriptor_gh_pr_create () =
  let output = {|{"ok":true,"output":"https://github.com/owner/repo/pull/123","command_descriptor":{"kind":"gh_pr_create","title":"feat","base":"main","draft":false}}|} in
  match Ide_bridge.extract_descriptor_from_output output with
  | Some (Ide_event_types.Gh_pr_create { title; base; draft }) ->
    check string "title" "feat" title;
    check string "base" "main" base;
    check bool "draft" false draft
  | other -> failf "expected Gh_pr_create descriptor, got %s" (match other with Some d -> Yojson.Safe.to_string (Ide_event_types.command_descriptor_to_json d) | None -> "None")
;;

let test_extract_descriptor_gh_pr_search () =
  let output =
    {|{"ok":true,"output":"[]","command_descriptor":{"kind":"gh_pr_search","query":"task-1814","state":"all","duplicate_search":true}}|}
  in
  match Ide_bridge.extract_descriptor_from_output output with
  | Some (Ide_event_types.Gh_pr_search { query; state }) ->
    check string "query" "task-1814" query;
    check (option string) "state" (Some "all") state
  | other ->
    failf
      "expected Gh_pr_search descriptor, got %s"
      (match other with
       | Some d -> Yojson.Safe.to_string (Ide_event_types.command_descriptor_to_json d)
       | None -> "None")
;;

let test_descriptor_to_pr_event () =
  with_temp_dir (fun base_dir ->
    let output = {|{"ok":true,"output":"{\"number\":999,\"url\":\"https://github.com/jeong-sik/masc/pull/999\"}","command_descriptor":{"kind":"gh_pr_create","title":"test PR","base":"main","draft":false}}|} in
    Ide_bridge.ingest_pr_event_from_descriptor
      ~base_path:base_dir
      ~partition:Ide_paths.Legacy_default
      ~keeper_id:"k1"
      ~turn_id:"t1"
      ~output_text:output
      ~tool_name:"execute"
      ~success:true;
    let dir = Ide_paths.partition_store_dir ~base_dir:base_dir Ide_paths.Legacy_default in
    let path = Filename.concat dir "pr_events.jsonl" in
    check bool "file exists" true (Sys.file_exists path);
    let ic = open_in path in
    let line = input_line ic in
    close_in ic;
    let json = Yojson.Safe.from_string line in
    let pr_number = Yojson.Safe.Util.member "pr_number" json |> Yojson.Safe.Util.to_int in
    let pr_title = Yojson.Safe.Util.member "pr_title" json |> Yojson.Safe.Util.to_string in
    check int "pr_number" 999 pr_number;
    check string "pr_title" "test PR" pr_title)
;;

let test_descriptor_merge_event () =
  with_temp_dir (fun base_dir ->
    let output = {|{"ok":true,"output":"","command_descriptor":{"kind":"gh_pr_merge","pr_number":456,"squash":true}}|} in
    Ide_bridge.ingest_pr_event_from_descriptor
      ~base_path:base_dir
      ~partition:Ide_paths.Legacy_default
      ~keeper_id:"k1"
      ~turn_id:"t1"
      ~output_text:output
      ~tool_name:"execute"
      ~success:true;
    let dir = Ide_paths.partition_store_dir ~base_dir:base_dir Ide_paths.Legacy_default in
    let path = Filename.concat dir "pr_events.jsonl" in
    check bool "file exists" true (Sys.file_exists path);
    let ic = open_in path in
    let line = input_line ic in
    close_in ic;
    let json = Yojson.Safe.from_string line in
    let pr_number = Yojson.Safe.Util.member "pr_number" json |> Yojson.Safe.Util.to_int in
    let pr_state = Yojson.Safe.Util.member "pr_state" json |> Yojson.Safe.Util.to_string in
    check int "pr_number" 456 pr_number;
    check string "pr_state" "merged" pr_state)
;;

let () =
  run
    "command_descriptor"
    [ ( "gh_pr"
      , [ test_case "create" `Quick test_gh_pr_create
        ; test_case "create --draft" `Quick test_gh_pr_create_draft
        ; test_case "create --base=develop" `Quick test_gh_pr_create_base_eq
        ; test_case "create -b develop" `Quick test_gh_pr_create_base_short
        ; test_case "search" `Quick test_gh_pr_search
        ; test_case "plain list is generic" `Quick test_gh_pr_list_without_search_is_generic
        ; test_case "merge" `Quick test_gh_pr_merge
        ; test_case "comment" `Quick test_gh_pr_comment
        ; test_case "close" `Quick test_gh_pr_close
        ; test_case "review" `Quick test_gh_pr_review
        ] )
    ; ( "gh_issue"
      , [ test_case "create" `Quick test_gh_issue_create
        ; test_case "close" `Quick test_gh_issue_close
        ] )
    ; ( "git"
      , [ test_case "push --force" `Quick test_git_push
        ; test_case "push --force-with-lease" `Quick test_git_push_force_with_lease
        ; test_case "commit" `Quick test_git_commit
        ; test_case "commit --amend" `Quick test_git_commit_amend
        ] )
    ; ( "generic"
      , [ test_case "unknown command" `Quick test_generic_unknown
        ; test_case "pipeline" `Quick test_generic_pipeline
        ] )
    ; ( "pipe_chain"
      , [ test_case "rg|grep|head" `Quick test_pipe_chain_rg_grep_head
        ; test_case "gh in last position" `Quick test_pipe_chain_gh_in_last
        ; test_case "git push in last" `Quick test_pipe_chain_git_push
        ] )
    ; ( "pr_action_metrics"
      , [ test_case "typed gh projection" `Quick test_pr_action_projection_uses_typed_gh_only
        ; test_case "tool_execute metric labels" `Quick test_tool_execute_pr_action_metric_labels
        ] )
    ; ( "exit_code_semantics"
      , [ test_case "grep no match" `Quick test_exit_code_grep_no_match
        ; test_case "grep error" `Quick test_exit_code_grep_error
        ; test_case "diff files differ" `Quick test_exit_code_diff_files_differ
        ; test_case "general success" `Quick test_exit_code_general_success
        ; test_case "general error" `Quick test_exit_code_general_error
        ] )
    ; ( "cmd_category"
      , [ test_case "search" `Quick test_category_search
        ; test_case "read" `Quick test_category_read
        ; test_case "list" `Quick test_category_list
        ; test_case "silent" `Quick test_category_silent
        ; test_case "write" `Quick test_category_write
        ] )
    ; ( "bridge_integration"
      , [ test_case "extract descriptor" `Quick test_extract_descriptor_gh_pr_create
        ; test_case "extract search descriptor" `Quick test_extract_descriptor_gh_pr_search
        ; test_case "descriptor to PR event" `Quick test_descriptor_to_pr_event
        ; test_case "descriptor merge event" `Quick test_descriptor_merge_event
        ] )
    ]
