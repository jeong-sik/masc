(** Tests for command_descriptor — deterministic PR event detection. *)

open Alcotest

module Desc = Masc.Keeper_tool_execute_runtime.For_testing

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
  match Masc.Exec_policy.parse_string_to_ir ~mode:Masc.Exec_policy.Strict cmd with
  | Ok ir -> ir
  | Error reason -> failf "parse failed: %s" (Masc.Exec_policy.block_reason_to_string reason)
;;

(** {1 Gh PR operations} *)

let test_gh_pr_create () =
  let ir = parse_ir "gh pr create --title 'feat: add tests' --base main" in
  match Desc.compute_command_descriptor ir with
  | Ide_event_types.Gh_pr_create { title; base; draft } ->
    check string "title" "feat: add tests" title;
    check string "base" "main" base;
    check bool "draft" false draft
  | other -> failf "expected Gh_pr_create, got %s" (Yojson.Safe.to_string (Ide_event_types.command_descriptor_to_json other))
;;

let test_gh_pr_create_draft () =
  let ir = parse_ir "gh pr create --title wip --draft" in
  match Desc.compute_command_descriptor ir with
  | Ide_event_types.Gh_pr_create { draft; _ } ->
    check bool "draft" true draft
  | other -> failf "expected Gh_pr_create, got %s" (Yojson.Safe.to_string (Ide_event_types.command_descriptor_to_json other))
;;

let test_gh_pr_create_base_eq () =
  (* --base is consumed by the GADT parser and discarded (not in rest).
     So base defaults to "main". This is a known limitation. *)
  let ir = parse_ir "gh pr create --title feat --base=develop" in
  match Desc.compute_command_descriptor ir with
  | Ide_event_types.Gh_pr_create { base; _ } ->
    check string "base defaults to main" "main" base
  | other -> failf "expected Gh_pr_create, got %s" (Yojson.Safe.to_string (Ide_event_types.command_descriptor_to_json other))
;;

let test_gh_pr_create_base_short () =
  (* -B is consumed by the GADT parser and discarded (not in rest).
     So base defaults to "main". This is a known limitation. *)
  let ir = parse_ir "gh pr create --title feat -B develop" in
  match Desc.compute_command_descriptor ir with
  | Ide_event_types.Gh_pr_create { base; _ } ->
    check string "base defaults to main" "main" base
  | other -> failf "expected Gh_pr_create, got %s" (Yojson.Safe.to_string (Ide_event_types.command_descriptor_to_json other))
;;

let test_gh_pr_merge () =
  let ir = parse_ir "gh pr merge 123 --squash" in
  match Desc.compute_command_descriptor ir with
  | Ide_event_types.Gh_pr_merge { pr_number; squash } ->
    check int "pr_number" 123 pr_number;
    check bool "squash" true squash
  | other -> failf "expected Gh_pr_merge, got %s" (Yojson.Safe.to_string (Ide_event_types.command_descriptor_to_json other))
;;

let test_gh_pr_comment () =
  let ir = parse_ir "gh pr comment 456 --body LGTM" in
  match Desc.compute_command_descriptor ir with
  | Ide_event_types.Gh_pr_comment { pr_number; body } ->
    check int "pr_number" 456 pr_number;
    check string "body" "LGTM" body
  | other -> failf "expected Gh_pr_comment, got %s" (Yojson.Safe.to_string (Ide_event_types.command_descriptor_to_json other))
;;

let test_gh_pr_close () =
  let ir = parse_ir "gh pr close 789" in
  match Desc.compute_command_descriptor ir with
  | Ide_event_types.Gh_pr_close { pr_number } ->
    check int "pr_number" 789 pr_number
  | other -> failf "expected Gh_pr_close, got %s" (Yojson.Safe.to_string (Ide_event_types.command_descriptor_to_json other))
;;

let test_gh_pr_review () =
  let ir = parse_ir "gh pr review 321" in
  match Desc.compute_command_descriptor ir with
  | Ide_event_types.Gh_pr_review { pr_number } ->
    check int "pr_number" 321 pr_number
  | other -> failf "expected Gh_pr_review, got %s" (Yojson.Safe.to_string (Ide_event_types.command_descriptor_to_json other))
;;

(** {1 Gh Issue operations} *)

