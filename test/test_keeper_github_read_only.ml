(** Tests for [Keeper_tool_registry.is_read_only_with_input].

    Validates input-aware read-only classification for keeper_shell op=gh:
    1. Read-only gh subcommands (pr list, issue view, etc.) via cmd
    2. Mutating gh subcommands are not classified as read-only
    3. gh api GET (default) is read-only
    4. gh api with -X POST/PUT/DELETE is mutating
    5. gh api with -f/-F (implicit POST) is mutating
    6. gh api graphql is mutating (always POST)
    7. Edge cases: empty input, non-gh tools, whitespace *)

open Masc_mcp

let is_ro ~tool_name ~input =
  Keeper_tool_registry.is_read_only_with_input ~tool_name ~input

let has_side_effect ~tool_name ~input =
  Keeper_exec_tools.has_mutating_side_effect_with_input ~tool_name ~input

let is_boundary_exempt ~tool_name ~input =
  Keeper_tool_registry.is_main_worktree_boundary_exempt_with_input
    ~tool_name ~input

let mk_cmd cmd =
  `Assoc [ ("op", `String "gh"); ("cmd", `String cmd) ]

(* Legacy helpers for backward compat with older tests (not exercised;
   keeper_shell op=gh only accepts cmd, not args). *)
let mk_args args =
  `Assoc [ ("op", `String "gh");
           ("cmd", `String (String.concat " " args)) ]

let mk_cmd_and_args cmd _args =
  `Assoc [ ("op", `String "gh"); ("cmd", `String cmd) ]

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
      (is_ro ~tool_name:"keeper_shell" ~input:(mk_cmd cmd))
  ) read_only_cmds

let test_read_only_case_insensitive () =
  Alcotest.(check bool) "PR LIST uppercase"
    true (is_ro ~tool_name:"keeper_shell" ~input:(mk_cmd "PR LIST"));
  Alcotest.(check bool) "Pr View mixed"
    true (is_ro ~tool_name:"keeper_shell" ~input:(mk_cmd "Pr View 123"))

let test_prefixed_gh_command_normalization () =
  Alcotest.(check (option int)) "prefixed gh parser still finds PR number"
    (Some 123)
    (match Keeper_gh_shared.extract_gh_target_number "gh pr view 123" with
     | Some (Keeper_gh_shared.PR, n) -> Some n
     | _ -> None);
  Alcotest.(check (option string)) "prefixed gh parser still finds mutation"
    (Some "pr")
    (match Keeper_gh_shared.gh_mutates_entity "gh pr merge 123" with
     | Some Keeper_gh_shared.PR -> Some "pr"
     | Some Keeper_gh_shared.Issue -> Some "issue"
     | None -> None);
  Alcotest.(check bool) "prefixed gh command stays read-only"
    true
    (is_ro ~tool_name:"keeper_shell" ~input:(mk_cmd "gh pr list --state open"));
  Alcotest.(check bool) "prefixed gh merge stays mutating"
    true
    (has_side_effect ~tool_name:"keeper_shell" ~input:(mk_cmd "gh pr merge 123"))

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
      (is_ro ~tool_name:"keeper_shell" ~input:(mk_args args))
  ) read_only_args

let test_cmd_takes_precedence_over_args () =
  (* When cmd is present and non-empty, args are ignored *)
  Alcotest.(check bool) "cmd=mutating overrides read-only args"
    false
    (is_ro ~tool_name:"keeper_shell"
       ~input:(mk_cmd_and_args "pr merge 123" ["pr"; "list"]));
  Alcotest.(check bool) "cmd=read-only overrides mutating args"
    true
    (is_ro ~tool_name:"keeper_shell"
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
      (is_ro ~tool_name:"keeper_shell" ~input:(mk_cmd cmd))
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
      (is_ro ~tool_name:"keeper_shell" ~input:(mk_cmd cmd))
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
      (is_ro ~tool_name:"keeper_shell" ~input:(mk_cmd cmd))
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
      (is_ro ~tool_name:"keeper_shell" ~input:(mk_cmd cmd))
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
      (is_ro ~tool_name:"keeper_shell" ~input:(mk_cmd cmd))
  ) graphql_cmds

(* ================================================================ *)
(* Edge cases                                                        *)
(* ================================================================ *)

let test_empty_input_not_read_only () =
  (* With op=gh but empty cmd, we cannot classify — treat as mutating. *)
  Alcotest.(check bool) "empty cmd"
    false (is_ro ~tool_name:"keeper_shell" ~input:(mk_cmd ""));
  Alcotest.(check bool) "whitespace cmd"
    false (is_ro ~tool_name:"keeper_shell" ~input:(mk_cmd "   "));
  Alcotest.(check bool) "empty args"
    false (is_ro ~tool_name:"keeper_shell" ~input:(mk_args []));
  (* Without op=gh (or any op), keeper_shell falls back to its default
     read-only classification from shard_shell.read_only_tools.
     Tools calling keeper_shell without an op are malformed but harmless
     — they get the safe default. *)
  Alcotest.(check bool) "no op (falls back to default read-only)"
    true (is_ro ~tool_name:"keeper_shell" ~input:(`Assoc []))

