module Types = Masc_domain

(** Goal tool coverage — shared Goal Store surface through Tool_workspace. *)

open Alcotest
open Masc
open Workspace_types
open Tool_workspace

let has_prompt_root path =
  Sys.file_exists
    (Filename.concat path "config/prompts/verification.goal_completion.md")
;;

let repo_root () =
  match Sys.getenv_opt "DUNE_SOURCEROOT" with
  | Some root when has_prompt_root root -> root
  | _ ->
    let rec ascend path =
      if has_prompt_root path
      then path
      else
        let parent = Filename.dirname path in
        if String.equal parent path then Sys.getcwd () else ascend parent
    in
    ascend (Sys.getcwd ())
;;

let goal_reviewer_run
  : (string ->
     ( Goal_completion_reviewer.verdict option
     , Agent_sdk.Error.sdk_error )
       result)
      ref
  =
  ref (fun (_prompt : string) ->
    Ok (Some Goal_completion_reviewer.Approve))
;;

let () =
  Prompt_registry.set_markdown_dir
    (Filename.concat (repo_root ()) "config/prompts");
  Prompt_defaults.init ();
  Atomic.set Workspace_hooks.get_cross_verifier_runtime_id_fn (fun () ->
    Some "test.goal-completion-reviewer");
  Atomic.set
    Goal_completion_reviewer.run_llm_reviewer_fn
    (fun ?sw:_ ~evaluator_runtime:_ ~prompt ~report_tool_schema:_ () ->
       !goal_reviewer_run prompt)
;;

let temp_dir () =
  let path = Filename.temp_file "goal_tool_test" "" in
  Sys.remove path;
  Unix.mkdir path 0o755;
  path
;;

let rm_rf dir =
  let rec rm path =
    if Sys.file_exists path
    then
      if Sys.is_directory path
      then (
        Sys.readdir path |> Array.iter (fun entry -> rm (Filename.concat path entry));
        Unix.rmdir path)
      else Sys.remove path
  in
  try rm dir with
  | _ -> ()
;;

let with_workspace f =
  Eio_main.run
  @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let dir = temp_dir () in
  Fun.protect
    ~finally:(fun () -> rm_rf dir)
    (fun () ->
       let config = Workspace.default_config dir in
       ignore (Workspace.init config ~agent_name:(Some "planner"));
       f config)
;;

let workspace_ctx ?(agent_name = "planner") config : Tool_workspace.context =
  { Tool_workspace.config; agent_name }
;;

let parse_json_result (result : Tool_result.result) =
  if (Tool_result.is_success result)
  then Yojson.Safe.from_string ((Tool_result.message result))
  else Alcotest.fail ((Tool_result.message result))
;;