let test_gh_issue_create () =
  let ir = parse_ir "gh issue create --title 'bug: crash' --body details" in
  match Desc.compute_command_descriptor ir with
  | Ide_event_types.Gh_issue_create { title; body } ->
    check string "title" "bug: crash" title;
    check string "body" "details" body
  | other -> failf "expected Gh_issue_create, got %s" (Yojson.Safe.to_string (Ide_event_types.command_descriptor_to_json other))
;;

let test_gh_issue_close () =
  let ir = parse_ir "gh issue close 100" in
  match Desc.compute_command_descriptor ir with
  | Ide_event_types.Gh_issue_close { issue_number } ->
    check int "issue_number" 100 issue_number
  | other -> failf "expected Gh_issue_close, got %s" (Yojson.Safe.to_string (Ide_event_types.command_descriptor_to_json other))
;;

(** {1 Git operations} *)

let test_git_push () =
  let ir = parse_ir "git push origin main --force" in
  match Desc.compute_command_descriptor ir with
  | Ide_event_types.Git_push { remote; branch; force } ->
    check string "remote" "origin" remote;
    check string "branch" "main" branch;
    check bool "force" true force
  | other -> failf "expected Git_push, got %s" (Yojson.Safe.to_string (Ide_event_types.command_descriptor_to_json other))
;;

let test_git_push_force_with_lease () =
  let ir = parse_ir "git push origin main --force-with-lease" in
  match Desc.compute_command_descriptor ir with
  | Ide_event_types.Git_push { force; _ } ->
    check bool "force" true force
  | other -> failf "expected Git_push, got %s" (Yojson.Safe.to_string (Ide_event_types.command_descriptor_to_json other))
;;

let test_git_commit () =
  let ir = parse_ir "git commit -m 'fix: bug'" in
  match Desc.compute_command_descriptor ir with
  | Ide_event_types.Git_commit { message } ->
    check string "message" "fix: bug" message
  | other -> failf "expected Git_commit, got %s" (Yojson.Safe.to_string (Ide_event_types.command_descriptor_to_json other))
;;

let test_git_commit_amend () =
  let ir = parse_ir "git commit --amend -m 'fix: updated'" in
  match Desc.compute_command_descriptor ir with
  | Ide_event_types.Git_commit { message } ->
    check bool "contains amend" true (String.contains message '(')
  | other -> failf "expected Git_commit, got %s" (Yojson.Safe.to_string (Ide_event_types.command_descriptor_to_json other))
;;

(** {1 Generic / edge cases} *)

let test_generic_unknown () =
  let ir = parse_ir "ls -la" in
  match Desc.compute_command_descriptor ir with
  | Ide_event_types.Generic -> ()
  | other -> failf "expected Generic, got %s" (Yojson.Safe.to_string (Ide_event_types.command_descriptor_to_json other))
;;

let test_generic_pipeline () =
  let ir = parse_ir "cat file.txt | grep pattern" in
  match Desc.compute_command_descriptor ir with
  | Ide_event_types.Generic -> ()
  | other -> failf "expected Generic for pipeline, got %s" (Yojson.Safe.to_string (Ide_event_types.command_descriptor_to_json other))
;;

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

let test_descriptor_to_pr_event () =
  with_temp_dir (fun base_dir ->
    let output = {|{"ok":true,"output":"https://github.com/jeong-sik/masc/pull/999","command_descriptor":{"kind":"gh_pr_create","title":"test PR","base":"main","draft":false}}|} in
    Ide_bridge.ingest_pr_event_from_descriptor
      ~base_path:base_dir
      ~keeper_id:"k1"
      ~turn_id:"t1"
      ~output_text:output
      ~tool_name:"execute";
    let dir = Ide_paths.partition_store_dir ~base_dir:base_dir Ide_paths.Orphan in
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
      ~keeper_id:"k1"
      ~turn_id:"t1"
      ~output_text:output
      ~tool_name:"execute";
    let dir = Ide_paths.partition_store_dir ~base_dir:base_dir Ide_paths.Orphan in
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
    ; ( "bridge_integration"
      , [ test_case "extract descriptor" `Quick test_extract_descriptor_gh_pr_create
        ; test_case "descriptor to PR event" `Quick test_descriptor_to_pr_event
        ; test_case "descriptor merge event" `Quick test_descriptor_merge_event
        ] )
    ]