let test_non_gh_tool () =
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
    (is_ro ~tool_name:"keeper_shell"
       ~input:(mk_args ["api"; "repos/owner/repo/pulls"]));
  Alcotest.(check bool) "api POST via args"
    false
    (is_ro ~tool_name:"keeper_shell"
       ~input:(mk_args ["api"; "-X"; "POST"; "/repos/o/r/pulls/1/merge"]))

let test_input_aware_mutation_detection () =
  Alcotest.(check bool) "keeper_shell op=gh read-only cmd is not mutating"
    false
    (has_side_effect ~tool_name:"keeper_shell" ~input:(mk_cmd "pr list"));
  Alcotest.(check bool) "keeper_shell op=gh merge cmd is mutating"
    true
    (has_side_effect ~tool_name:"keeper_shell" ~input:(mk_cmd "pr merge 123"));
  Alcotest.(check bool) "masc_code_git status is not mutating"
    false
    (has_side_effect ~tool_name:"masc_code_git" ~input:(mk_action "status"));
  Alcotest.(check bool) "masc_code_git commit is mutating"
    true
    (has_side_effect ~tool_name:"masc_code_git" ~input:(mk_action "commit"))

let test_tool_call_observer_receives_keeper_context () =
  let seen = ref None in
  let observer ~keeper_name ~tool_name ~input ~success =
    seen := Some (keeper_name, tool_name, input, success)
  in
  Keeper_exec_tools.add_tool_call_observer observer;
  Fun.protect
    ~finally:(fun () -> Keeper_exec_tools.remove_tool_call_observer observer)
    (fun () ->
      let input = mk_cmd "pr list" in
      Keeper_exec_tools.notify_tool_call_observers
        ~keeper_name:"keeper-a"
        ~tool_name:"keeper_shell"
        ~input
        ~success:true;
      match !seen with
      | Some (keeper_name, tool_name, observed_input, success) ->
          Alcotest.(check string) "keeper name" "keeper-a" keeper_name;
          Alcotest.(check string) "tool name" "keeper_shell" tool_name;
          Alcotest.(check bool) "success flag" true success;
          Alcotest.(check string) "input payload"
            (Yojson.Safe.to_string input)
            (Yojson.Safe.to_string observed_input)
      | None ->
          Alcotest.fail "expected observer notification")

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

(* Regression: [keeper_board_delete] and [keeper_board_cleanup] were
   missing from the [keeper_*] side of the exempt list even though
   their [masc_*] coordination alias [masc_board_delete] was already
   exempt at line 283 of [keeper_tool_registry.ml].  Observed 2026-04-12
   01:15:25 KST on janitor: the first [keeper_board_delete] of a cleanup
   turn succeeded and opened the mutation boundary, and every subsequent
   [keeper_board_delete] in the same turn was blocked by the
   [pre_tool_use_guard] — burning janitor's turn budget on a repeating
   "tool skipped" loop instead of progressing through the cleanup queue.
   Same structural gap class as #6671 / #6681.

   Board delete and cleanup are MASC-state-only mutations (board post
   store), not main-worktree writes, so multiple deletes per turn are
   safe.  This test locks the exemption so the next rename does not
   silently drift the [keeper_*] side out of sync with [masc_*]. *)
let test_keeper_board_delete_and_cleanup_bypass_boundary () =
  let check name =
    Alcotest.(check bool) (name ^ " is mutating") false
      (is_ro ~tool_name:name ~input:(`Assoc []));
    Alcotest.(check bool) (name ^ " bypasses boundary") true
      (is_boundary_exempt ~tool_name:name ~input:(`Assoc []))
  in
  List.iter check
    [ "keeper_board_delete"; "keeper_board_cleanup" ]

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
          Alcotest.test_case "prefixed gh command normalization" `Quick
            test_prefixed_gh_command_normalization;
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
          Alcotest.test_case "non-gh tool" `Quick
            test_non_gh_tool;
          Alcotest.test_case "api via args" `Quick
            test_api_via_args;
          Alcotest.test_case "input-aware mutation detection" `Quick
            test_input_aware_mutation_detection;
          Alcotest.test_case "tool observer receives keeper context" `Quick
            test_tool_call_observer_receives_keeper_context;
          Alcotest.test_case "task claim mutating but boundary exempt" `Quick
            test_task_claim_is_mutating_but_boundary_exempt;
          Alcotest.test_case "masc_code_git write actions bypass boundary" `Quick
            test_masc_code_git_write_actions_bypass_boundary;
          Alcotest.test_case "keeper_bash still opens boundary" `Quick
            test_keeper_bash_still_opens_boundary;
          Alcotest.test_case "masc_* coordination aliases bypass boundary" `Quick
            test_masc_coordination_aliases_bypass_boundary;
          Alcotest.test_case "keeper_board_delete and cleanup bypass boundary" `Quick
            test_keeper_board_delete_and_cleanup_bypass_boundary;
        ] );
    ]
