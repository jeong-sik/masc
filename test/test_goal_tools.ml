module Types = Masc_domain

(** Goal tool coverage — shared Goal Store surface through Tool_workspace. *)

open Alcotest
open Masc
open Workspace_types
open Tool_workspace

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
       let previous_is_admin = Atomic.get Workspace_hooks.is_admin_agent_fn in
       Fun.protect
         ~finally:(fun () -> Atomic.set Workspace_hooks.is_admin_agent_fn previous_is_admin)
         (fun () ->
            Atomic.set Workspace_hooks.is_admin_agent_fn
              (fun ~base_path:_ ~agent_name -> String.equal agent_name "planner");
            f config))
;;

let workspace_ctx ?(agent_name = "planner") config : Tool_workspace.context =
  { Tool_workspace.config; agent_name }
;;

let parse_json_result (result : Tool_result.result) =
  if (Tool_result.is_success result)
  then Yojson.Safe.from_string ((Tool_result.message result))
  else Alcotest.fail ((Tool_result.message result))
;;

let principal_json ~id = `Assoc [ "id", `String id ]

let get_string_field json field =
  match Yojson.Safe.Util.member field json with
  | `String value -> value
  | _ -> fail (field ^ " missing")
;;

let get_string_list_field json field =
  Yojson.Safe.Util.member field json
  |> Yojson.Safe.Util.to_list
  |> List.map Yojson.Safe.Util.to_string
;;

let get_payload json =
  match Yojson.Safe.Util.member "payload" json with
  | `Assoc _ as payload -> payload
  | _ -> fail "payload missing"
;;

let json_is_null = function
  | `Null -> true
  | _ -> false
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

let count_substring s needle =
  let s_len = String.length s in
  let n_len = String.length needle in
  let rec loop i count =
    if n_len = 0 || i + n_len > s_len
    then count
    else if String.sub s i n_len = needle
    then loop (i + n_len) (count + 1)
    else loop (i + 1) count
  in
  loop 0 0
;;

let find_substring_from source needle start =
  let source_len = String.length source in
  let needle_len = String.length needle in
  let rec loop idx =
    if idx + needle_len > source_len
    then None
    else if String.sub source idx needle_len = needle
    then Some idx
    else loop (idx + 1)
  in
  loop start
;;

let find_substring source needle = find_substring_from source needle 0

let read_source_file rel =
  let source_root =
    match Sys.getenv_opt "DUNE_SOURCEROOT" with
    | Some root -> root
    | None -> Sys.getcwd ()
  in
  let path = Filename.concat source_root rel in
  let ic = open_in path in
  Fun.protect
    ~finally:(fun () -> close_in_noerr ic)
    (fun () -> In_channel.input_all ic)
;;

let read_file path =
  let ic = open_in path in
  Fun.protect
    ~finally:(fun () -> close_in_noerr ic)
    (fun () -> In_channel.input_all ic)
;;

let write_file path content =
  let oc = open_out path in
  Fun.protect
    ~finally:(fun () -> close_out_noerr oc)
    (fun () -> Out_channel.output_string oc content)
;;

let goal_events_by_type config event_type =
  Fs_compat.load_jsonl (Goal_verification.events_path config)
  |> List.filter (fun json ->
    match Yojson.Safe.Util.member "event_type" json with
    | `String value -> String.equal value event_type
    | _ -> false)
;;

let approval_request_by_id config request_id =
  Goal_approval.read_state config
  |> fun state ->
  List.find_opt
    (fun (request : Goal_approval.approval_request) ->
      String.equal request.id request_id)
    state.requests
;;

let create_done_task config ~goal_id ~title =
  ignore
    (Workspace_task.add_task
       ~goal_id
       config
       ~title
       ~priority:3
       ~description:"done task fixture");
  let task_id =
    Workspace.get_tasks_raw config
    |> List.find_map (fun (task : Masc_domain.task) ->
      if String.equal task.title title then Some task.id else None)
    |> function
    | Some task_id -> task_id
    | None -> fail ("task not found: " ^ title)
  in
  let step action notes =
    match
      Workspace.transition_task_r config ~agent_name:"planner" ~task_id ~action ~notes ()
    with
    | Ok _ -> ()
    | Error err -> fail (Masc_domain.masc_error_to_string err)
  in
  step Masc_domain.Claim "test fixture claim";
  step Masc_domain.Start "test fixture start";
  step Masc_domain.Done_action "test fixture done"
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
    match Goal_store.upsert_goal config ~title ~phase () with
    | Ok _ -> ()
    | Error msg -> fail msg
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

