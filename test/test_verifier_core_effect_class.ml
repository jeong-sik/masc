(** test_verifier_core_effect_class — Tests for the typed effect_class
    variant and classify_tool_effect function (RFC-0327 §A4).

    Replaces the old string-pattern read_only_patterns classifier with
    a typed variant that is exhaustively matchable and testable.

    @since RFC-0327 §A4 *)

open Masc

module Core = Verifier_core

(* ================================================================ *)
(* effect_class classification tests                                 *)
(* ================================================================ *)

let test_read_tools_classified_as_read () =
  let read_tools = [
    "read"; "grep"; "search"; "search_files"; "find";
    "list"; "ls"; "cat"; "head"; "tail"; "glob"; "rg";
  ] in
  List.iter (fun tool ->
    Alcotest.(check string)
      (Printf.sprintf "%s should classify as Read" tool)
      "read"
      (Core.effect_class_to_string (Core.classify_tool_effect ~tool_name:tool))
  ) read_tools

let test_git_read_commands_classified_as_read () =
  let git_read = [
    "git status"; "git log"; "git diff"; "git show";
    "git branch"; "git rev-parse";
  ] in
  List.iter (fun cmd ->
    Alcotest.(check string)
      (Printf.sprintf "%s should classify as Read" cmd)
      "read"
      (Core.effect_class_to_string (Core.classify_tool_effect ~tool_name:cmd))
  ) git_read

let test_surface_read_commands_classified_as_read () =
  let surfaces = ["status"; "view"; "get"; "fetch"; "query"] in
  List.iter (fun name ->
    Alcotest.(check string)
      (Printf.sprintf "%s should classify as Read" name)
      "read"
      (Core.effect_class_to_string (Core.classify_tool_effect ~tool_name:name))
  ) surfaces

let test_write_tools_classified_as_write () =
  let write_tools = ["edit"; "write"; "create"; "delete"; "patch"] in
  List.iter (fun tool ->
    Alcotest.(check string)
      (Printf.sprintf "%s should classify as Write" tool)
      "write"
      (Core.effect_class_to_string (Core.classify_tool_effect ~tool_name:tool))
  ) write_tools

let test_execute_tools_classified_as_execute () =
  let exec_tools = ["execute"; "shell"; "run"] in
  List.iter (fun tool ->
    Alcotest.(check string)
      (Printf.sprintf "%s should classify as Execute" tool)
      "execute"
      (Core.effect_class_to_string (Core.classify_tool_effect ~tool_name:tool))
  ) exec_tools

let test_git_write_commands_classified_as_execute () =
  let git_write = [
    "git add"; "git commit"; "git push"; "git pull";
    "git merge"; "git rebase"; "git checkout"; "git switch";
  ] in
  List.iter (fun cmd ->
    Alcotest.(check string)
      (Printf.sprintf "%s should classify as Execute" cmd)
      "execute"
      (Core.effect_class_to_string (Core.classify_tool_effect ~tool_name:cmd))
  ) git_write

let test_gh_mutations_classified_as_execute () =
  let gh_mut = ["gh pr create"; "gh pr merge"; "gh issue create"] in
  List.iter (fun cmd ->
    Alcotest.(check string)
      (Printf.sprintf "%s should classify as Execute" cmd)
      "execute"
      (Core.effect_class_to_string (Core.classify_tool_effect ~tool_name:cmd))
  ) gh_mut

let test_admin_tools_classified_as_admin () =
  let admin_tools = [
    "keeper_task_claim"; "keeper_task_done"; "masc_transition";
    "keeper_task_create"; "keeper_task_release";
    "keeper_board_post"; "keeper_board_comment"; "keeper_board_vote";
  ] in
  List.iter (fun tool ->
    Alcotest.(check string)
      (Printf.sprintf "%s should classify as Admin" tool)
      "admin"
      (Core.effect_class_to_string (Core.classify_tool_effect ~tool_name:tool))
  ) admin_tools

let test_unknown_tool_defaults_to_write () =
  Alcotest.(check string)
    "unknown tool should default to Write"
    "write"
    (Core.effect_class_to_string
       (Core.classify_tool_effect ~tool_name:"some_unknown_tool"))

