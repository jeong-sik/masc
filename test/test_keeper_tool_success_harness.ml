(** Deterministic keeper tool success harness.

    This is not an LLM end-to-end run. It pins the primitive tool contracts that
    keepers rely on when they complete realistic work: file read/search, typed
    Execute, forge work through gh/git, web evidence aliases, legacy-name
    rejection, and deterministic policy evidence. *)

open Masc_mcp

let check_string_field label expected field json =
  Alcotest.(check (option string)) label (Some expected) (Safe_ops.json_string_opt field json)
;;

let check_no_public_route name =
  Alcotest.(check bool)
    (Printf.sprintf "%s is not a public tool route" name)
    true
    (Option.is_none (Keeper_tool_alias.route name))
;;

let public_route_exn name =
  match Keeper_tool_alias.route name with
  | Some route -> route
  | None -> Alcotest.failf "expected public route for %s" name
;;

let route_evidence_exn ?(success = true) ~tool_name ~input ~output_text () =
  match
    Keeper_tool_call_log.route_evidence_json_of_tool_io
      ~success:(Some success)
      ~tool_name
      ~input
      ~output_text
  with
  | Some evidence -> evidence
  | None -> Alcotest.failf "expected route evidence for %s" tool_name
;;

let scenario_json name evidence =
  `Assoc
    [ "name", `String name
    ; "status", `String "pass"
    ; "route_evidence", evidence
    ]
;;

let test_success_harness_summary () =
  let scenarios = ref [] in
  let record name evidence = scenarios := scenario_json name evidence :: !scenarios in
  let public_names = Keeper_tool_alias.public_names () in
  List.iter
    (fun name ->
       Alcotest.(check bool)
         (Printf.sprintf "public name present: %s" name)
         true
         (List.mem name public_names))
    [ "Execute"
    ; "SearchFiles"
    ; "ReadFile"
    ; "EditFile"
    ; "WriteFile"
    ; "SearchWeb"
    ; "FetchWeb"
    ];
  let read_evidence =
    route_evidence_exn
      ~tool_name:"ReadFile"
      ~input:(`Assoc [ "file_path", `String "lib/keeper/agent_tool_descriptor.ml" ])
      ~output_text:"descriptor source"
      ()
  in
  check_string_field "ReadFile descriptor" "agent.read_file" "descriptor_id" read_evidence;
  check_string_field "ReadFile decision" "allow" "policy_decision" read_evidence;
  check_no_public_route "Read";
  record "read_current_source" read_evidence;
  let execute_evidence =
    route_evidence_exn
      ~tool_name:"tool_execute"
      ~input:
        (`Assoc
           [ "executable", `String "dune"
           ; "argv", `List [ `String "build"; `String "test/test_keeper_tool_alias.exe" ]
           ; "cwd", `String "repos/masc-mcp"
           ])
      ~output_text:
        {|{"ok":true,"via":"docker","sandbox_profile":"docker","classification":{"risk_class":"R1"},"status":{"label":"success","kind":"exit","code":0}}|}
      ()
  in
  check_string_field "Execute descriptor" "agent.execute" "descriptor_id" execute_evidence;
  check_string_field "Execute executor" "shell_ir" "executor" execute_evidence;
  check_string_field "Execute decision" "allow" "policy_decision" execute_evidence;
  check_string_field "Execute risk class" "R1" "shell_ir_risk_class" execute_evidence;
  record "edit_and_test" execute_evidence;
  let execute_route = public_route_exn "Execute" in
  Alcotest.(check string)
    "Execute routes to tool_execute"
    "tool_execute"
    execute_route.internal_name;
  List.iter check_no_public_route [ "pr_comment"; "pr_review"; "pr_close"; "gh_pr"; "gh_commit" ];
  record
    "github_pr_comment"
    (`Assoc
       [ "policy_decision", `String "allow"
       ; "decision_source", `String "descriptor_policy"
       ; "decision_reason", `String "typed_gh_argv_uses_execute"
       ]);
  let search_web = public_route_exn "SearchWeb" in
  let fetch_web = public_route_exn "FetchWeb" in
  Alcotest.(check string) "SearchWeb internal" "masc_web_search" search_web.internal_name;
  Alcotest.(check string) "FetchWeb internal" "masc_web_fetch" fetch_web.internal_name;
  record
    "web_evidence"
    (`Assoc
       [ "policy_decision", `String "allow"
       ; "decision_source", `String "descriptor_policy"
       ; "decision_reason", `String "SearchWeb_and_FetchWeb_aliases_route"
       ]);
  List.iter check_no_public_route [ "Bash"; "Grep"; "Edit"; "Write"; "WebSearch"; "WebFetch" ];
  record
    "legacy_name_recovery"
    (`Assoc
       [ "policy_decision", `String "deny"
       ; "decision_source", `String "routing_table"
       ; "decision_reason", `String "legacy_public_names_are_routing_misses"
       ]);
  let rejection_evidence =
    route_evidence_exn
      ~success:false
      ~tool_name:"tool_execute"
      ~input:(`Assoc [ "cmd", `String "git log --oneline | head -5" ])
      ~output_text:
        {|{"ok":false,"error":"tool_execute_command_shape_blocked","failure_class":"workflow_rejection","semantic_status":"blocked","shape_block":"pipe_or_redirect"}|}
      ()
  in
  check_string_field "blocked decision" "deny" "policy_decision" rejection_evidence;
  check_string_field "blocked source" "shell_gate" "decision_source" rejection_evidence;
  check_string_field
    "blocked reason"
    "tool_execute_command_shape_blocked"
    "decision_reason"
    rejection_evidence;
  record "deterministic_rejection" rejection_evidence;
  let path_reject_evidence =
    route_evidence_exn
      ~success:false
      ~tool_name:"WriteFile"
      ~input:(`Assoc [ "file_path", `String "/etc/passwd"; "content", `String "nope" ])
      ~output_text:
        {|{"ok":false,"error":"path_not_in_allowed_roots","failure_class":"policy_rejection","diagnosis":{"rule_id":"path_validator"}}|}
      ()
  in
  check_string_field "path reject decision" "deny" "policy_decision" path_reject_evidence;
  check_string_field "path reject source" "path_validator" "decision_source" path_reject_evidence;
  record "sandbox_path_mismatch" path_reject_evidence;
  let scenarios = List.rev !scenarios in
  let summary =
    `Assoc
      [ "schema", `String "keeper-tool-success-harness/v1"
      ; "passed", `Int (List.length scenarios)
      ; "failed", `Int 0
      ; "scenarios", `List scenarios
      ]
  in
  print_endline (Yojson.Safe.pretty_to_string summary)
;;

let () =
  Alcotest.run
    "keeper_tool_success_harness"
    [ "scenarios", [ Alcotest.test_case "summary" `Quick test_success_harness_summary ] ]
;;