let test_goal_upsert_normalizes_noop_verifier_policy () =
  let assert_no_policy args =
    with_workspace
    @@ fun config ->
    let created =
      Tool_workspace.dispatch
        (workspace_ctx config)
        ~name:"masc_goal_upsert"
        ~args:(`Assoc (("title", `String "No-op verifier policy") :: args))
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
    let saved_goal =
      match Goal_store.get_goal config ~goal_id with
      | Some goal -> goal
      | None -> fail "goal missing after no-op verifier policy upsert"
    in
    check bool "verifier policy omitted" true (Option.is_none saved_goal.verifier_policy)
  in
  assert_no_policy [ "verifier_policy", `Assoc [] ];
  assert_no_policy [ "verifier_policy", `Assoc [ "mode", `String "none" ] ]
;;

let test_goal_upsert_rejects_malformed_verifier_policy_shape () =
  with_workspace
  @@ fun config ->
  let rejected =
    Tool_workspace.dispatch
      (workspace_ctx config)
      ~name:"masc_goal_upsert"
      ~args:
        (`Assoc
            [ "title", `String "Malformed verifier policy"
            ; "verifier_policy", `Assoc [ "mode", `String "review" ]
            ])
  in
  let error = expect_error rejected in
  check string "validation error" "validation_error" (get_string_field error "error_code");
  check
    bool
    "error includes accepted policy shapes"
    true
    (contains_substring (Yojson.Safe.to_string error) "accepted verifier_policy shapes")
;;

let test_goal_verification_phase_failure_source_guard () =
  let source = read_source_file "lib/workspace_goals.ml" in
  check
    int
    "verification request compensation helper is defined and used"
    2
    (count_substring source "cancel_verification_request_after_phase_failure");
  check
    bool
    "verification cancellation records a durable reason"
    true
    (contains_substring source "failed_to_persist_awaiting_verification_phase");
  check
    bool
    "sealed vote phase write failure is observable"
    true
    (contains_substring source "goal_verification_phase_update_failed");
  check
    bool
    "sealed vote phase write failure names request status"
    true
    (contains_substring source "sealed as %s but failed to")
  ;
  check
    bool
    "sealed vote phase write failure rolls verification request back"
    true
    (contains_substring source "rollback_verification_vote_after_phase_failure")
  ;
  let verification_source = read_source_file "lib/goal/goal_verification.ml" in
  check
    bool
    "verification rollback refuses changed current request"
    true
    (contains_substring
       verification_source
       "refusing to rollback")
  ;
  check
    bool
    "verification votes require the goal active request binding"
    true
    (contains_substring source "validate_goal_active_verification_request");
  check
    bool
    "inactive goals cannot accept stale verification votes"
    true
    (contains_substring source "is not awaiting verification; refusing vote")
;;

let test_goal_completion_phase_update_rechecks_ready_source_guard () =
  let store_source = read_source_file "lib/goal/goal_store.ml" in
  check
    bool
    "checked goal update can fail before write"
    true
    (contains_substring store_source "let update_goal_checked");
  let verification_source = read_source_file "lib/workspace_goals_verification.ml" in
  check
    bool
    "phase update uses checked goal update"
    true
    (contains_substring verification_source "Goal_store.update_goal_checked");
  check
    bool
    "phase update accepts precondition"
    true
    (contains_substring verification_source "?precondition");
  let goals_source = read_source_file "lib/workspace_goals.ml" in
  check
    bool
    "completion precondition helper is wired"
    true
    (count_substring goals_source "completion_ready_precondition" >= 3);
  check
    bool
    "completion readiness uses locked fail-closed goal-task snapshot"
    true
    (contains_substring
       goals_source
       "build_goal_task_index_for_config_checked");
  let index_source = read_source_file "lib/workspace/workspace_goal_index.ml" in
  let snapshot_source =
    let start_marker = "let build_goal_task_index_for_config_checked" in
    match find_substring index_source start_marker with
    | None -> fail "missing checked goal-task snapshot helper"
    | Some start ->
      let rest =
        String.sub index_source start (String.length index_source - start)
      in
      match find_substring rest "let tasks_for_goal" with
      | None -> rest
      | Some stop -> String.sub rest 0 stop
  in
  let backlog_lock_idx =
    match find_substring snapshot_source "backlog_lock_path config" with
    | Some idx -> idx
    | None -> fail "checked snapshot missing backlog lock"
  in
  let link_lock_idx =
    match find_substring snapshot_source "goal_task_links_lock_path config" with
    | Some idx -> idx
    | None -> fail "checked snapshot missing goal-task-links lock"
  in
  check bool "checked snapshot lock order is backlog before links" true
    (backlog_lock_idx < link_lock_idx);
  check
    bool
    "request_complete phase writes recheck completion readiness"
    true
    (contains_substring goals_source "?precondition:request_completion_precondition");
  check
    bool
    "verification approval finalization rechecks completion readiness"
    true
    (contains_substring goals_source "?precondition:approval_precondition")
;;

let test_goal_transition_verification_to_completion () =
  with_workspace
  @@ fun config ->
  let verifier_policy =
    { Goal_verification.inherit_mode = Goal_verification.Extend
    ; principals =
        [ { id = "agent-alpha"; display_name = Some "agent-alpha" } ]
    ; required_verdicts = Some 1
    }
  in
  let goal, _kind =
    match Goal_store.upsert_goal config ~title:"Verify me" ~verifier_policy () with
    | Ok payload -> payload
    | Error msg -> fail msg
  in
  create_done_task config ~goal_id:goal.id ~title:"Verify done task";
  let transitioned =
    Tool_workspace.dispatch
      (workspace_ctx config)
      ~name:"masc_goal_transition"
      ~args:
        (`Assoc
            [ "goal_id", `String goal.id
            ; "action", `String "request_complete"
            ; "actor", principal_json ~id:"planner"
            ])
  in
  let transitioned_json =
    match transitioned with
    | Some result -> parse_json_result result
    | None -> fail "masc_goal_transition not handled"
  in
  let transitioned_goal = Yojson.Safe.Util.member "goal" transitioned_json in
  check
    string
    "phase moved to awaiting_verification"
    "awaiting_verification"
    (get_string_field transitioned_goal "phase");
  let request_json = Yojson.Safe.Util.member "verification_request" transitioned_json in
  let request_id = get_string_field request_json "id" in
  let transitioned_summary =
    Yojson.Safe.Util.member "verification_summary" transitioned_json
  in
  check
    string
    "latest request visible while open"
    request_id
    (transitioned_summary
     |> Yojson.Safe.Util.member "latest_request"
     |> fun json -> get_string_field json "id");
  let verified =
    Tool_workspace.dispatch
      (workspace_ctx ~agent_name:"agent-alpha" config)
      ~name:"masc_goal_verify"
      ~args:
        (`Assoc
            [ "goal_id", `String goal.id
            ; "request_id", `String request_id
            ; "principal", principal_json ~id:"agent-alpha"
            ; "decision", `String "approve"
            ; "note", `String "checked receipt and tests"
            ; ( "evidence_refs"
              , `List
                  [ `String "receipt:agent-alpha:turn-7"
                  ; `String "test:test_goal_tools"
                  ] )
            ])
  in
  let verified_json =
    match verified with
    | Some result -> parse_json_result result
    | None -> fail "masc_goal_verify not handled"
  in
  let verified_goal = Yojson.Safe.Util.member "goal" verified_json in
  check
    string
    "phase moved to completed"
    "completed"
    (get_string_field verified_goal "phase");
  let verified_summary = Yojson.Safe.Util.member "verification_summary" verified_json in
  check
    bool
    "open request cleared after approve"
    true
    (verified_summary |> Yojson.Safe.Util.member "open_request" |> json_is_null);
  check
    int
    "approve count follows latest request"
    1
    (verified_summary
     |> Yojson.Safe.Util.member "approve_count"
     |> Yojson.Safe.Util.to_int);
  let latest_request = Yojson.Safe.Util.member "latest_request" verified_summary in
  check
    string
    "approved latest request retained"
    request_id
    (get_string_field latest_request "id");
  check
    string
    "latest request status approved"
    "approved"
    (get_string_field latest_request "status");
  let vote =
    match
      latest_request |> Yojson.Safe.Util.member "votes" |> Yojson.Safe.Util.to_list
    with
    | vote :: _ -> vote
    | [] -> fail "expected verification vote"
  in
  check
    string
    "vote note retained"
    "checked receipt and tests"
    (get_string_field vote "note");
  check
    (list string)
    "vote evidence refs retained"
    [ "receipt:agent-alpha:turn-7"; "test:test_goal_tools" ]
    (get_string_list_field vote "evidence_refs")
;;

let test_goal_transition_rejected_verification_retains_evidence () =
  with_workspace
  @@ fun config ->
  let verifier_policy =
    { Goal_verification.inherit_mode = Goal_verification.Extend
    ; principals =
        [ { id = "agent-alpha"; display_name = Some "agent-alpha" } ]
    ; required_verdicts = Some 1
    }
  in
  let goal, _kind =
    match Goal_store.upsert_goal config ~title:"Reject me" ~verifier_policy () with
    | Ok payload -> payload
    | Error msg -> fail msg
  in
  create_done_task config ~goal_id:goal.id ~title:"Reject done task";
  let transitioned =
    Tool_workspace.dispatch
      (workspace_ctx config)
      ~name:"masc_goal_transition"
      ~args:
        (`Assoc
            [ "goal_id", `String goal.id
            ; "action", `String "request_complete"
            ; "actor", principal_json ~id:"planner"
            ])
  in
  let transitioned_json =
    match transitioned with
    | Some result -> parse_json_result result
    | None -> fail "masc_goal_transition not handled"
  in
  let request_id =
    transitioned_json
    |> Yojson.Safe.Util.member "verification_request"
    |> fun json -> get_string_field json "id"
  in
  let rejected =
    Tool_workspace.dispatch
      (workspace_ctx ~agent_name:"agent-alpha" config)
      ~name:"masc_goal_verify"
      ~args:
        (`Assoc
            [ "goal_id", `String goal.id
            ; "request_id", `String request_id
            ; "principal", principal_json ~id:"agent-alpha"
            ; "decision", `String "reject"
            ; "note", `String "receipt did not prove completion"
            ; "evidence_refs", `List [ `String "receipt:agent-alpha:turn-7" ]
            ])
  in
  let rejected_json =
    match rejected with
    | Some result -> parse_json_result result
    | None -> fail "masc_goal_verify not handled"
  in
  check
    string
    "phase moved back to executing"
    "executing"
    (rejected_json
     |> Yojson.Safe.Util.member "goal"
     |> fun json -> get_string_field json "phase");
  let latest_request =
    rejected_json
    |> Yojson.Safe.Util.member "verification_summary"
    |> Yojson.Safe.Util.member "latest_request"
  in
  check
    int
    "reject count follows latest request"
    1
    (rejected_json
     |> Yojson.Safe.Util.member "verification_summary"
     |> Yojson.Safe.Util.member "reject_count"
     |> Yojson.Safe.Util.to_int);
  check
    string
    "latest request status rejected"
    "rejected"
    (get_string_field latest_request "status");
  let vote =
    match
      latest_request |> Yojson.Safe.Util.member "votes" |> Yojson.Safe.Util.to_list
    with
    | vote :: _ -> vote
    | [] -> fail "expected reject vote"
  in
  check
    string
    "reject note retained"
    "receipt did not prove completion"
    (get_string_field vote "note");
  check
    (list string)
    "reject evidence retained"
    [ "receipt:agent-alpha:turn-7" ]
    (get_string_list_field vote "evidence_refs")