(* ================================================================ *)
(* should_skip tests (backward compat + typed path)                  *)
(* ================================================================ *)

let test_should_skip_read_tool () =
  Alcotest.(check bool)
    "read tool should skip"
    true
    (Core.should_skip ~tool_name:"read" ())

let test_should_skip_grep () =
  Alcotest.(check bool)
    "grep should skip"
    true
    (Core.should_skip ~tool_name:"grep" ())

let test_should_not_skip_write_tool () =
  Alcotest.(check bool)
    "edit tool should not skip"
    false
    (Core.should_skip ~tool_name:"edit" ())

let test_should_not_skip_execute_tool () =
  Alcotest.(check bool)
    "execute should not skip"
    false
    (Core.should_skip ~tool_name:"execute" ())

let test_should_not_skip_admin_tool () =
  Alcotest.(check bool)
    "keeper_task_done should not skip"
    false
    (Core.should_skip ~tool_name:"keeper_task_done" ())

let test_should_skip_case_insensitive () =
  Alcotest.(check bool)
    "READ (uppercase) should skip"
    true
    (Core.should_skip ~tool_name:"READ" ())

(* ================================================================ *)
(* classify_tool_effect: case insensitivity                          *)
(* ================================================================ *)

let test_classify_case_insensitive () =
  Alcotest.(check string)
    "READ should classify as Read"
    "read"
    (Core.effect_class_to_string (Core.classify_tool_effect ~tool_name:"READ"))

let test_classify_whitespace_trimmed () =
  Alcotest.(check string)
    "  read  (padded) should classify as Read"
    "read"
    (Core.effect_class_to_string
       (Core.classify_tool_effect ~tool_name:"  read  "))

(* ================================================================ *)
(* effect_class_to_string roundtrip                                  *)
(* ================================================================ *)

let test_effect_class_to_string () =
  Alcotest.(check string) "Read" "read" (Core.effect_class_to_string Core.Read);
  Alcotest.(check string) "Write" "write" (Core.effect_class_to_string Core.Write);
  Alcotest.(check string) "Execute" "execute" (Core.effect_class_to_string Core.Execute);
  Alcotest.(check string) "Admin" "admin" (Core.effect_class_to_string Core.Admin)

(* ================================================================ *)
(* Tests runner                                                      *)
(* ================================================================ *)

let tests =
  [
    ("effect_class: read tools", `Quick, test_read_tools_classified_as_read);
    ("effect_class: git read commands", `Quick, test_git_read_commands_classified_as_read);
    ("effect_class: surface read commands", `Quick, test_surface_read_commands_classified_as_read);
    ("effect_class: write tools", `Quick, test_write_tools_classified_as_write);
    ("effect_class: execute tools", `Quick, test_execute_tools_classified_as_execute);
    ("effect_class: git write commands", `Quick, test_git_write_commands_classified_as_execute);
    ("effect_class: gh mutations", `Quick, test_gh_mutations_classified_as_execute);
    ("effect_class: admin tools", `Quick, test_admin_tools_classified_as_admin);
    ("effect_class: unknown defaults to write", `Quick, test_unknown_tool_defaults_to_write);
    ("should_skip: read tool", `Quick, test_should_skip_read_tool);
    ("should_skip: grep", `Quick, test_should_skip_grep);
    ("should_skip: write tool", `Quick, test_should_not_skip_write_tool);
    ("should_skip: execute tool", `Quick, test_should_not_skip_execute_tool);
    ("should_skip: admin tool", `Quick, test_should_not_skip_admin_tool);
    ("should_skip: case insensitive", `Quick, test_should_skip_case_insensitive);
    ("classify: case insensitive", `Quick, test_classify_case_insensitive);
    ("classify: whitespace trimmed", `Quick, test_classify_whitespace_trimmed);
    ("effect_class_to_string roundtrip", `Quick, test_effect_class_to_string);
  ]

let () =
  Alcotest.run "Verifier_core.effect_class" tests