let get_string_field json field =
  match Yojson.Safe.Util.member field json with
  | `String value -> value
  | _ -> fail (field ^ " missing")
;;

let contains_substring s needle =
  let s_len = String.length s in
  let n_len = String.length needle in
  let rec loop i =
    if n_len = 0
    then true
    else if i + n_len > s_len
    then false
    else if String.sub s i n_len = needle
    then true
    else loop (i + 1)
  in
  loop 0
;;

let expect_error (result : Tool_result.result option) =
  match result with
  | Some r when not (Tool_result.is_success r) -> Yojson.Safe.from_string ((Tool_result.message r))
  | Some r ->
    fail (Printf.sprintf "expected tool error, got success: %s" ((Tool_result.message r)))
  | None -> fail "tool not handled"
;;

let test_goal_upsert_and_list () =
  with_workspace
  @@ fun config ->
  let created =
    Tool_workspace.dispatch
      (workspace_ctx config)
      ~name:"masc_goal_upsert"
      ~args:
        (`Assoc
            [ "title", `String "Ship Goal Surface"
            ; "priority", `Int 2
            ])
  in
  let created_json =
    match created with
    | Some result -> parse_json_result result
    | None -> fail "masc_goal_upsert not handled"
  in
  let goal_id =
    match Yojson.Safe.Util.member "goal_id" created_json with
    | `String id when id <> "" -> id
    | _ -> fail "goal_id missing from upsert response"
  in
  check bool "goal_id populated" true (String.length goal_id > 0);
  let task_link_field =
    match Yojson.Safe.Util.member "task_link_field" created_json with
    | `String field -> field
    | _ -> fail "task_link_field missing from upsert response"
  in
  check string "structured link field" "goal_id" task_link_field;
  check string "structured link mode" "structured_goal_id"
    (Yojson.Safe.Util.member "task_link_mode" created_json
     |> Yojson.Safe.Util.to_string);
  check bool "title marker omitted" true
    (Yojson.Safe.Util.member "task_title_marker" created_json = `Null);
  let listed =
    Tool_workspace.dispatch
      (workspace_ctx config)
      ~name:"masc_goal_list"
      ~args:(`Assoc [])
  in
  let listed_json =
    match listed with
    | Some result -> parse_json_result result
    | None -> fail "masc_goal_list not handled"
  in
  let count =
    match Yojson.Safe.Util.member "count" listed_json with
    | `Int n -> n
    | _ -> fail "count missing from goal list response"
  in
  check int "one listed goal" 1 count;
  let goals = Yojson.Safe.Util.member "goals" listed_json |> Yojson.Safe.Util.to_list in
  match goals with
  | [ goal_json ] -> check string "listed goal id" goal_id (get_string_field goal_json "id")
  | _ -> fail "expected one listed goal"
;;

let test_goal_list_filters_by_phase () =
  with_workspace
  @@ fun config ->
  let create ~title ~phase =
    let phase =
      match Goal_phase.parse phase with
      | Some phase -> phase
      | None -> fail ("invalid phase fixture: " ^ phase)
    in
    match Goal_store.upsert_goal config ~title () with
    | Error msg -> fail msg
    | Ok (goal, _) ->
      (match
         Goal_store.update_goal config ~goal_id:goal.id (fun current ->
           { current with phase })
       with
       | Ok _ -> ()
       | Error msg -> fail msg)
  in
  create ~title:"Executing goal" ~phase:"executing";
  create ~title:"Blocked goal" ~phase:"blocked";
  let listed =
    Tool_workspace.dispatch
      (workspace_ctx config)
      ~name:"masc_goal_list"
      ~args:(`Assoc [ "phase", `String "blocked" ])
  in
  let listed_json =
    match listed with
    | Some result -> parse_json_result result
    | None -> fail "masc_goal_list not handled"
  in
  let goals = Yojson.Safe.Util.member "goals" listed_json |> Yojson.Safe.Util.to_list in
  check int "one listed goal by phase" 1 (List.length goals);
  match goals with
  | [ goal_json ] ->
    check string "phase filter honored" "blocked" (get_string_field goal_json "phase")
  | _ -> fail "expected one filtered goal"
;;

let test_goal_list_includes_rollup () =
  with_workspace
  @@ fun config ->
  (match Goal_store.upsert_goal config ~title:"Executing goal" () with
   | Ok _ -> ()
   | Error msg -> fail msg);
  let listed =
    Tool_workspace.dispatch
      (workspace_ctx config)
      ~name:"masc_goal_list"
      ~args:(`Assoc [])
  in
  let listed_json =
    match listed with
    | Some result -> parse_json_result result
    | None -> fail "masc_goal_list not handled"
  in
  let rollup = Yojson.Safe.Util.member "rollup" listed_json in
  check int "active goal is counted" 1
    (Yojson.Safe.Util.member "active_count" rollup |> Yojson.Safe.Util.to_int)