;;

let test_goal_transition_manual_reject_blocks_and_cancels_request () =
  with_workspace
  @@ fun config ->
  let verifier_policy =
    { Goal_verification.inherit_mode = Goal_verification.Extend
    ; principals =
        [ { id = "agent-alpha"; display_name = Some "agent-alpha" } ]
    ; required_verdicts = Some 1
    }
  in
  let goal, _kind =
    match Goal_store.upsert_goal config ~title:"Manually reject me" ~verifier_policy () with
    | Ok payload -> payload
    | Error msg -> fail msg
  in
  create_done_task config ~goal_id:goal.id ~title:"Manual reject done task";
  let transitioned =
    Tool_workspace.dispatch
      (workspace_ctx config)
      ~name:"masc_goal_transition"
      ~args:
        (`Assoc
            [ "goal_id", `String goal.id
            ; "action", `String "request_complete"
            ; "actor", principal_json ~id:"planner"
            ])
  in
  let transitioned_json =
    match transitioned with
    | Some result -> parse_json_result result
    | None -> fail "masc_goal_transition not handled"
  in
  let request_id =
    transitioned_json
    |> Yojson.Safe.Util.member "verification_request"
    |> fun json -> get_string_field json "id"
  in
  let rejected =
    Tool_workspace.dispatch
      (workspace_ctx config)
      ~name:"masc_goal_transition"
      ~args:
        (`Assoc
            [ "goal_id", `String goal.id
            ; "action", `String "reject_completion"
            ; "actor", principal_json ~id:"planner"
            ; "note", `String "operator rejected the completion claim"
            ])
  in
  let rejected_json =
    match rejected with
    | Some result -> parse_json_result result
    | None -> fail "masc_goal_transition not handled"
  in
  let rejected_goal = Yojson.Safe.Util.member "goal" rejected_json in
  check string "manual reject blocks goal" "blocked" (get_string_field rejected_goal "phase");
  check
    bool
    "manual reject clears active request"
    true
    (rejected_goal |> Yojson.Safe.Util.member "active_verification_request_id" |> json_is_null);
  check
    bool
    "manual reject has no open request"
    true
    (rejected_json
     |> Yojson.Safe.Util.member "verification_summary"
     |> Yojson.Safe.Util.member "open_request"
     |> json_is_null);
  let saved_request =
    match Goal_verification.find_request config ~request_id with
    | Some request -> request
    | None -> fail "verification request missing after manual reject"
  in
  check
    bool
    "manual reject cancels, not quorum-rejects, request"
    true
    (saved_request.status = Goal_verification.Cancelled)
;;

let test_goal_transition_approval_gate () =
  with_workspace
  @@ fun config ->
  let verifier_policy =
    { Goal_verification.inherit_mode = Goal_verification.Extend
    ; principals =
        [ { id = "agent-alpha"; display_name = Some "agent-alpha" } ]
    ; required_verdicts = Some 1
    }
  in
  let goal, _kind =
    match
      Goal_store.upsert_goal
        config
        ~title:"Approve me"
        ~verifier_policy
        ~require_completion_approval:true
        ()
    with
    | Ok payload -> payload
    | Error msg -> fail msg
  in
  create_done_task config ~goal_id:goal.id ~title:"Approval done task";
  let transitioned =
    Tool_workspace.dispatch
      (workspace_ctx config)
      ~name:"masc_goal_transition"
      ~args:
        (`Assoc
            [ "goal_id", `String goal.id
            ; "action", `String "request_complete"
            ; "actor", principal_json ~id:"planner"
            ])
  in
  let transitioned_json =
    match transitioned with
    | Some result -> parse_json_result result
    | None -> fail "masc_goal_transition not handled"
  in
  let request_id =
    transitioned_json
    |> Yojson.Safe.Util.member "verification_request"
    |> fun json -> get_string_field json "id"
  in
  let verified =
    Tool_workspace.dispatch
      (workspace_ctx ~agent_name:"agent-alpha" config)
      ~name:"masc_goal_verify"
      ~args:
        (`Assoc
            [ "goal_id", `String goal.id
            ; "request_id", `String request_id
            ; "principal", principal_json ~id:"agent-alpha"
            ; "decision", `String "approve"
            ])
  in
  let verified_json =
    match verified with
    | Some result -> parse_json_result result
    | None -> fail "masc_goal_verify not handled"
  in
  check
    string
    "phase moved to awaiting_approval"
    "awaiting_approval"
    (verified_json
     |> Yojson.Safe.Util.member "goal"
     |> fun json -> get_string_field json "phase");
  let approval_request =
    match Goal_approval.find_open_request config ~goal_id:goal.id with
    | Some request -> request
    | None -> fail "approval request was not persisted"
  in
  check bool "approval request id prefix" true
    (String.starts_with ~prefix:"approval-" approval_request.id);
  check int "approval request id length" 41 (String.length approval_request.id);
  check string "approval request goal_id" goal.id approval_request.goal_id;
  check
    string
    "approval request links verification request"
    request_id
    (match approval_request.verification_request_id with
     | Some value -> value
     | None -> fail "approval request missing verification_request_id");
  check string "approval opened by final verifier" "agent-alpha" approval_request.opened_by.id;
  check
    string
    "approval request is open"
    "open"
    (Goal_approval.approval_status_to_string approval_request.status);
  let opened_event =
    goal_events_by_type config "goal_approval_opened"
    |> List.find_opt (fun event ->
      let payload = get_payload event in
      let event_request =
        Yojson.Safe.Util.member "approval_request" payload
      in
      (match Yojson.Safe.Util.member "id" event_request with
       | `String id -> String.equal id approval_request.id
       | _ -> false))
  in
  (match opened_event with
   | None -> fail "goal_approval_opened event missing durable approval_request"
   | Some event ->
     let payload = get_payload event in
     let actor = Yojson.Safe.Util.member "actor" payload in
     check string "opened event actor" "agent-alpha" (get_string_field actor "id"));
  let approved =
    Tool_workspace.dispatch
      (workspace_ctx config)
      ~name:"masc_goal_transition"
      ~args:
        (`Assoc
            [ "goal_id", `String goal.id
            ; "action", `String "approve_completion"
            ; "actor", principal_json ~id:"planner"
            ])
  in
  let approved_json =
    match approved with
    | Some result -> parse_json_result result
    | None -> fail "masc_goal_transition not handled"
  in
  check
    string
    "phase moved to completed after approval"
    "completed"
    (approved_json
     |> Yojson.Safe.Util.member "goal"
     |> fun json -> get_string_field json "phase")
  ;
  check
    bool
    "approval request no longer open"
    true
    (Option.is_none (Goal_approval.find_open_request config ~goal_id:goal.id));
  let saved_approval_request =
    match approval_request_by_id config approval_request.id with
    | Some request -> request
    | None -> fail "approval request missing after resolution"
  in
  check
    string
    "approval request approved"
    "approved"
    (Goal_approval.approval_status_to_string saved_approval_request.status);
  check
    string
    "approval resolved by operator"
    "planner"
    (match saved_approval_request.resolved_by with
     | Some principal -> principal.id
     | None -> fail "approval request missing resolved_by");
  let resolved_event =
    goal_events_by_type config "goal_approval_resolved"
    |> List.find_opt (fun event ->
      let payload = get_payload event in
      let event_request =
        Yojson.Safe.Util.member "approval_request" payload
      in
      (match Yojson.Safe.Util.member "id" event_request with
       | `String id -> String.equal id approval_request.id
       | _ -> false))
  in
  match resolved_event with
  | None -> fail "goal_approval_resolved event missing approval_request"
  | Some event ->
    let payload = get_payload event in
    check string "resolved decision" "approve" (get_string_field payload "decision");
    let actor = Yojson.Safe.Util.member "actor" payload in
    check string "resolved event actor" "planner" (get_string_field actor "id")
;;

let test_goal_approval_semantic_errors_do_not_rewrite_ledger () =
  with_workspace
  @@ fun config ->
  let principal : Goal_verification.goal_principal =
    { id = "planner"; display_name = None }
  in
  let request =
    match
      Goal_approval.open_request
        config
        ~goal_id:"goal-semantic-error"
        ~opened_by:principal
        ()
    with
    | Ok request -> request
    | Error msg -> fail msg
  in
  let path = Goal_approval.requests_path config in
  let after_open = read_file path in
  (match
     Goal_approval.open_request
       config
       ~goal_id:request.goal_id
       ~opened_by:principal
       ()
   with
   | Ok _ -> fail "duplicate approval open must reject"
   | Error msg ->
     check
       bool
       "duplicate open names existing request"
       true
       (contains_substring msg "already has an open approval request"));
  check string "duplicate open does not rewrite ledger" after_open (read_file path);
  let resolved =
    match
      Goal_approval.resolve_open_request
        config
        ~goal_id:request.goal_id
        ~status:Goal_approval.Approved
        ~resolved_by:principal
        ()
    with
    | Ok request -> request
    | Error msg -> fail msg
  in
  check string "request resolved" "approved"
    (Goal_approval.approval_status_to_string resolved.status);
  let after_resolve = read_file path in
  (match
     Goal_approval.resolve_open_request
       config
       ~goal_id:request.goal_id
       ~status:Goal_approval.Rejected
       ~resolved_by:principal
       ()
   with
   | Ok _ -> fail "already resolved approval must reject"
   | Error msg ->
     check
       bool
       "second resolve names missing open request"
       true
       (contains_substring msg "no open approval request"));
  check string "second resolve does not rewrite ledger" after_resolve (read_file path)
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

let test_goal_completion_requires_linked_task () =
  with_workspace
  @@ fun config ->
  let goal, _kind =
    match Goal_store.upsert_goal config ~title:"No task completion" () with
    | Ok payload -> payload
    | Error msg -> fail msg
  in
  let completed =
    Tool_workspace.dispatch
      (workspace_ctx config)
      ~name:"masc_goal_transition"
      ~args:
        (`Assoc
            [ "goal_id", `String goal.id
            ; "action", `String "request_complete"
            ; "actor", principal_json ~id:"planner"
            ])
  in
  let error_json = expect_error completed in
  check
    string
    "zero task completion blocked"
    "conflict"
    (get_string_field error_json "error_code");
  check
    bool
    "error mentions linked task"
    true
    (contains_substring (Yojson.Safe.to_string error_json) "linked task")
;;

let test_goal_completion_blocks_open_tasks () =
  with_workspace
  @@ fun config ->
  let goal, _kind =
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
       ~description:"open");
  let completed =
    Tool_workspace.dispatch
      (workspace_ctx config)
      ~name:"masc_goal_transition"
      ~args:
        (`Assoc
            [ "goal_id", `String goal.id
            ; "action", `String "request_complete"
            ; "actor", principal_json ~id:"planner"
            ])
  in
  let error_json = expect_error completed in
  check
    string
    "open task completion blocked"
    "conflict"
    (get_string_field error_json "error_code")
;;

let test_goal_completion_fails_closed_on_corrupt_goal_task_registry () =
  with_workspace
  @@ fun config ->
  let goal, _kind =
    match Goal_store.upsert_goal config ~title:"Completion corrupt links" () with
    | Ok payload -> payload
    | Error msg -> fail msg
  in
  create_done_task config ~goal_id:goal.id ~title:"Corrupt links done task";
  let links_path = Workspace_goal_index.goal_task_links_path config in
  let recovery_path = links_path ^ ".last-good" in
  let corrupt_primary = "{goal-links-corrupt" in
  let corrupt_recovery = "{goal-links-recovery-corrupt" in
  write_file links_path corrupt_primary;
  write_file recovery_path corrupt_recovery;
  let completed =
    Tool_workspace.dispatch
      (workspace_ctx config)
      ~name:"masc_goal_transition"
      ~args:
        (`Assoc
            [ "goal_id", `String goal.id
            ; "action", `String "request_complete"
            ; "actor", principal_json ~id:"planner"
            ])
  in
  let error_json = expect_error completed in
  check string "corrupt registry blocks completion" "conflict"
    (get_string_field error_json "error_code");
  check
    bool
    "error names readiness snapshot"
    true
    (contains_substring
       (Yojson.Safe.to_string error_json)
       "goal completion readiness unavailable");
  check string "primary corrupt file preserved" corrupt_primary (read_file links_path);
  check
    string
    "recovery corrupt file preserved"
    corrupt_recovery
    (read_file recovery_path);
  let saved_goal =
    match Goal_store.get_goal config ~goal_id:goal.id with
    | Some goal -> goal
    | None -> fail "goal missing after corrupt registry rejection"
  in
  check string "phase unchanged" "executing" (Goal_phase.to_string saved_goal.phase)
;;

let test_goal_verify_rolls_back_sealed_request_on_phase_failure () =
  with_workspace
  @@ fun config ->
  let verifier_policy =
    { Goal_verification.inherit_mode = Goal_verification.Extend
    ; principals =
        [ { id = "agent-alpha"; display_name = Some "agent-alpha" } ]
    ; required_verdicts = Some 1
    }
  in
  let goal, _kind =
    match
      Goal_store.upsert_goal
        config
        ~title:"Verify rollback on phase failure"
        ~verifier_policy
        ()
    with
    | Ok payload -> payload
    | Error msg -> fail msg
  in
  create_done_task config ~goal_id:goal.id ~title:"Rollback vote done task";
  let opened =
    Tool_workspace.dispatch
      (workspace_ctx config)
      ~name:"masc_goal_transition"
      ~args:
        (`Assoc
            [ "goal_id", `String goal.id
            ; "action", `String "request_complete"
            ; "actor", principal_json ~id:"planner"
            ])
  in
  let opened_json =
    match opened with
    | Some result -> parse_json_result result
    | None -> fail "masc_goal_transition not handled"
  in
  let request_id =
    opened_json
    |> Yojson.Safe.Util.member "verification_request"
    |> fun json -> get_string_field json "id"
  in
  let links_path = Workspace_goal_index.goal_task_links_path config in
  let recovery_path = links_path ^ ".last-good" in
  write_file links_path "{goal-links-corrupt-before-verify";
  write_file recovery_path "{goal-links-recovery-corrupt-before-verify";
  let verified =
    Tool_workspace.dispatch
      (workspace_ctx ~agent_name:"agent-alpha" config)
      ~name:"masc_goal_verify"
      ~args:
        (`Assoc
            [ "goal_id", `String goal.id
            ; "request_id", `String request_id
            ; "principal", principal_json ~id:"agent-alpha"
            ; "decision", `String "approve"
            ; "note", `String "checked receipt and tests"
            ; "evidence_refs", `List [ `String "receipt:agent-alpha:rollback" ]
            ])
  in
  let error_json = expect_error verified in
  check
    bool
    "error reports request rollback"
    true
    (contains_substring
       (Yojson.Safe.to_string error_json)
       "restored to open after failed goal phase write");
  let saved_request =
    match Goal_verification.find_request config ~request_id with
    | Some request -> request
    | None -> fail "verification request missing after rollback"
  in
  check
    bool
    "request restored to open"
    true
    (saved_request.status = Goal_verification.Open);
  check int "vote was rolled back" 0 (List.length saved_request.votes);
  let saved_goal =
    match Goal_store.get_goal config ~goal_id:goal.id with
    | Some goal -> goal
    | None -> fail "goal missing after rollback"
  in
  check
    string
    "goal remains awaiting verification"
    "awaiting_verification"
    (Goal_phase.to_string saved_goal.phase);
  check
    string
    "active verification request preserved"
    request_id
    (match saved_goal.active_verification_request_id with
     | Some id -> id
     | None -> fail "active verification request cleared")
