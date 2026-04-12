(** Tests for [Keeper_tool_registry.is_read_only_with_input].

    Validates input-aware read-only classification for keeper_github:
    1. Read-only gh subcommands (pr list, issue view, etc.) via cmd
    2. Read-only gh subcommands via args (argv list)
    3. Mutating gh subcommands are not classified as read-only
    4. gh api GET (default) is read-only
    5. gh api with -X POST/PUT/DELETE is mutating
    6. gh api with -f/-F (implicit POST) is mutating
    7. gh api graphql is mutating (always POST)
    8. Edge cases: empty input, non-keeper_github tools, whitespace *)

open Masc_mcp

let is_ro ~tool_name ~input =
  Keeper_tool_registry.is_read_only_with_input ~tool_name ~input

let is_boundary_exempt ~tool_name ~input =
  Keeper_tool_registry.is_main_worktree_boundary_exempt_with_input
    ~tool_name ~input

let mk_cmd cmd =
  `Assoc [ ("cmd", `String cmd) ]

let mk_args args =
  `Assoc [ ("args", `List (List.map (fun s -> `String s) args)) ]

let mk_cmd_and_args cmd args =
  `Assoc [ ("cmd", `String cmd);
           ("args", `List (List.map (fun s -> `String s) args)) ]

let mk_action action =
  `Assoc [ ("action", `String action) ]

(* ================================================================ *)
(* Read-only subcommands via cmd                                     *)
(* ================================================================ *)

let test_read_only_cmd_prefixes () =
  let read_only_cmds =
    [ "pr list"; "pr list --state open"; "pr view 123";
      "pr diff 123"; "pr checks 123"; "pr status";
      "issue list"; "issue view 456"; "issue status";
      "repo view owner/repo"; "repo list";
      "release list"; "release view v1.0" ]
  in
  List.iter (fun cmd ->
    Alcotest.(check bool)
      (Printf.sprintf "read-only cmd: %s" cmd)
      true
      (is_ro ~tool_name:"keeper_github" ~input:(mk_cmd cmd))
  ) read_only_cmds

let test_read_only_case_insensitive () =
  Alcotest.(check bool) "PR LIST uppercase"
    true (is_ro ~tool_name:"keeper_github" ~input:(mk_cmd "PR LIST"));
  Alcotest.(check bool) "Pr View mixed"
    true (is_ro ~tool_name:"keeper_github" ~input:(mk_cmd "Pr View 123"))

(* ================================================================ *)
(* Read-only subcommands via args                                    *)
(* ================================================================ *)

let test_read_only_via_args () =
  let read_only_args =
    [ ["pr"; "list"];
      ["pr"; "view"; "123"];
      ["pr"; "diff"; "123"];
      ["issue"; "list"];
      ["issue"; "view"; "456"];
      ["repo"; "view"; "owner/repo"];
      ["release"; "list"] ]
  in
  List.iter (fun args ->
    Alcotest.(check bool)
      (Printf.sprintf "read-only args: [%s]" (String.concat "; " args))
      true
      (is_ro ~tool_name:"keeper_github" ~input:(mk_args args))
  ) read_only_args

let test_cmd_takes_precedence_over_args () =
  (* When cmd is present and non-empty, args are ignored *)
  Alcotest.(check bool) "cmd=mutating overrides read-only args"
    false
    (is_ro ~tool_name:"keeper_github"
       ~input:(mk_cmd_and_args "pr merge 123" ["pr"; "list"]));
  Alcotest.(check bool) "cmd=read-only overrides mutating args"
    true
    (is_ro ~tool_name:"keeper_github"
       ~input:(mk_cmd_and_args "pr list" ["pr"; "merge"; "123"]))

(* ================================================================ *)
(* Mutating subcommands                                              *)
(* ================================================================ *)

let test_mutating_cmds_not_read_only () =
  let mutating_cmds =
    [ "pr merge 123"; "pr close 123"; "pr create --title 'fix'";
      "pr edit 123 --title 'new'"; "pr comment 123 --body 'ok'";
      "issue create --title 'bug'"; "issue close 456";
      "issue comment 456 --body 'noted'";
      "gist create file.txt"; "workflow run deploy.yml" ]
  in
  List.iter (fun cmd ->
    Alcotest.(check bool)
      (Printf.sprintf "mutating cmd: %s" cmd)
      false
      (is_ro ~tool_name:"keeper_github" ~input:(mk_cmd cmd))
  ) mutating_cmds

(* ================================================================ *)
(* gh api classification                                             *)
(* ================================================================ *)

let test_api_get_default_is_read_only () =
  let read_only_api =
    [ "api repos/owner/repo/pulls";
      "api repos/owner/repo/pulls/123/comments";
      "api /repos/o/r/issues";
      "api -X GET repos/owner/repo" ]
  in
  List.iter (fun cmd ->
    Alcotest.(check bool)
      (Printf.sprintf "api read-only: %s" cmd)
      true
      (is_ro ~tool_name:"keeper_github" ~input:(mk_cmd cmd))
  ) read_only_api

let test_api_with_method_flag_is_mutating () =
  let mutating_api =
    [ "api -X POST /repos/o/r/pulls/1/merge";
      "api -X PUT /repos/o/r/pulls/1/merge";
      "api -X PATCH /repos/o/r/pulls/1 -f state=closed";
      "api -X DELETE repos/owner/repo/issues/1";
      "api --method POST /repos/o/r/merges";
      "api --method=POST /repos/o/r/pulls/1/merge";
      "api -x=put /repos/o/r/pulls/1/merge" ]
  in
  List.iter (fun cmd ->
    Alcotest.(check bool)
      (Printf.sprintf "api mutating method: %s" cmd)
      false
      (is_ro ~tool_name:"keeper_github" ~input:(mk_cmd cmd))
  ) mutating_api

let test_api_with_field_flag_is_mutating () =
  let field_api =
    [ "api /repos/o/r/pulls/1/merge -f sha=abc123";
      "api /repos/o/r/merges -F base=main -F head=feat";
      "api /repos/o/r/merges --field=base=main" ]
  in
  List.iter (fun cmd ->
    Alcotest.(check bool)
      (Printf.sprintf "api field flag mutating: %s" cmd)
      false
      (is_ro ~tool_name:"keeper_github" ~input:(mk_cmd cmd))
  ) field_api

let test_api_graphql_is_mutating () =
  let graphql_cmds =
    [ "api graphql -f query=repository";
      "api graphql -f query=mergePullRequest" ]
  in
  List.iter (fun cmd ->
    Alcotest.(check bool)
      (Printf.sprintf "api graphql mutating: %s" cmd)
      false
      (is_ro ~tool_name:"keeper_github" ~input:(mk_cmd cmd))
  ) graphql_cmds

(* ================================================================ *)
(* Edge cases                                                        *)
(* ================================================================ *)

let test_empty_input_not_read_only () =
  Alcotest.(check bool) "empty cmd"
    false (is_ro ~tool_name:"keeper_github" ~input:(mk_cmd ""));
  Alcotest.(check bool) "whitespace cmd"
    false (is_ro ~tool_name:"keeper_github" ~input:(mk_cmd "   "));
  Alcotest.(check bool) "empty args"
    false (is_ro ~tool_name:"keeper_github" ~input:(mk_args []));
  Alcotest.(check bool) "no cmd or args"
    false (is_ro ~tool_name:"keeper_github" ~input:(`Assoc []))

let test_non_keeper_github_tool () =
  (* keeper_bash has_mutating_side_effect=true, so it should not be
     classified as read-only even if the cmd looks like a gh read-only cmd *)
  Alcotest.(check bool) "keeper_bash is not affected"
    false
    (is_ro ~tool_name:"keeper_bash" ~input:(mk_cmd "pr list"));
  (* keeper_board_post is mutating (not read-only) but boundary-exempt *)
  Alcotest.(check bool) "keeper_board_post is not read-only"
    false
    (is_ro ~tool_name:"keeper_board_post" ~input:(mk_cmd "pr list"))

let test_api_via_args () =
  Alcotest.(check bool) "api GET via args"
    true
    (is_ro ~tool_name:"keeper_github"
       ~input:(mk_args ["api"; "repos/owner/repo/pulls"]));
  Alcotest.(check bool) "api POST via args"
    false
    (is_ro ~tool_name:"keeper_github"
       ~input:(mk_args ["api"; "-X"; "POST"; "/repos/o/r/pulls/1/merge"]))

(* ================================================================ *)
(* Main-worktree mutation-boundary exemptions                        *)
(* ================================================================ *)

let test_task_claim_is_mutating_but_boundary_exempt () =
  Alcotest.(check bool) "task claim is not read-only"
    false
    (is_ro ~tool_name:"keeper_task_claim" ~input:(`Assoc []));
  Alcotest.(check bool) "task claim bypasses boundary"
    true
    (is_boundary_exempt ~tool_name:"keeper_task_claim" ~input:(`Assoc []))

let test_masc_code_git_write_actions_bypass_boundary () =
  List.iter
    (fun action ->
      Alcotest.(check bool)
        (Printf.sprintf "git %s is mutating" action)
        false
        (is_ro ~tool_name:"masc_code_git" ~input:(mk_action action));
      Alcotest.(check bool)
        (Printf.sprintf "git %s bypasses boundary" action)
        true
        (is_boundary_exempt ~tool_name:"masc_code_git" ~input:(mk_action action)))
    [ "add"; "commit"; "push" ]

let test_keeper_bash_still_opens_boundary () =
  Alcotest.(check bool) "keeper_bash not exempt"
    false
    (is_boundary_exempt ~tool_name:"keeper_bash" ~input:(mk_cmd "git status"))

(* Regression: [masc_] prefix coordination aliases for [keeper_] prefix
   tools were missing from [is_main_worktree_boundary_exempt_with_input]
   in main until #6671, causing masc_improver to hang mid-turn after
   [masc_add_task] opened the boundary and [masc_claim_next] was
   blocked.  Lock the [masc_] and [keeper_] families to the same
   exemption semantics so the next rename does not silently drift. *)
let test_masc_coordination_aliases_bypass_boundary () =
  let check_pair name =
    Alcotest.(check bool) (name ^ " is mutating") false
      (is_ro ~tool_name:name ~input:(`Assoc []));
    Alcotest.(check bool) (name ^ " bypasses boundary") true
      (is_boundary_exempt ~tool_name:name ~input:(`Assoc []))
  in
  List.iter check_pair
    [ "masc_tasks"; "masc_add_task"; "masc_claim_next";
      "masc_batch_add_tasks"; "masc_plan_init"; "masc_plan_set_task";
      "masc_plan_update"; "masc_plan_get"; "masc_transition";
      "masc_broadcast"; "masc_messages"; "masc_status";
      "masc_dashboard"; "masc_agents"; "masc_agent_card";
      "masc_board_post"; "masc_board_comment"; "masc_board_vote";
      "masc_board_comment_vote"; "masc_board_delete";
      "masc_board_list"; "masc_board_get"; "masc_board_stats";
      "masc_board_hearths"; "masc_board_profile" ]

(* ================================================================ *)
(* Runner                                                            *)
(* ================================================================ *)

let () =
  Alcotest.run "Keeper github read-only boundary"
    [
      ( "read_only_cmd",
        [
          Alcotest.test_case "read-only cmd prefixes" `Quick
            test_read_only_cmd_prefixes;
          Alcotest.test_case "case insensitive" `Quick
            test_read_only_case_insensitive;
        ] );
      ( "read_only_args",
        [
          Alcotest.test_case "read-only via args field" `Quick
            test_read_only_via_args;
          Alcotest.test_case "cmd takes precedence over args" `Quick
            test_cmd_takes_precedence_over_args;
        ] );
      ( "mutating_cmds",
        [
          Alcotest.test_case "mutating cmds not read-only" `Quick
            test_mutating_cmds_not_read_only;
        ] );
      ( "gh_api",
        [
          Alcotest.test_case "api GET default is read-only" `Quick
            test_api_get_default_is_read_only;
          Alcotest.test_case "api with -X method is mutating" `Quick
            test_api_with_method_flag_is_mutating;
          Alcotest.test_case "api with -f/-F is mutating" `Quick
            test_api_with_field_flag_is_mutating;
          Alcotest.test_case "api graphql is mutating" `Quick
            test_api_graphql_is_mutating;
        ] );
      ( "edge_cases",
        [
          Alcotest.test_case "empty input not read-only" `Quick
            test_empty_input_not_read_only;
          Alcotest.test_case "non-keeper_github tool" `Quick
            test_non_keeper_github_tool;
          Alcotest.test_case "api via args" `Quick
            test_api_via_args;
          Alcotest.test_case "task claim mutating but boundary exempt" `Quick
            test_task_claim_is_mutating_but_boundary_exempt;
          Alcotest.test_case "masc_code_git write actions bypass boundary" `Quick
            test_masc_code_git_write_actions_bypass_boundary;
          Alcotest.test_case "keeper_bash still opens boundary" `Quick
            test_keeper_bash_still_opens_boundary;
          Alcotest.test_case "masc_* coordination aliases bypass boundary" `Quick
            test_masc_coordination_aliases_bypass_boundary;
        ] );
    ]
