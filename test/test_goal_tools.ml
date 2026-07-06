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
       f config)
;;

let make_path_unreadable path =
  if Sys.file_exists path && not (Sys.is_directory path) then Sys.remove path;
  if not (Sys.file_exists path) then Unix.mkdir path 0o755
;;

let replace_path_with_file path content =
  rm_rf path;
  Fs_compat.mkdir_p (Filename.dirname path);
  let oc = open_out path in
  Fun.protect
    ~finally:(fun () -> close_out_noerr oc)
    (fun () -> output_string oc content)
;;

let make_goal_task_link_registry_unreadable config =
  make_path_unreadable (Workspace_goal_index.goal_task_links_path config);
  make_path_unreadable (Workspace_goal_index.goal_task_links_recovery_path config)
;;

let workspace_ctx ?(agent_name = "planner") config : Tool_workspace.context =
  { Tool_workspace.config; agent_name }
;;

let operator_ctx env sw config agent_name : _ Operator_control.context =
  { config
  ; agent_name
  ; sw
  ; clock = Eio.Stdenv.clock env
  ; proc_mgr = Some (Eio.Stdenv.process_mgr env)
  ; net = Some (Eio.Stdenv.net env)
  ; mcp_session_id = None
  }
;;

let with_operator_pending_confirm_hooks f =
  let previous_trace = Atomic.get Workspace_hooks.operator_pending_confirm_trace_id_fn in
  let previous_upsert = Atomic.get Workspace_hooks.operator_pending_confirm_upsert_fn in
  let previous_remove =
    Atomic.get Workspace_hooks.operator_pending_confirm_remove_fn
  in
  Atomic.set
    Workspace_hooks.operator_pending_confirm_trace_id_fn
    Operator_pending_confirm.trace_id;
  Atomic.set
    Workspace_hooks.operator_pending_confirm_upsert_fn
    (fun config (entry : Workspace_hooks.operator_pending_confirm_request) ->
      Operator_pending_confirm.upsert_pending_confirm
        config
        { token = entry.token
        ; trace_id = entry.trace_id
        ; actor = entry.actor
        ; action_type = entry.action_type
        ; target_type = entry.target_type
        ; target_id = entry.target_id
        ; payload = entry.payload
        ; delegated_tool = entry.delegated_tool
        ; created_at = entry.created_at
        ; expires_at = entry.expires_at
        });
  Atomic.set
    Workspace_hooks.operator_pending_confirm_remove_fn
    Operator_pending_confirm.remove_pending_confirm;
  Fun.protect
    ~finally:(fun () ->
      Atomic.set Workspace_hooks.operator_pending_confirm_trace_id_fn previous_trace;
      Atomic.set Workspace_hooks.operator_pending_confirm_upsert_fn previous_upsert;
      Atomic.set
        Workspace_hooks.operator_pending_confirm_remove_fn
        previous_remove)
    f
;;

let parse_json_result (result : Tool_result.result) =
  if (Tool_result.is_success result)
  then Yojson.Safe.from_string ((Tool_result.message result))
  else Alcotest.fail ((Tool_result.message result))
;;

let principal_json ~id = `Assoc [ "id", `String id ]

let principal_json_with_display_name ~id ~display_name =
  `Assoc [ "id", `String id; "display_name", `String display_name ]
;;

let seed_goal_operator (config : Workspace.config) ~agent_name =
  Auth_credential_base.write_initial_admin config.base_path agent_name
;;

let make_keeper_meta ~name ~active_goal_ids =
  match
    Masc_test_deps.meta_of_json_fixture
      (`Assoc
          [ "name", `String name
          ; "agent_name", `String ("agent-" ^ name)
          ; "trace_id", `String ("trace-" ^ name)
          ; "goal", `String "goal verification wake test"
          ; ( "active_goal_ids"
            , `List (List.map (fun goal_id -> `String goal_id) active_goal_ids) )
          ])
  with
  | Ok meta -> meta
  | Error err -> fail ("meta_of_json_fixture failed: " ^ err)
;;

let write_keeper_meta config meta =
  match Keeper_meta_store.write_meta config meta with
  | Ok () -> ()
  | Error err -> fail ("write_meta failed: " ^ err)
;;

let get_string_field json field =
  match Yojson.Safe.Util.member field json with
  | `String value -> value
  | _ -> fail (field ^ " missing")
;;

let get_error_message_field json =
  match Yojson.Safe.Util.member "message" json with
  | `String value -> value
  | _ -> get_string_field json "error"
;;

let get_optional_string_field json field =
  match Yojson.Safe.Util.member field json with
  | `String value -> Some value
  | `Null -> None
  | _ -> fail (field ^ " must be string or null")
;;

let get_string_list_field json field =
  Yojson.Safe.Util.member field json
  |> Yojson.Safe.Util.to_list
  |> List.map Yojson.Safe.Util.to_string
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

let read_file path =
  let ic = open_in_bin path in
  Fun.protect
    ~finally:(fun () -> close_in_noerr ic)
    (fun () -> really_input_string ic (in_channel_length ic))
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