;;

let test_goal_completion_override_allows_empty_goal () =
  with_workspace
  @@ fun config ->
  let goal, _kind =
    match Goal_store.upsert_goal config ~title:"Override completion" () with
    | Ok payload -> payload
    | Error msg -> fail msg
  in
  let completed =
    Tool_workspace.dispatch
      (workspace_ctx config)
      ~name:"masc_goal_transition"
      ~args:
        (`Assoc
            [ "goal_id", `String goal.id
            ; "action", `String "request_complete"
            ; "actor", principal_json ~id:"planner"
            ; "override_note", `String "metric-only manual completion"
            ])
  in
  let completed_json =
    match completed with
    | Some result -> parse_json_result result
    | None -> fail "masc_goal_transition not handled"
  in
  check
    string
    "override completes goal"
    "completed"
    (completed_json
     |> Yojson.Safe.Util.member "goal"
     |> fun json -> get_string_field json "phase")
;;

let test_operator_actions_reject_spoofed_actor () =
  with_workspace
  @@ fun config ->
  let goal, _kind =
    match Goal_store.upsert_goal config ~title:"Only operators can block" () with
    | Ok payload -> payload
    | Error msg -> fail msg
  in
  let rejected =
    Tool_workspace.dispatch
      (workspace_ctx config)
      ~name:"masc_goal_transition"
      ~args:
        (`Assoc
            [ "goal_id", `String goal.id
            ; "action", `String "operator_block"
            ; "actor", principal_json ~id:"agent-alpha"
            ])
  in
  let error_json = expect_error rejected in
  check string "spoofed actor rejected" "validation_error" (get_string_field error_json "error_code");
  let saved_goal =
    match Goal_store.get_goal config ~goal_id:goal.id with
    | Some goal -> goal
    | None -> fail "goal missing after rejected operator_block"
  in
  check string "phase unchanged" "executing" (Goal_phase.to_string saved_goal.phase)
;;

let test_completion_approval_rejects_spoofed_actor () =
  with_workspace
  @@ fun config ->
  let goal, _kind =
    match
      Goal_store.upsert_goal
        config
        ~title:"Only operators can approve"
        ~phase:Goal_phase.Awaiting_approval
        ()
    with
    | Ok payload -> payload
    | Error msg -> fail msg
  in
  let rejected =
    Tool_workspace.dispatch
      (workspace_ctx config)
      ~name:"masc_goal_transition"
      ~args:
        (`Assoc
            [ "goal_id", `String goal.id
            ; "action", `String "approve_completion"
            ; "actor", principal_json ~id:"agent-alpha"
            ])
  in
  let error_json = expect_error rejected in
  check string "spoofed approval rejected" "validation_error" (get_string_field error_json "error_code");
  let saved_goal =
    match Goal_store.get_goal config ~goal_id:goal.id with
    | Some goal -> goal
    | None -> fail "goal missing after rejected approve_completion"
  in
  check
    string
    "phase unchanged"
    "awaiting_approval"
    (Goal_phase.to_string saved_goal.phase)