;;
let test_goal_list_ignores_blank_optional_filters () =
  with_workspace
  @@ fun config ->
  (match Goal_store.upsert_goal config ~title:"Blank filter goal" () with
   | Ok _ -> ()
   | Error msg -> fail msg);
  let listed =
    Tool_workspace.dispatch
      (workspace_ctx config)
      ~name:"masc_goal_list"
      ~args:(`Assoc [ "phase", `String "" ])
  in
  let listed_json =
    match listed with
    | Some result -> parse_json_result result
    | None -> fail "masc_goal_list not handled"
  in
  check
    int
    "blank filters are ignored"
    1
    (Yojson.Safe.Util.member "count" listed_json |> Yojson.Safe.Util.to_int)
;;

let test_goal_list_rejects_status_filter () =
  with_workspace
  @@ fun config ->
  let rejected =
    Tool_workspace.dispatch
      (workspace_ctx config)
      ~name:"masc_goal_list"
      ~args:(`Assoc [ "status", `String "active" ])
  in
  let error_json = expect_error rejected in
  check
    string
    "status filter blocked"
    "validation_error"
    (get_string_field error_json "error_code");
  check
    bool
    "error points to removed status"
    true
    (contains_substring (Yojson.Safe.to_string error_json) "status filter was removed");
  let field_errors =
    Yojson.Safe.Util.member "field_errors" error_json |> Yojson.Safe.Util.to_list
  in
  match field_errors with
  | field_error :: _ ->
    check string "field" "status" (get_string_field field_error "field")
  | [] -> fail "expected status field error"
;;

let test_goal_upsert_rejects_lifecycle_fields () =
  with_workspace
  @@ fun config ->
  let rejected_phase =
    Tool_workspace.dispatch
      (workspace_ctx config)
      ~name:"masc_goal_upsert"
      ~args:(`Assoc [ "title", `String "Bypass block"; "phase", `String "blocked" ])
  in
  let phase_error = expect_error rejected_phase in
  check
    string
    "phase blocked"
    "validation_error"
    (get_string_field phase_error "error_code");
  check
    bool
    "phase error points at transition"
    true
    (contains_substring (Yojson.Safe.to_string phase_error) "masc_goal_transition");
  let goal, _kind =
    match Goal_store.upsert_goal config ~title:"Existing goal" () with
    | Ok payload -> payload
    | Error msg -> fail msg
  in
  let rejected_status =
    Tool_workspace.dispatch
      (workspace_ctx config)
      ~name:"masc_goal_upsert"
      ~args:(`Assoc [ "id", `String goal.id; "status", `String "dropped" ])
  in
  let status_error = expect_error rejected_status in
  check
    string
    "terminal status blocked"
    "validation_error"
    (get_string_field status_error "error_code");
  let saved_goal =
    match Goal_store.get_goal config ~goal_id:goal.id with
    | Some goal -> goal
    | None -> fail "goal missing after rejected upsert"
  in
  check
    string
    "phase unchanged after rejected status"
    "executing"
    (Goal_phase.to_string saved_goal.phase)
;;