let restamp_goal_updated_at config ~goal_id ~updated_at =
  let state = Goal_store.read_state config in
  Goal_store.write_state
    config
    { state with
      goals =
        List.map
          (fun (goal : Goal_store.goal) ->
             if String.equal goal.id goal_id then { goal with updated_at } else goal)
          state.goals
    ; updated_at
    }
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

let test_goal_list_includes_hygiene_rollup () =
  with_workspace
  @@ fun config ->
  let goal, _kind =
    match Goal_store.upsert_goal config ~title:"Metricless executing goal" () with
    | Ok payload -> payload
    | Error msg -> fail msg
  in
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
  let hygiene = Yojson.Safe.Util.member "hygiene" listed_json in
  check
    int
    "metricless active goal is counted"
    1
    (Yojson.Safe.Util.member "metric_missing_active_count" hygiene
     |> Yojson.Safe.Util.to_int);
  check
    (list string)
    "metricless goal is applyable"
    [ goal.id ]
    (get_string_list_field hygiene "applyable_goal_ids")
;;

let test_goal_hygiene_review_blocks_stale_metricless_executing_goal () =
  with_workspace
  @@ fun config ->
  seed_goal_operator config ~agent_name:"operator";
  let goal, _kind =
    match Goal_store.upsert_goal config ~title:"Stale metricless goal" () with
    | Ok payload -> payload
    | Error msg -> fail msg
  in
  let old_updated_at =
    Masc_domain.iso8601_of_unix_seconds
      (Time_compat.now () -. Masc_time_constants.days_to_seconds 15)
  in
  restamp_goal_updated_at config ~goal_id:goal.id ~updated_at:old_updated_at;
  let reviewed =
    Tool_workspace.dispatch
      (workspace_ctx config)
      ~name:"masc_goal_hygiene_review"
      ~args:(`Assoc [])
  in
  let reviewed_json =
    match reviewed with
    | Some result -> parse_json_result result
    | None -> fail "masc_goal_hygiene_review not handled"
  in
  let hygiene = Yojson.Safe.Util.member "hygiene" reviewed_json in
  check
    int
    "stale executing goal counted"
    1
    (Yojson.Safe.Util.member "stale_executing_count" hygiene
     |> Yojson.Safe.Util.to_int);
  check
    int
    "metricless active goal counted before apply"
    1
    (Yojson.Safe.Util.member "metric_missing_active_count" hygiene
     |> Yojson.Safe.Util.to_int);
  let applied =
    Tool_workspace.dispatch
      (workspace_ctx ~agent_name:"operator" config)
      ~name:"masc_goal_hygiene_review"
      ~args:
        (`Assoc
            [ "apply", `Bool true
            ; "actor", principal_json ~id:"operator"
            ])
  in
  let applied_json =
    match applied with
    | Some result -> parse_json_result result
    | None -> fail "masc_goal_hygiene_review apply not handled"
  in
  check
    int
    "one goal blocked"
    1
    (Yojson.Safe.Util.member "applied_count" applied_json |> Yojson.Safe.Util.to_int);
  let saved_goal =
    match Goal_store.get_goal config ~goal_id:goal.id with
    | Some goal -> goal
    | None -> fail "goal missing after hygiene apply"
  in
  check string "goal blocked" "blocked" (Goal_phase.to_string saved_goal.phase);
  check
    bool
    "review note names G-GHYG"
    true
    (match saved_goal.last_review_note with
     | Some note -> contains_substring note "G-GHYG"
     | None -> false);
  let refreshed_hygiene = Yojson.Safe.Util.member "hygiene" applied_json in
  check
    int
    "blocked goal no longer stale executing"
    0
    (Yojson.Safe.Util.member "stale_executing_count" refreshed_hygiene
     |> Yojson.Safe.Util.to_int);
  check
    int
    "blocked goal no longer active metricless"
    0
    (Yojson.Safe.Util.member "metric_missing_active_count" refreshed_hygiene
     |> Yojson.Safe.Util.to_int)
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

let test_goal_list_reports_goal_store_read_failure () =
  with_workspace
  @@ fun config ->
  replace_path_with_file (Goal_store.goals_path config) "{not-json";
  replace_path_with_file (Goal_store.goals_path config ^ ".last-good") "{not-json";
  match
    Tool_workspace.dispatch
      (workspace_ctx config)
      ~name:"masc_goal_list"
      ~args:(`Assoc [])
  with
  | Some result ->
    check bool "goal list failed" false (Tool_result.is_success result);
    check
      (option string)
      "runtime failure"
      (Some "runtime_failure")
      (Option.map
         Tool_result.tool_failure_class_to_string
         (Tool_result.failure_class result));
    let json = Yojson.Safe.from_string (Tool_result.message result) in
    check string "internal error" "internal_error" (get_string_field json "error_code");
    check
      bool
      "message carries goal ledger read failure"
      true
      (contains_substring (Yojson.Safe.to_string json) "goals.json")
  | None -> fail "masc_goal_list not handled"
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
  let keeper_name = "goal-retry-keeper" in
  write_keeper_meta config (make_keeper_meta ~name:keeper_name ~active_goal_ids:[ goal.id ]);
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
  let wake_json =
    Yojson.Safe.Util.member "goal_verification_failed_wake" rejected_json
  in
  check
    int
    "one assigned keeper got verification failure wake"
    1
    (Yojson.Safe.Util.member "keeper_count" wake_json |> Yojson.Safe.Util.to_int);
  check
    (list string)
    "wake targets assigned keeper"
    [ keeper_name ]
    (get_string_list_field wake_json "keeper_names");
  let queued =
    Keeper_registry_event_queue.snapshot ~base_path:config.base_path keeper_name
    |> Keeper_event_queue.to_list
  in
  let failure =
    queued
    |> List.find_map (fun (stimulus : Keeper_event_queue.stimulus) ->
      match stimulus.payload with
      | Keeper_event_queue.Goal_verification_failed failure -> Some (stimulus, failure)
      | _ -> None)
  in
  (match failure with
   | None -> fail "expected Goal_verification_failed stimulus"
   | Some (stimulus, failure) ->
     check string "stimulus goal id" goal.id failure.goal_id;
     check string "stimulus request id" request_id failure.request_id;
     check string "stimulus rejected by" "agent-alpha" failure.rejected_by;
     check
       string
       "stimulus post id"
       (Keeper_event_queue.goal_verification_failure_post_id failure)
       stimulus.post_id);
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
  seed_goal_operator config ~agent_name:"operator";
  let rejected =
    Tool_workspace.dispatch
      (workspace_ctx ~agent_name:"operator" config)
      ~name:"masc_goal_transition"
      ~args:
        (`Assoc
            [ "goal_id", `String goal.id
            ; "action", `String "reject_completion"
            ; "actor", principal_json ~id:"operator"
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

let test_goal_transition_manual_reject_aborts_when_cancel_fails () =
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
    match Goal_store.upsert_goal config ~title:"Reject with missing request" ~verifier_policy () with
    | Ok payload -> payload
    | Error msg -> fail msg
  in
  create_done_task config ~goal_id:goal.id ~title:"Reject missing request task";
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
  Sys.remove (Goal_verification.requests_path config);
  seed_goal_operator config ~agent_name:"operator";
  let rejected =
    Tool_workspace.dispatch
      (workspace_ctx ~agent_name:"operator" config)
      ~name:"masc_goal_transition"
      ~args:
        (`Assoc
            [ "goal_id", `String goal.id
            ; "action", `String "reject_completion"
            ; "actor", principal_json ~id:"operator"
            ; "note", `String "operator rejected the completion claim"
            ])
  in
  let result =
    match rejected with
    | Some result -> result
    | None -> fail "masc_goal_transition not handled"
  in
  check bool "reject fails when cancel fails" false (Tool_result.is_success result);
  check
    bool
    "failure reports cancel"
    true
    (contains_substring (Tool_result.message result) request_id);
  let saved_goal =
    match Goal_store.get_goal config ~goal_id:goal.id with
    | Some goal -> goal
    | None -> fail "goal missing after failed reject"
  in
  check
    string
    "phase preserved"
    "awaiting_verification"
    (Goal_phase.to_string saved_goal.phase);
  check
    (option string)
    "active request preserved"
    (Some request_id)
    saved_goal.active_verification_request_id
;;

let test_goal_transition_approval_gate () =
  with_operator_pending_confirm_hooks
  @@ fun () ->
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
  seed_goal_operator config ~agent_name:"operator";
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
  let pending_confirms = Operator_pending_confirm.read_pending_confirms config in
  check int "approval request persisted" 1 (List.length pending_confirms);
  let pending_confirm =
    match pending_confirms with
    | [ entry ] -> entry
    | _ -> fail "expected one persisted goal approval request"
  in
  check string "approval action type" Operator_action_constants.goal_completion_decision
    pending_confirm.action_type;
  check string "approval target type" Operator_action_constants.goal_target_type
    pending_confirm.target_type;
  check (option string) "approval target id" (Some goal.id) pending_confirm.target_id;
  check string "approval delegated tool" Operator_action_constants.goal_transition_tool
    pending_confirm.delegated_tool;
  check string "approval actor" "operator" pending_confirm.actor;
  check string "approval request id in payload" request_id
    (pending_confirm.payload
     |> Yojson.Safe.Util.member "request_id"
     |> Yojson.Safe.Util.to_string);
  let approved =
    Tool_workspace.dispatch
      (workspace_ctx ~agent_name:"operator" config)
      ~name:"masc_goal_transition"
      ~args:
        (`Assoc
            [ "goal_id", `String goal.id
            ; "action", `String "approve_completion"
            ; "actor", principal_json ~id:"operator"
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
     |> fun json -> get_string_field json "phase");
  check
    int
    "approval request cleared"
    0
    (List.length (Operator_pending_confirm.read_pending_confirms config))
;;

let with_goal_awaiting_completion_approval ~title f =
  with_operator_pending_confirm_hooks
  @@ fun () ->
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
        ~title
        ~verifier_policy
        ~require_completion_approval:true
        ()
    with
    | Ok payload -> payload
    | Error msg -> fail msg
  in
  seed_goal_operator config ~agent_name:"operator";
  create_done_task config ~goal_id:goal.id ~title:(title ^ " done task");
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
    "fixture phase moved to awaiting_approval"
    "awaiting_approval"
    (verified_json
     |> Yojson.Safe.Util.member "goal"
     |> fun json -> get_string_field json "phase");
  check
    int
    "fixture approval request persisted"
    1
    (List.length (Operator_pending_confirm.read_pending_confirms config));
  f config goal
;;

let test_goal_approval_reject_clears_pending_confirm () =
  with_goal_awaiting_completion_approval
    ~title:"Reject approval cleanup"
    (fun config goal ->
       let rejected =
         Tool_workspace.dispatch
           (workspace_ctx ~agent_name:"operator" config)
           ~name:"masc_goal_transition"
           ~args:
             (`Assoc
                 [ "goal_id", `String goal.id
                 ; "action", `String "reject_completion"
                 ; "actor", principal_json ~id:"operator"
                 ])
       in
       let rejected_json =
         match rejected with
         | Some result -> parse_json_result result
         | None -> fail "masc_goal_transition not handled"
       in
       check
         string
         "reject_completion moves to blocked"
         "blocked"
         (rejected_json
          |> Yojson.Safe.Util.member "goal"
          |> fun json -> get_string_field json "phase");
       check
         int
         "reject_completion clears approval request"
         0
         (List.length (Operator_pending_confirm.read_pending_confirms config)))
;;

let test_goal_approval_drop_clears_pending_confirm () =
  with_goal_awaiting_completion_approval
    ~title:"Drop approval cleanup"
    (fun config goal ->
       let dropped =
         Tool_workspace.dispatch
           (workspace_ctx ~agent_name:"operator" config)
           ~name:"masc_goal_transition"
           ~args:
             (`Assoc
                 [ "goal_id", `String goal.id
                 ; "action", `String "drop"
                 ; "actor", principal_json ~id:"operator"
                 ])
       in
       let dropped_json =
         match dropped with
         | Some result -> parse_json_result result
         | None -> fail "masc_goal_transition not handled"
       in
       check
         string
         "drop moves to dropped"
         "dropped"
         (dropped_json
          |> Yojson.Safe.Util.member "goal"
          |> fun json -> get_string_field json "phase");
       check
         int
         "drop clears approval request"
         0
         (List.length (Operator_pending_confirm.read_pending_confirms config)))
;;

let test_goal_approval_clear_failure_is_reported () =
  with_goal_awaiting_completion_approval
    ~title:"Reject approval clear failure"
    (fun config goal ->
       let previous_remove =
         Atomic.get Workspace_hooks.operator_pending_confirm_remove_fn
       in
       Fun.protect
         ~finally:(fun () ->
           Atomic.set Workspace_hooks.operator_pending_confirm_remove_fn previous_remove)
         (fun () ->
            Atomic.set
              Workspace_hooks.operator_pending_confirm_remove_fn
              (fun _config _token -> Error "forced pending-confirm clear failure");
            let rejected =
              Tool_workspace.dispatch
                (workspace_ctx ~agent_name:"operator" config)
                ~name:"masc_goal_transition"
                ~args:
                  (`Assoc
                      [ "goal_id", `String goal.id
                      ; "action", `String "reject_completion"
                      ; "actor", principal_json ~id:"operator"
                      ])
            in
            let error_json = expect_error rejected in
            check
              string
              "clear failure is surfaced"
              "internal_error"
              (get_string_field error_json "error_code");
            check
              bool
              "error names pending confirm clear"
              true
              (contains_substring
                 (get_error_message_field error_json)
                 "failed to clear goal approval pending confirm");
            check
              int
              "approval request remains when clear fails"
              1
              (List.length (Operator_pending_confirm.read_pending_confirms config))))
;;

let test_goal_principal_display_name_canonicalized () =
  with_workspace
  @@ fun config ->
  let forged_actor_label = "Admin / human reviewer" in
  let forged_vote_label = "Root approver" in
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
        ~title:"Canonical principal labels"
        ~verifier_policy
        ()
    with
    | Ok payload -> payload
    | Error msg -> fail msg
  in
  create_done_task config ~goal_id:goal.id ~title:"Canonical principal done task";
  let transitioned =
    Tool_workspace.dispatch
      (workspace_ctx config)
      ~name:"masc_goal_transition"
      ~args:
        (`Assoc
            [ "goal_id", `String goal.id
            ; "action", `String "request_complete"
            ; ( "actor"
              , principal_json_with_display_name
                  ~id:"planner"
                  ~display_name:forged_actor_label )
            ])
  in
  let transitioned_json =
    match transitioned with
    | Some result -> parse_json_result result
    | None -> fail "masc_goal_transition not handled"
  in
  let request_json = Yojson.Safe.Util.member "verification_request" transitioned_json in
  let request_id = get_string_field request_json "id" in
  let requested_by_json = Yojson.Safe.Util.member "requested_by" request_json in
  check string "requester id remains caller" "planner"
    (get_string_field requested_by_json "id");
  check
    bool
    "requester display label is canonical"
    true
    (Option.is_none (get_optional_string_field requested_by_json "display_name"));
  let saved_open_request =
    match Goal_verification.find_request config ~request_id with
    | Some request -> request
    | None -> fail "verification request missing after transition"
  in
  check
    bool
    "persisted requester display label is canonical"
    true
    (Option.is_none saved_open_request.requested_by.display_name);
  let verified =
    Tool_workspace.dispatch
      (workspace_ctx ~agent_name:"agent-alpha" config)
      ~name:"masc_goal_verify"
      ~args:
        (`Assoc
            [ "goal_id", `String goal.id
            ; "request_id", `String request_id
            ; ( "principal"
              , principal_json_with_display_name
                  ~id:"agent-alpha"
                  ~display_name:forged_vote_label )
            ; "decision", `String "approve"
            ])
  in
  let verified_json =
    match verified with
    | Some result -> parse_json_result result
    | None -> fail "masc_goal_verify not handled"
  in
  let verified_request = Yojson.Safe.Util.member "verification_request" verified_json in
  let vote_json =
    match
      verified_request |> Yojson.Safe.Util.member "votes" |> Yojson.Safe.Util.to_list
    with
    | vote :: _ -> vote
    | [] -> fail "expected verification vote"
  in
  let vote_principal_json = Yojson.Safe.Util.member "principal" vote_json in
  check string "vote principal id remains caller" "agent-alpha"
    (get_string_field vote_principal_json "id");
  check
    bool
    "vote principal display label is canonical"
    true
    (Option.is_none (get_optional_string_field vote_principal_json "display_name"));
  let saved_final_request =
    match Goal_verification.find_request config ~request_id with
    | Some request -> request
    | None -> fail "verification request missing after vote"
  in
  (match saved_final_request.votes with
   | [ vote ] ->
     check
       bool
       "persisted vote display label is canonical"
       true
       (Option.is_none vote.principal.display_name)
   | _ -> fail "expected one persisted vote");
  let event_log =
    read_file (Filename.concat (Workspace_utils.masc_dir config) "goal_events.jsonl")
  in
  check
    bool
    "event log omits forged actor label"
    false
    (contains_substring event_log forged_actor_label);
  check
    bool
    "event log omits forged vote label"
    false
    (contains_substring event_log forged_vote_label)
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
  check string "spoofed principal rejected" "validation_error"
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
  check string "cross-goal request rejected" "conflict"
    (get_string_field error_json "error_code");
  let saved_request =
    match Goal_verification.find_request config ~request_id:request_one with
    | Some request -> request
    | None -> fail "verification request missing after cross-goal vote"
  in
  check int "no cross-goal vote written" 0 (List.length saved_request.votes)
;;

let test_goal_verify_rejects_inactive_request_id () =
  with_workspace
  @@ fun config ->
  let goal, _kind =
    match Goal_store.upsert_goal config ~title:"Inactive request guard" () with
    | Ok payload -> payload
    | Error msg -> fail msg
  in
  let verifier = { Goal_verification.id = "agent-alpha"; display_name = None } in
  let policy_snapshot : Goal_verification.policy_snapshot =
    { principals = [ verifier ]; eligible_principals = [ verifier ]; required_verdicts = 1 }
  in
  let request =
    match
      Goal_verification.create_request
        config
        ~goal_id:goal.id
        ~requested_by:{ id = "planner"; display_name = None }
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
  check string "inactive request rejected" "conflict"
    (get_string_field error_json "error_code");
  check string "inactive request error" "goal verification request is not active on this goal"
    (get_error_message_field error_json);
  let saved_request =
    match Goal_verification.find_request config ~request_id:request.id with
    | Some request -> request
    | None -> fail "verification request missing after inactive vote"
  in
  check int "no inactive-request vote written" 0 (List.length saved_request.votes);
  let saved_goal =
    match Goal_store.get_goal config ~goal_id:goal.id with
    | Some goal -> goal
    | None -> fail "goal missing after inactive vote"
  in
  check string "phase unchanged" (Goal_phase.to_string goal.phase)
    (Goal_phase.to_string saved_goal.phase)
;;

let test_goal_verify_rejects_non_active_request_id () =
  with_workspace
  @@ fun config ->
  let verifier = { Goal_verification.id = "agent-alpha"; display_name = None } in
  let verifier_policy =
    { Goal_verification.inherit_mode = Goal_verification.Extend
    ; principals = [ verifier ]
    ; required_verdicts = Some 1
    }
  in
  let goal, _kind =
    match Goal_store.upsert_goal config ~title:"Reject stale request" ~verifier_policy () with
    | Ok payload -> payload
    | Error msg -> fail msg
  in
  create_done_task config ~goal_id:goal.id ~title:"Reject stale request task";
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
  let active_request_id =
    transitioned_json
    |> Yojson.Safe.Util.member "verification_request"
    |> fun json -> get_string_field json "id"
  in
  let policy_snapshot : Goal_verification.policy_snapshot =
    { principals = [ verifier ]; eligible_principals = [ verifier ]; required_verdicts = 1 }
  in
  let stale_request =
    match
      Goal_verification.create_request
        config
        ~goal_id:goal.id
        ~requested_by:{ id = "planner"; display_name = None }
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
            ; "request_id", `String stale_request.id
            ; "principal", principal_json ~id:"agent-alpha"
            ; "decision", `String "approve"
            ])
  in
  let error_json = expect_error rejected in
  check string "non-active request rejected" "conflict"
    (get_string_field error_json "error_code");
  check string "non-active request error" "goal verification request is not active on this goal"
    (get_error_message_field error_json);
  let saved_goal =
    match Goal_store.get_goal config ~goal_id:goal.id with
    | Some goal -> goal
    | None -> fail "goal missing after stale request vote"
  in
  check
    (option string)
    "active request unchanged"
    (Some active_request_id)
    saved_goal.active_verification_request_id;
  let saved_stale_request =
    match Goal_verification.find_request config ~request_id:stale_request.id with
    | Some request -> request
    | None -> fail "stale verification request missing after rejected vote"
  in
  check int "no stale-request vote written" 0 (List.length saved_stale_request.votes)
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

let test_goal_completion_reports_goal_link_read_failure () =
  with_workspace
  @@ fun config ->
  let goal, _kind =
    match Goal_store.upsert_goal config ~title:"Unreadable link registry completion" () with
    | Ok payload -> payload
    | Error msg -> fail msg
  in
  ignore
    (Workspace_task.add_task
       ~goal_id:goal.id
       config
       ~title:"Linked but registry unreadable"
       ~priority:3
       ~description:"open");
  make_goal_task_link_registry_unreadable config;
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
    "goal link read failure blocks completion"
    "conflict"
    (get_string_field error_json "error_code");
  check
    bool
    "error reports goal link read failure"
    true
    (contains_substring
       (Yojson.Safe.to_string error_json)
       Workspace_goal_index.goal_task_links_read_failed_prefix)
;;

let test_dashboard_goals_tree_reports_goal_link_read_failure () =
  with_workspace
  @@ fun config ->
  let goal, _kind =
    match Goal_store.upsert_goal config ~title:"Dashboard goal link read failure" () with
    | Ok payload -> payload
    | Error msg -> fail msg
  in
  ignore
    (Workspace_task.add_task
       ~goal_id:goal.id
       config
       ~title:"Dashboard linked task"
       ~priority:3
       ~description:"open");
  make_goal_task_link_registry_unreadable config;
  let json = Dashboard_goals.dashboard_goals_tree_json ~config in
  check
    string
    "dashboard goals status unknown"
    "unknown"
    (get_string_field json "status");
  check
    bool
    "dashboard goals marks goal links unknown"
    false
    (Yojson.Safe.Util.member "goal_task_links_known" json |> Yojson.Safe.Util.to_bool);
  check
    bool
    "dashboard goals read error recorded"
    true
    (contains_substring
       (Yojson.Safe.Util.member "goal_task_links_read_error" json
        |> Yojson.Safe.Util.to_string)
       Workspace_goal_index.goal_task_links_read_failed_prefix);
  check
    yojson_t
    "tree omitted when link registry unreadable"
    (`List [])
    (Yojson.Safe.Util.member "tree" json);
  check
    yojson_t
    "task count is unknown"
    `Null
    (json
     |> Yojson.Safe.Util.member "summary"
     |> Yojson.Safe.Util.member "total_tasks")
;;

let test_dashboard_goals_tree_reports_goal_store_read_failure () =
  with_workspace
  @@ fun config ->
  replace_path_with_file (Goal_store.goals_path config) "{not-json";
  replace_path_with_file (Goal_store.goals_path config ^ ".last-good") "{not-json";
  let json = Dashboard_goals.dashboard_goals_tree_json ~config in
  check
    string
    "dashboard goals status unknown"
    "unknown"
    (get_string_field json "status");
  check
    bool
    "dashboard goals marks goal store unknown"
    false
    (Yojson.Safe.Util.member "goal_store_known" json |> Yojson.Safe.Util.to_bool);
  check
    bool
    "dashboard goals goal store read error recorded"
    true
    (contains_substring
       (Yojson.Safe.Util.member "goal_store_read_error" json
        |> Yojson.Safe.Util.to_string)
       "goals.json");
  check
    yojson_t
    "goal task link error not forged"
    `Null
    (Yojson.Safe.Util.member "goal_task_links_read_error" json);
  check
    yojson_t
    "tree omitted when goal store unreadable"
    (`List [])
    (Yojson.Safe.Util.member "tree" json)
;;

let test_dashboard_goals_tree_surfaces_keeper_meta_read_failure () =
  with_workspace
  @@ fun config ->
  ignore
    (Goal_store.upsert_goal
       config
       ~title:"Dashboard keeper meta read failure"
       ());
  replace_path_with_file
    (Keeper_types_profile.keeper_dir config)
    "not a keeper directory";
  let json = Dashboard_goals.dashboard_goals_tree_json ~config in
  check string "dashboard goals status remains ok" "ok" (get_string_field json "status");
  check
    bool
    "dashboard goals marks keeper meta unknown"
    false
    (Yojson.Safe.Util.member "keeper_meta_known" json |> Yojson.Safe.Util.to_bool);
  let read_errors =
    Yojson.Safe.Util.member "keeper_meta_read_errors" json |> Yojson.Safe.Util.to_list
  in
  check bool "keeper meta read error recorded" true (read_errors <> []);
  check
    bool
    "keeper meta read error mentions keeper_names_result"
    true
    (contains_substring
       (Yojson.Safe.to_string (`List read_errors))
       "keeper_names_result")
;;

let test_goal_completion_blocks_unevaluated_metric () =
  with_workspace
  @@ fun config ->
  let goal, _kind =
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
  create_done_task config ~goal_id:goal.id ~title:"Metric done task";
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
    "metric completion blocked"
    "conflict"
    (get_string_field error_json "error_code");
  check
    bool
    "error mentions metric evaluation"
    true
    (contains_substring (Yojson.Safe.to_string error_json) "has not been evaluated")
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

let test_goal_transition_rejects_spoofed_actor () =
  with_workspace
  @@ fun config ->
  let goal, _kind =
    match Goal_store.upsert_goal config ~title:"No forged actor" () with
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
            ; "action", `String "pause"
            ; "actor", principal_json ~id:"agent-alpha"
            ])
  in
  let error_json = expect_error rejected in
  check string "spoofed actor rejected" "validation_error"
    (get_string_field error_json "error_code");
  let saved_goal =
    match Goal_store.get_goal config ~goal_id:goal.id with
    | Some goal -> goal
    | None -> fail "goal missing after spoofed actor rejection"
  in
  check string "phase unchanged" "executing" (Goal_phase.to_string saved_goal.phase)
;;

let test_operator_actions_require_operator_caller () =
  with_workspace
  @@ fun config ->
  let goal, _kind =
    match Goal_store.upsert_goal config ~title:"Only operators can block" () with
    | Ok payload -> payload
    | Error msg -> fail msg
  in
  let rejected =
    Tool_workspace.dispatch
      (workspace_ctx ~agent_name:"agent-alpha" config)
      ~name:"masc_goal_transition"
      ~args:
        (`Assoc
            [ "goal_id", `String goal.id
            ; "action", `String "operator_block"
            ; "actor", principal_json ~id:"agent-alpha"
            ])
  in
  let error_json = expect_error rejected in
  check string "non-operator rejected" "conflict" (get_string_field error_json "error_code");
  let saved_goal =
    match Goal_store.get_goal config ~goal_id:goal.id with
    | Some goal -> goal
    | None -> fail "goal missing after operator rejection"
  in
  check string "phase unchanged" "executing" (Goal_phase.to_string saved_goal.phase)
;;

let test_operator_actions_accept_authenticated_operator () =
  with_workspace
  @@ fun config ->
  seed_goal_operator config ~agent_name:"operator";
  let goal, _kind =
    match Goal_store.upsert_goal config ~title:"Operator can block" () with
    | Ok payload -> payload
    | Error msg -> fail msg
  in
  let blocked =
    Tool_workspace.dispatch
      (workspace_ctx ~agent_name:"operator" config)
      ~name:"masc_goal_transition"
      ~args:
        (`Assoc
            [ "goal_id", `String goal.id
            ; "action", `String "operator_block"
            ; "actor", principal_json ~id:"operator"
            ])
  in
  let blocked_json =
    match blocked with
    | Some result -> parse_json_result result
    | None -> fail "masc_goal_transition not handled"
  in
  check
    string
    "operator transition blocks goal"
    "blocked"
    (blocked_json
     |> Yojson.Safe.Util.member "goal"
     |> fun json -> get_string_field json "phase")
;;

let test_completion_approval_requires_operator_caller () =
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
  let approved =
    Tool_workspace.dispatch
      (workspace_ctx ~agent_name:"agent-alpha" config)
      ~name:"masc_goal_transition"
      ~args:
        (`Assoc
            [ "goal_id", `String goal.id
            ; "action", `String "approve_completion"
            ; "actor", principal_json ~id:"agent-alpha"
            ])
  in
  let error_json = expect_error approved in
  check string "non-operator approval rejected" "conflict"
    (get_string_field error_json "error_code");
  let saved_goal =
    match Goal_store.get_goal config ~goal_id:goal.id with
    | Some goal -> goal
    | None -> fail "goal missing after approve_completion rejection"
  in
  check
    string
    "phase unchanged"
    "awaiting_approval"
    (Goal_phase.to_string saved_goal.phase)
;;

let test_goal_approval_operator_action_registered () =
  check bool "allowed action" true
    (Operator_approval.is_allowed Operator_action_constants.goal_completion_decision);
  check bool "confirm required" true
    (Operator_approval.confirm_required Operator_action_constants.goal_completion_decision);
  let action =
    List.find_opt
      (fun (action : Operator_pending_confirm.available_action) ->
         String.equal
           action.action_type
           Operator_action_constants.goal_completion_decision)
      Operator_pending_confirm.available_actions
  in
  match action with
  | None ->
    fail
      (Operator_action_constants.goal_completion_decision
       ^ " missing from available actions")
  | Some action ->
    check string "tool" Operator_action_constants.goal_transition_tool action.tool_name;
    check string "target type" Operator_action_constants.goal_target_type action.target_type;
    check bool "registry confirm required" true action.confirm_required
;;

let test_operator_goal_decision_requires_explicit_decision () =
  Eio_main.run
  @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  Eio.Switch.run
  @@ fun sw ->
  let dir = temp_dir () in
  Fun.protect
    ~finally:(fun () -> rm_rf dir)
    (fun () ->
       let config = Workspace.default_config dir in
       ignore (Workspace.init config ~agent_name:(Some "operator"));
       let ctx = operator_ctx env sw config "operator" in
       let assert_rejected ~token payload =
        (match
           Operator_pending_confirm.upsert_pending_confirm
             config
             { token
             ; trace_id = "goal_missing_decision"
             ; actor = "operator"
             ; action_type = Operator_action_constants.goal_completion_decision
             ; target_type = Operator_action_constants.goal_target_type
             ; target_id = Some "goal-1"
             ; payload
             ; delegated_tool = Operator_action_constants.goal_transition_tool
             ; created_at = Masc_domain.now_iso ()
             ; expires_at = None
             }
         with
         | Ok () -> ()
         | Error msg -> fail msg);
         match
           Operator_control.confirm_json
             ctx
             (`Assoc
                 [ "actor", `String "operator"; "confirm_token", `String token ])
         with
         | Ok _ -> fail "goal decision without explicit decision should reject"
         | Error msg -> check string "decision rejection" "payload.decision is required" msg
       in
       assert_rejected ~token:"missing-decision" (`Assoc []);
       assert_rejected
         ~token:"blank-decision"
         (`Assoc [ "decision", `String "  " ]))
;;

let () =
  run
    "goal_tools"
    [ ( "tool_workspace"
      , [ test_case "upsert and list" `Quick test_goal_upsert_and_list
        ; test_case "list filters by phase" `Quick test_goal_list_filters_by_phase
        ; test_case
            "list includes hygiene rollup"
            `Quick
            test_goal_list_includes_hygiene_rollup
        ; test_case
            "hygiene review blocks stale metricless executing goal"
            `Quick
            test_goal_hygiene_review_blocks_stale_metricless_executing_goal
        ; test_case
            "list ignores blank optional filters"
            `Quick
            test_goal_list_ignores_blank_optional_filters
        ; test_case
            "list rejects status filter"
            `Quick
            test_goal_list_rejects_status_filter
        ; test_case
            "list reports goal store read failure"
            `Quick
            test_goal_list_reports_goal_store_read_failure
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
        ; test_case
            "manual reject aborts when cancel fails"
            `Quick
            test_goal_transition_manual_reject_aborts_when_cancel_fails
        ; test_case "approval gate" `Quick test_goal_transition_approval_gate
        ; test_case
            "approval reject clears pending confirm"
            `Quick
            test_goal_approval_reject_clears_pending_confirm
        ; test_case
            "approval drop clears pending confirm"
            `Quick
            test_goal_approval_drop_clears_pending_confirm
        ; test_case
            "approval clear failure is reported"
            `Quick
            test_goal_approval_clear_failure_is_reported
        ; test_case
            "principal display labels are canonicalized"
            `Quick
            test_goal_principal_display_name_canonicalized
        ; test_case
            "verify rejects spoofed principal"
            `Quick
            test_goal_verify_rejects_spoofed_principal
        ; test_case
            "verify rejects cross-goal request"
            `Quick
            test_goal_verify_rejects_cross_goal_request_id
        ; test_case
            "verify rejects inactive request"
            `Quick
            test_goal_verify_rejects_inactive_request_id
        ; test_case
            "verify rejects non-active request"
            `Quick
            test_goal_verify_rejects_non_active_request_id
        ; test_case
            "completion requires linked task"
            `Quick
            test_goal_completion_requires_linked_task
        ; test_case
            "completion blocks open tasks"
            `Quick
            test_goal_completion_blocks_open_tasks
        ; test_case
            "completion reports goal link read failure"
            `Quick
            test_goal_completion_reports_goal_link_read_failure
        ; test_case
            "dashboard goals tree reports goal link read failure"
            `Quick
            test_dashboard_goals_tree_reports_goal_link_read_failure
        ; test_case
            "dashboard goals tree reports goal store read failure"
            `Quick
            test_dashboard_goals_tree_reports_goal_store_read_failure
        ; test_case
            "dashboard goals tree surfaces keeper meta read failure"
            `Quick
            test_dashboard_goals_tree_surfaces_keeper_meta_read_failure
        ; test_case
            "completion blocks unevaluated metric"
            `Quick
            test_goal_completion_blocks_unevaluated_metric
        ; test_case
            "completion override allows empty goal"
            `Quick
            test_goal_completion_override_allows_empty_goal
        ; test_case
            "transition rejects spoofed actor"
            `Quick
            test_goal_transition_rejects_spoofed_actor
        ; test_case
            "operator actions require operator caller"
            `Quick
            test_operator_actions_require_operator_caller
        ; test_case
            "operator actions accept authenticated operator"
            `Quick
            test_operator_actions_accept_authenticated_operator
        ; test_case
            "approval requires operator caller"
            `Quick
            test_completion_approval_requires_operator_caller
        ; test_case
            "approval operator action registered"
            `Quick
            test_goal_approval_operator_action_registered
        ; test_case
            "operator goal decision requires explicit decision"
            `Quick
            test_operator_goal_decision_requires_explicit_decision
        ] )
    ]
;;