;;

let test_completion_approval_requires_open_request () =
  with_workspace
  @@ fun config ->
  let goal, _kind =
    match
      Goal_store.upsert_goal
        config
        ~title:"Approval without ledger"
        ~phase:Goal_phase.Awaiting_approval
        ()
    with
    | Ok payload -> payload
    | Error msg -> fail msg
  in
  let rejected =
    Tool_workspace.dispatch
      (workspace_ctx config)
      ~name:"masc_goal_transition"
      ~args:
        (`Assoc
            [ "goal_id", `String goal.id
            ; "action", `String "approve_completion"
            ; "actor", principal_json ~id:"planner"
            ])
  in
  let error_json = expect_error rejected in
  check string "missing approval request rejected" "conflict" (get_string_field error_json "error_code");
  let saved_goal =
    match Goal_store.get_goal config ~goal_id:goal.id with
    | Some goal -> goal
    | None -> fail "goal missing after rejected approve_completion"
  in
  check
    string
    "phase unchanged"
    "awaiting_approval"
    (Goal_phase.to_string saved_goal.phase)
;;

let test_goal_approval_open_fails_closed_on_corrupt_state () =
  with_workspace
  @@ fun config ->
  let path = Goal_approval.requests_path config in
  let recovery = path ^ ".last-good" in
  let primary_content = "{not valid json" in
  let recovery_content = {|{"version":"not-an-int","updated_at":false,"requests":[]} |} in
  write_file path primary_content;
  write_file recovery recovery_content;
  let opened_by : Goal_verification.goal_principal =
    { id = "planner"; display_name = None }
  in
  let result =
    Goal_approval.open_request
      config
      ~goal_id:"goal-corrupt"
      ~opened_by
      ()
  in
  (match result with
   | Ok _ -> fail "corrupt approval ledger unexpectedly accepted open_request"
   | Error msg ->
     check
       bool
       "open_request read failure is explicit"
       true
       (contains_substring msg "failed to read goal approval state"));
  check string "primary ledger preserved" primary_content (read_file path);
  check string "recovery ledger preserved" recovery_content (read_file recovery)
;;

let test_goal_approval_resolve_fails_closed_on_corrupt_state () =
  with_workspace
  @@ fun config ->
  let opened_by : Goal_verification.goal_principal =
    { id = "planner"; display_name = None }
  in
  let request =
    match
      Goal_approval.open_request
        config
        ~goal_id:"goal-corrupt-resolve"
        ~opened_by
        ()
    with
    | Ok request -> request
    | Error msg -> fail msg
  in
  let path = Goal_approval.requests_path config in
  let recovery = path ^ ".last-good" in
  let primary_content = "{not valid json" in
  let recovery_content = {|{"version":"not-an-int","updated_at":false,"requests":[]} |} in
  write_file path primary_content;
  write_file recovery recovery_content;
  let result =
    Goal_approval.resolve_open_request
      config
      ~goal_id:request.goal_id
      ~status:Goal_approval.Approved
      ~resolved_by:opened_by
      ()
  in
  (match result with
   | Ok _ -> fail "corrupt approval ledger unexpectedly accepted resolve_open_request"
   | Error msg ->
     check
       bool
       "resolve_open_request read failure is explicit"
       true
       (contains_substring msg "failed to read goal approval state"));
  check string "primary ledger preserved" primary_content (read_file path);
  check string "recovery ledger preserved" recovery_content (read_file recovery)
;;

let test_goal_verify_rejects_spoofed_principal () =
  with_workspace
  @@ fun config ->
  let verifier_policy =
    { Goal_verification.inherit_mode = Goal_verification.Extend
    ; principals =
        [ { id = "agent-alpha"; display_name = Some "agent-alpha" } ]
    ; required_verdicts = Some 1
    }
  in
  let goal, _kind =
    match Goal_store.upsert_goal config ~title:"No forged votes" ~verifier_policy () with
    | Ok payload -> payload
    | Error msg -> fail msg
  in
  create_done_task config ~goal_id:goal.id ~title:"No forged votes done task";
  let transitioned =
    Tool_workspace.dispatch
      (workspace_ctx config)
      ~name:"masc_goal_transition"
      ~args:
        (`Assoc
            [ "goal_id", `String goal.id
            ; "action", `String "request_complete"
            ; "actor", principal_json ~id:"planner"
            ])
  in
  let transitioned_json =
    match transitioned with
    | Some result -> parse_json_result result
    | None -> fail "masc_goal_transition not handled"
  in
  let request_id =
    transitioned_json
    |> Yojson.Safe.Util.member "verification_request"
    |> fun json -> get_string_field json "id"
  in
  let rejected =
    Tool_workspace.dispatch
      (workspace_ctx config)
      ~name:"masc_goal_verify"
      ~args:
        (`Assoc
            [ "goal_id", `String goal.id
            ; "request_id", `String request_id
            ; "principal", principal_json ~id:"agent-alpha"
            ; "decision", `String "approve"
            ])
  in
  let error_json = expect_error rejected in
  check
    string
    "spoofed principal rejected"
    "validation_error"
    (get_string_field error_json "error_code");
  let saved_request =
    match Goal_verification.find_request config ~request_id with
    | Some request -> request
    | None -> fail "verification request missing after spoofed vote"
  in
  check int "no forged vote written" 0 (List.length saved_request.votes)