let test_goal_review_removed_from_dispatch () =
  with_workspace
  @@ fun config ->
  let result =
    Tool_workspace.dispatch
      (workspace_ctx config)
      ~name:"masc_goal_review"
      ~args:(`Assoc [ "goal_id", `String "goal-legacy"; "outcome", `String "done" ])
  in
  check bool "masc_goal_review removed" true (Option.is_none result)
;;

let transition_phase result =
  match result with
  | Some result ->
    parse_json_result result
    |> Yojson.Safe.Util.member "goal"
    |> fun json -> get_string_field json "phase"
  | None -> fail "masc_goal_transition not handled"
;;

let request_complete ?note config goal_id =
  let fields =
    [ "goal_id", `String goal_id
    ; "action", `String "request_complete"
    ]
    @
    match note with
    | Some note -> [ "note", `String note ]
    | None -> []
  in
  Tool_workspace.dispatch
    (workspace_ctx config)
    ~name:"masc_goal_transition"
    ~args:(`Assoc fields)
;;

let current_goal config goal_id =
  match Goal_store.get_goal config ~goal_id with
  | Some goal -> goal
  | None -> fail "goal disappeared"
;;

let test_goal_completion_verdict_parser_is_exact () =
  let expect_invalid label json =
    match Goal_completion_reviewer.parse_verdict_from_json json with
    | Error _ -> ()
    | Ok _ -> fail (label ^ " unexpectedly produced a verdict")
  in
  (match
     Goal_completion_reviewer.parse_verdict_from_json
       (`Assoc [ "verdict", `String "APPROVE" ])
   with
   | Ok Goal_completion_reviewer.Approve -> ()
   | Ok (Goal_completion_reviewer.Reject _) | Error _ ->
     fail "exact APPROVE verdict did not parse");
  expect_invalid
    "APPROVE with reason"
    (`Assoc
       [ "verdict", `String "APPROVE"
       ; "reason", `String "must not be present"
       ]);
  expect_invalid
    "REJECT without reason"
    (`Assoc [ "verdict", `String "REJECT" ]);
  expect_invalid
    "unknown field"
    (`Assoc
       [ "verdict", `String "APPROVE"
       ; "extra", `String "not in schema"
       ]);
  expect_invalid
    "duplicate verdict"
    (`Assoc
       [ "verdict", `String "APPROVE"
       ; "verdict", `String "REJECT"
       ; "reason", `String "duplicate"
       ])
;;

let test_goal_completion_requires_structured_approval () =
  with_workspace
  @@ fun config ->
  goal_reviewer_run := (fun _ -> Ok (Some Goal_completion_reviewer.Approve));
  let goal, _ =
    match Goal_store.upsert_goal config ~title:"Direct completion" () with
    | Ok payload -> payload
    | Error msg -> fail msg
  in
  let result =
    request_complete
      ~note:"Deployment receipt confirms the target behavior."
      config
      goal.id
  in
  check string "structured approval completes" "completed" (transition_phase result);
  let completed = current_goal config goal.id in
  check bool "approved Goal has no failure marker" true
    (Option.is_none completed.completion_review_failure);
  (match completed.completion_receipt with
   | None -> fail "structured approval did not persist a completion receipt"
   | Some receipt ->
     check
       string
       "provider-neutral reviewer runtime persisted"
       "test.goal-completion-reviewer"
       receipt.evaluator_runtime;
     check
       string
       "receipt binds reviewed snapshot"
       goal.updated_at
       receipt.reviewed_goal_updated_at;
     check
       int
       "receipt binds exact review prompt"
       64
       (String.length receipt.review_prompt_sha256));
  let mutation_error =
    Tool_workspace.dispatch
      (workspace_ctx config)
      ~name:"masc_goal_upsert"
      ~args:
        (`Assoc
           [ "id", `String goal.id
           ; "title", `String "Mutated after approval"
           ])
    |> expect_error
  in
  check
    string
    "completed contract mutation is rejected"
    "validation_error"
    (get_string_field mutation_error "error_code");
  check
    string
    "completed Goal retains reviewed title"
    "Direct completion"
    (current_goal config goal.id).title;
  let reopened =
    Tool_workspace.dispatch
      (workspace_ctx config)
      ~name:"masc_goal_transition"
      ~args:
        (`Assoc
           [ "goal_id", `String goal.id
           ; "action", `String "reopen"
           ])
  in
  check string "reopen returns to execution" "executing"
    (transition_phase reopened);
  check bool "reopen clears completion receipt" true
    (current_goal config goal.id
     |> fun current -> Option.is_none current.completion_receipt)
;;

let test_goal_completion_supplies_open_task_as_evidence () =
  with_workspace
  @@ fun config ->
  let goal, _ =
    match Goal_store.upsert_goal config ~title:"Open task completion" () with
    | Ok payload -> payload
    | Error msg -> fail msg
  in
  ignore
    (Workspace_task.add_task
       ~goal_id:goal.id
       config
       ~title:"Still open"
       ~priority:3
       ~description:"This task is unrelated to the already achieved target");
  let task =
    Workspace.get_tasks_raw config
    |> List.find (fun (task : Masc_domain.task) ->
         String.equal task.title "Still open")
  in
  goal_reviewer_run :=
    (fun prompt ->
       check
         bool
         "linked open Task reaches semantic reviewer"
         true
         (contains_substring prompt task.id);
       Ok (Some Goal_completion_reviewer.Approve));
  check
    string
    "open task is evidence, not a local count gate"
    "completed"
    (transition_phase
       (request_complete
          ~note:"The Goal target was achieved independently; see the claim."
          config
          goal.id))
;;

let test_goal_completion_rejection_is_durable_and_nonterminal () =
  with_workspace
  @@ fun config ->
  let goal, _ =
    match
      Goal_store.upsert_goal
        config
        ~title:"Metric completion"
        ~metric:"coverage %"
        ~target_value:"80%"
        ()
    with
    | Ok payload -> payload
    | Error msg -> fail msg
  in
  goal_reviewer_run :=
    (fun prompt ->
       check bool "metric reaches reviewer" true (contains_substring prompt "coverage %");
       check bool "target reaches reviewer" true (contains_substring prompt "80%");
       Ok
         (Some
            (Goal_completion_reviewer.Reject
               "No measured coverage result was supplied")));
  let error =
    request_complete
      ~note:"All implementation tasks are done."
      config
      goal.id
    |> expect_error
  in
  check
    string
    "semantic rejection is explicit"
    "precondition_failed"
    (get_string_field error "error_code");
  let current = current_goal config goal.id in
  check bool "rejected Goal stays executing" true
    (current.phase = Goal_phase.Executing);
  check
    (option string)
    "rejection reason is durable"
    (Some "No measured coverage result was supplied")
    current.last_review_note;
  check bool "rejection kind is typed" true
    (current.completion_review_failure = Some Goal_store.Rejected);
  check bool "next Keeper turn receives fixed continuation marker" true
    (contains_substring
       (Keeper_unified_turn.goal_summary_for_turn current)
       "completion review pending rework")
;;

let test_goal_completion_unavailable_is_retryable_and_nonterminal () =
  with_workspace
  @@ fun config ->
  let goal, _ =
    match Goal_store.upsert_goal config ~title:"Evaluator unavailable" () with
    | Ok payload -> payload
    | Error msg -> fail msg
  in
  goal_reviewer_run :=
    (fun _ ->
       Error (Agent_sdk.Error.Internal "review runtime temporarily unavailable"));
  let result = request_complete config goal.id in
  (match result with
   | Some result ->
     check
       bool
       "unavailable review is retryable"
       true
       (Tool_result.failure_class result = Some Tool_result.Transient_error)
   | None -> fail "masc_goal_transition not handled");
  let current = current_goal config goal.id in
  check bool "unavailable Goal stays executing" true
    (current.phase = Goal_phase.Executing);
  check bool "unavailable reason is durable" true
    (Option.is_some current.last_review_note);
  check bool "unavailable kind is typed" true
    (current.completion_review_failure = Some Goal_store.Unavailable)
;;

let test_goal_completion_missing_verdict_is_nonterminal () =
  with_workspace
  @@ fun config ->
  let goal, _ =
    match Goal_store.upsert_goal config ~title:"Missing structured verdict" () with
    | Ok payload -> payload
    | Error msg -> fail msg
  in
  goal_reviewer_run := (fun _ -> Ok None);
  let result = request_complete config goal.id in
  (match result with
   | Some result ->
     check bool "missing verdict fails" false (Tool_result.is_success result);
     check
       bool
       "missing verdict is retryable"
       true
       (Tool_result.failure_class result = Some Tool_result.Transient_error)
   | None -> fail "masc_goal_transition not handled");
  let current = current_goal config goal.id in
  check bool "missing verdict cannot complete" true
    (current.phase = Goal_phase.Executing);
  check bool "missing verdict is typed unavailable" true
    (current.completion_review_failure = Some Goal_store.Unavailable);
  check bool "missing verdict writes no receipt" true
    (Option.is_none current.completion_receipt)
;;

let test_goal_completion_rejects_stale_approval () =
  with_workspace
  @@ fun config ->
  let goal, _ =
    match Goal_store.upsert_goal config ~title:"Original target" () with
    | Ok payload -> payload
    | Error msg -> fail msg
  in
  goal_reviewer_run :=
    (fun _ ->
       (match
          Goal_store.update_goal config ~goal_id:goal.id (fun current ->
            { current with title = "Changed while reviewing" })
        with
        | Ok _ -> ()
        | Error msg -> fail msg);
       Ok (Some Goal_completion_reviewer.Approve));
  let error = request_complete config goal.id |> expect_error in
  check
    string
    "stale approval is a conflict"
    "conflict"
    (get_string_field error "error_code");
  let current = current_goal config goal.id in
  check bool "stale approval cannot complete" true
    (current.phase = Goal_phase.Executing);
  check bool "no stale receipt" true (Option.is_none current.completion_receipt)
;;
let test_goal_block_and_unblock_have_no_operator_hierarchy () =
  with_workspace
  @@ fun config ->
  let goal, _ =
    match Goal_store.upsert_goal config ~title:"Explicitly blocked Goal" () with
    | Ok payload -> payload
    | Error msg -> fail msg
  in
  let transition ?note action =
    let fields =
      [ "goal_id", `String goal.id; "action", `String action ]
      @
      match note with
      | None -> []
      | Some note -> [ "note", `String note ]
    in
    Tool_workspace.dispatch
      (workspace_ctx ~agent_name:"agent-alpha" config)
      ~name:"masc_goal_transition"
      ~args:(`Assoc fields)
  in
  check string "ordinary caller blocks" "blocked"
    (transition_phase (transition ~note:"Waiting for operator input" "block"));
  check bool "ordinary lifecycle note is not a completion marker" false
    (contains_substring
       (current_goal config goal.id
        |> Keeper_unified_turn.goal_summary_for_turn)
       "completion review pending rework");
  check string "ordinary caller unblocks" "executing"
    (transition_phase (transition "unblock"))
;;
let () =
  run
    "goal_tools"
    [ ( "tool_workspace"
      , [ test_case "upsert and list" `Quick test_goal_upsert_and_list
        ; test_case "list filters by phase" `Quick test_goal_list_filters_by_phase
        ; test_case "list includes rollup" `Quick test_goal_list_includes_rollup
        ; test_case
            "list ignores blank optional filters"
            `Quick
            test_goal_list_ignores_blank_optional_filters
        ; test_case
            "list rejects status filter"
            `Quick
            test_goal_list_rejects_status_filter
        ; test_case
            "upsert rejects lifecycle fields"
            `Quick
            test_goal_upsert_rejects_lifecycle_fields
        ; test_case
            "goal review removed from dispatch"
            `Quick
            test_goal_review_removed_from_dispatch
        ; test_case
            "completion verdict parser is exact"
            `Quick
            test_goal_completion_verdict_parser_is_exact
        ; test_case
            "completion requires structured approval"
            `Quick
            test_goal_completion_requires_structured_approval
        ; test_case
            "completion supplies open Task as evidence"
            `Quick
            test_goal_completion_supplies_open_task_as_evidence
        ; test_case
            "completion rejection is durable and nonterminal"
            `Quick
            test_goal_completion_rejection_is_durable_and_nonterminal
        ; test_case
            "completion unavailable is retryable and nonterminal"
            `Quick
            test_goal_completion_unavailable_is_retryable_and_nonterminal
        ; test_case
            "completion missing verdict is nonterminal"
            `Quick
            test_goal_completion_missing_verdict_is_nonterminal
        ; test_case
            "completion rejects stale approval"
            `Quick
            test_goal_completion_rejects_stale_approval
        ; test_case
            "block and unblock have no operator hierarchy"
            `Quick
            test_goal_block_and_unblock_have_no_operator_hierarchy
        ] )
    ]
;;