;;

let test_goal_verify_rejects_cross_goal_request_id () =
  with_workspace
  @@ fun config ->
  let verifier_policy =
    { Goal_verification.inherit_mode = Goal_verification.Extend
    ; principals =
        [ { id = "agent-alpha"; display_name = Some "agent-alpha" } ]
    ; required_verdicts = Some 1
    }
  in
  let create_goal title task_title =
    let goal, _kind =
      match Goal_store.upsert_goal config ~title ~verifier_policy () with
      | Ok payload -> payload
      | Error msg -> fail msg
    in
    create_done_task config ~goal_id:goal.id ~title:task_title;
    goal
  in
  let goal_one = create_goal "Cross goal one" "Cross goal one task" in
  let goal_two = create_goal "Cross goal two" "Cross goal two task" in
  let open_request (goal : Goal_store.goal) =
    let transitioned =
      Tool_workspace.dispatch
        (workspace_ctx config)
        ~name:"masc_goal_transition"
        ~args:
          (`Assoc
              [ "goal_id", `String goal.id
              ; "action", `String "request_complete"
              ; "actor", principal_json ~id:"planner"
              ])
    in
    let transitioned_json =
      match transitioned with
      | Some result -> parse_json_result result
      | None -> fail "masc_goal_transition not handled"
    in
    transitioned_json
    |> Yojson.Safe.Util.member "verification_request"
    |> fun json -> get_string_field json "id"
  in
  let request_one = open_request goal_one in
  let rejected =
    Tool_workspace.dispatch
      (workspace_ctx ~agent_name:"agent-alpha" config)
      ~name:"masc_goal_verify"
      ~args:
        (`Assoc
            [ "goal_id", `String goal_two.id
            ; "request_id", `String request_one
            ; "principal", principal_json ~id:"agent-alpha"
            ; "decision", `String "approve"
            ])
  in
  let error_json = expect_error rejected in
  check string "cross-goal request rejected" "conflict" (get_string_field error_json "error_code");
  let saved_request =
    match Goal_verification.find_request config ~request_id:request_one with
    | Some request -> request
    | None -> fail "verification request missing after cross-goal vote"
  in
  check int "no cross-goal vote written" 0 (List.length saved_request.votes)
;;

let test_goal_verify_rejects_orphan_request_not_active_on_goal () =
  with_workspace
  @@ fun config ->
  let verifier_policy =
    { Goal_verification.inherit_mode = Goal_verification.Extend
    ; principals =
        [ { id = "agent-alpha"; display_name = Some "agent-alpha" } ]
    ; required_verdicts = Some 1
    }
  in
  let goal, _kind =
    match
      Goal_store.upsert_goal
        config
        ~title:"Orphan verification request"
        ~verifier_policy
        ()
    with
    | Ok payload -> payload
    | Error msg -> fail msg
  in
  let requested_by : Goal_verification.goal_principal =
    { id = "planner"; display_name = None }
  in
  let policy_snapshot : Goal_verification.policy_snapshot =
    { principals = verifier_policy.principals
    ; eligible_principals = verifier_policy.principals
    ; required_verdicts = 1
    }
  in
  let request =
    match
      Goal_verification.create_request
        config
        ~goal_id:goal.id
        ~requested_by
        ~policy_snapshot
    with
    | Ok request -> request
    | Error msg -> fail msg
  in
  let rejected =
    Tool_workspace.dispatch
      (workspace_ctx ~agent_name:"agent-alpha" config)
      ~name:"masc_goal_verify"
      ~args:
        (`Assoc
            [ "goal_id", `String goal.id
            ; "request_id", `String request.id
            ; "principal", principal_json ~id:"agent-alpha"
            ; "decision", `String "approve"
            ])
  in
  let error_json = expect_error rejected in
  check string "orphan request rejected" "conflict"
    (get_string_field error_json "error_code");
  check
    bool
    "error names inactive goal verification"
    true
    (contains_substring
       (Yojson.Safe.to_string error_json)
       "is not awaiting verification");
  let saved_request =
    match Goal_verification.find_request config ~request_id:request.id with
    | Some request -> request
    | None -> fail "verification request missing after orphan rejection"
  in
  check int "no orphan vote written" 0 (List.length saved_request.votes);
  let saved_goal =
    match Goal_store.get_goal config ~goal_id:goal.id with
    | Some goal -> goal
    | None -> fail "goal missing after orphan request rejection"
  in
  check string "goal phase unchanged" "executing" (Goal_phase.to_string saved_goal.phase)
;;

let test_goal_transition_cancels_stale_open_request_before_new_request () =
  with_workspace
  @@ fun config ->
  let verifier_policy =
    { Goal_verification.inherit_mode = Goal_verification.Extend
    ; principals =
        [ { id = "agent-alpha"; display_name = Some "agent-alpha" } ]
    ; required_verdicts = Some 1
    }
  in
  let goal, _kind =
    match
      Goal_store.upsert_goal
        config
        ~title:"Cancel stale verification request"
        ~verifier_policy
        ()
    with
    | Ok payload -> payload
    | Error msg -> fail msg
  in
  create_done_task config ~goal_id:goal.id ~title:"Cancel stale request done task";
  let requested_by : Goal_verification.goal_principal =
    { id = "planner"; display_name = None }
  in
  let policy_snapshot : Goal_verification.policy_snapshot =
    { principals = verifier_policy.principals
    ; eligible_principals = verifier_policy.principals
    ; required_verdicts = 1
    }
  in
  let stale_request =
    match
      Goal_verification.create_request
        config
        ~goal_id:goal.id
        ~requested_by
        ~policy_snapshot
    with
    | Ok request -> request
    | Error msg -> fail msg
  in
  let opened =
    Tool_workspace.dispatch
      (workspace_ctx config)
      ~name:"masc_goal_transition"
      ~args:
        (`Assoc
            [ "goal_id", `String goal.id
            ; "action", `String "request_complete"
            ; "actor", principal_json ~id:"planner"
            ])
  in
  let opened_json =
    match opened with
    | Some result -> parse_json_result result
    | None -> fail "masc_goal_transition not handled"
  in
  let active_request_id =
    opened_json
    |> Yojson.Safe.Util.member "verification_request"
    |> fun json -> get_string_field json "id"
  in
  check
    bool
    "new request differs from stale orphan"
    true
    (not (String.equal active_request_id stale_request.id));
  let saved_stale =
    match Goal_verification.find_request config ~request_id:stale_request.id with
    | Some request -> request
    | None -> fail "stale request missing after compensation sweep"
  in
  check
    bool
    "stale request cancelled"
    true
    (saved_stale.status = Goal_verification.Cancelled);
  let saved_active =
    match Goal_verification.find_request config ~request_id:active_request_id with
    | Some request -> request
    | None -> fail "new active request missing"
  in
  check
    bool
    "new request remains open"
    true
    (saved_active.status = Goal_verification.Open);
  let saved_goal =
    match Goal_store.get_goal config ~goal_id:goal.id with
    | Some goal -> goal
    | None -> fail "goal missing after opening verification"
  in
  check
    string
    "goal binds new active request"
    active_request_id
    (match saved_goal.active_verification_request_id with
     | Some request_id -> request_id
     | None -> fail "active request missing on goal");
  let resolved_events = goal_events_by_type config "goal_verification_resolved" in
  check
    bool
    "stale cancellation event emitted"
    true
    (List.exists
       (fun json ->
          contains_substring
            (Yojson.Safe.to_string json)
            "stale_open_request_before_new_verification")
       resolved_events)
;;

let () =
  run
    "goal_tools"
    [ ( "tool_workspace"
      , [ test_case "upsert and list" `Quick test_goal_upsert_and_list
        ; test_case "list filters by phase" `Quick test_goal_list_filters_by_phase
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
            "upsert normalizes no-op verifier policy"
            `Quick
            test_goal_upsert_normalizes_noop_verifier_policy
        ; test_case
            "upsert rejects malformed verifier policy shape"
            `Quick
            test_goal_upsert_rejects_malformed_verifier_policy_shape
        ; test_case
            "verification phase failure source guard"
            `Quick
            test_goal_verification_phase_failure_source_guard
        ; test_case
            "completion phase update rechecks ready source guard"
            `Quick
            test_goal_completion_phase_update_rechecks_ready_source_guard
        ; test_case
            "transition verify complete"
            `Quick
            test_goal_transition_verification_to_completion
        ; test_case
            "goal review removed from dispatch"
            `Quick
            test_goal_review_removed_from_dispatch
        ; test_case
            "rejected verification retains evidence"
            `Quick
            test_goal_transition_rejected_verification_retains_evidence
        ; test_case
            "manual reject cancels verification"
            `Quick
            test_goal_transition_manual_reject_blocks_and_cancels_request
        ; test_case "approval gate" `Quick test_goal_transition_approval_gate
        ; test_case
            "approval semantic errors do not rewrite ledger"
            `Quick
            test_goal_approval_semantic_errors_do_not_rewrite_ledger
        ; test_case
            "completion requires linked task"
            `Quick
            test_goal_completion_requires_linked_task
        ; test_case
            "completion blocks open tasks"
            `Quick
            test_goal_completion_blocks_open_tasks
        ; test_case
            "completion fails closed on corrupt goal-task registry"
            `Quick
            test_goal_completion_fails_closed_on_corrupt_goal_task_registry
        ; test_case
            "goal verify rolls back sealed request on phase failure"
            `Quick
            test_goal_verify_rolls_back_sealed_request_on_phase_failure
        ; test_case
            "completion override allows empty goal"
            `Quick
            test_goal_completion_override_allows_empty_goal
        ; test_case
            "operator actions reject spoofed actor"
            `Quick
            test_operator_actions_reject_spoofed_actor
        ; test_case
            "approval rejects spoofed actor"
            `Quick
            test_completion_approval_rejects_spoofed_actor
        ; test_case
            "approval requires open request"
            `Quick
            test_completion_approval_requires_open_request
        ; test_case
            "approval open fails closed on corrupt state"
            `Quick
            test_goal_approval_open_fails_closed_on_corrupt_state
        ; test_case
            "approval resolve fails closed on corrupt state"
            `Quick
            test_goal_approval_resolve_fails_closed_on_corrupt_state
        ; test_case
            "goal verify rejects spoofed principal"
            `Quick
            test_goal_verify_rejects_spoofed_principal
        ; test_case
            "goal verify rejects cross-goal request id"
            `Quick
            test_goal_verify_rejects_cross_goal_request_id
        ; test_case
            "goal verify rejects orphan inactive request"
            `Quick
            test_goal_verify_rejects_orphan_request_not_active_on_goal
        ; test_case
            "transition cancels stale open request before new request"
            `Quick
            test_goal_transition_cancels_stale_open_request_before_new_request
        ] )
    ]
;;
