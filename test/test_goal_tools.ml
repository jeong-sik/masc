module Types = Masc_domain

(** Goal tool coverage — shared Goal Store surface through Tool_coord. *)

open Alcotest
open Masc_mcp
open Coord_types
open Tool_coord

let temp_dir () =
  let path = Filename.temp_file "goal_tool_test" "" in
  Sys.remove path;
  Unix.mkdir path 0o755;
  path

let rm_rf dir =
  let rec rm path =
    if Sys.file_exists path then
      if Sys.is_directory path then begin
        Sys.readdir path
        |> Array.iter (fun entry -> rm (Filename.concat path entry));
        Unix.rmdir path
      end else
        Sys.remove path
  in
  try rm dir with _ -> ()

let with_room f =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let dir = temp_dir () in
  Fun.protect ~finally:(fun () -> rm_rf dir) (fun () ->
    let config = Coord.default_config dir in
    ignore (Coord.init config ~agent_name:(Some "planner"));
    f config)

let coord_ctx config : Tool_coord.context =
  { Tool_coord.config; agent_name = "planner" }

let parse_json_result (result : Tool_coord.tool_result) =
  match result with
  | { success = true; message = body } -> Yojson.Safe.from_string body
  | { success = false; message = body } -> fail body

let principal_json ~kind ~id =
  `Assoc [ ("kind", `String kind); ("id", `String id) ]

let get_string_field json field =
  match Yojson.Safe.Util.member field json with
  | `String value -> value
  | _ -> fail (field ^ " missing")

let get_string_list_field json field =
  Yojson.Safe.Util.member field json
  |> Yojson.Safe.Util.to_list
  |> List.map Yojson.Safe.Util.to_string

let json_is_null = function
  | `Null -> true
  | _ -> false

let contains_substring s needle =
  let s_len = String.length s in
  let n_len = String.length needle in
  let rec loop i =
    if n_len = 0 then true
    else if i + n_len > s_len then false
    else if String.sub s i n_len = needle then true
    else loop (i + 1)
  in
  loop 0

let create_done_task config ~goal_id ~title =
  ignore
    (Coord_task.add_task ~goal_id config ~title ~priority:3
       ~description:"done task fixture");
  let task_id =
    Coord.get_tasks_raw config
    |> List.find_map (fun (task : Masc_domain.task) ->
           if String.equal task.title title then Some task.id else None)
    |> function
    | Some task_id -> task_id
    | None -> fail ("task not found: " ^ title)
  in
  let step action notes =
    match
      Coord.transition_task_r config ~agent_name:"planner" ~task_id ~action
        ~notes ()
    with
    | Ok _ -> ()
    | Error err -> fail (Masc_domain.masc_error_to_string err)
  in
  step Masc_domain.Claim "test fixture claim";
  step Masc_domain.Start "test fixture start";
  step Masc_domain.Done_action "test fixture done"

let expect_error (result : Tool_coord.tool_result option) =
  match result with
  | Some { success = false; message = body } -> Yojson.Safe.from_string body
  | Some { success = true; message = _ } -> fail "expected tool error"
  | None -> fail "tool not handled"

let test_goal_upsert_and_list () =
  with_room @@ fun config ->
  let created =
    Tool_coord.dispatch (coord_ctx config) ~name:"masc_goal_upsert"
      ~args:
        (`Assoc
          [
            ("title", `String "Ship Goal Surface");
            ("horizon", `String "mid");
            ("priority", `Int 2);
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
  let task_marker =
    match Yojson.Safe.Util.member "task_title_marker" created_json with
    | `String marker -> marker
    | _ -> fail "task_title_marker missing from upsert response"
  in
  check bool "task marker embeds goal id" true
    (String.equal task_marker (Printf.sprintf "[goal:%s]" goal_id));
  let task_link_field =
    match Yojson.Safe.Util.member "task_link_field" created_json with
    | `String field -> field
    | _ -> fail "task_link_field missing from upsert response"
  in
  check string "structured link field" "goal_id" task_link_field;
  let listed =
    Tool_coord.dispatch (coord_ctx config) ~name:"masc_goal_list"
      ~args:(`Assoc [ ("horizon", `String "mid") ])
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
  check int "one listed goal" 1 count

let test_goal_list_filters_by_phase () =
  with_room @@ fun config ->
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
    Tool_coord.dispatch (coord_ctx config) ~name:"masc_goal_list"
      ~args:(`Assoc [ ("phase", `String "blocked") ])
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
      check string "phase filter honored" "blocked"
        (get_string_field goal_json "phase")
  | _ -> fail "expected one filtered goal"

let test_goal_list_ignores_blank_optional_filters () =
  with_room @@ fun config ->
  (match Goal_store.upsert_goal config ~title:"Blank filter goal" () with
   | Ok _ -> ()
   | Error msg -> fail msg);
  let listed =
    Tool_coord.dispatch (coord_ctx config) ~name:"masc_goal_list"
      ~args:
        (`Assoc
          [
            ("horizon", `String "");
            ("phase", `String "");
            ("status", `String "");
          ])
  in
  let listed_json =
    match listed with
    | Some result -> parse_json_result result
    | None -> fail "masc_goal_list not handled"
  in
  check int "blank filters are ignored" 1
    (Yojson.Safe.Util.member "count" listed_json |> Yojson.Safe.Util.to_int)

let test_goal_upsert_rejects_lifecycle_fields () =
  with_room @@ fun config ->
  let rejected_phase =
    Tool_coord.dispatch (coord_ctx config) ~name:"masc_goal_upsert"
      ~args:
        (`Assoc
          [
            ("title", `String "Bypass block");
            ("phase", `String "blocked");
          ])
  in
  let phase_error = expect_error rejected_phase in
  check string "phase blocked" "validation_error"
    (get_string_field phase_error "error_code");
  check bool "phase error points at transition" true
    (contains_substring (Yojson.Safe.to_string phase_error) "masc_goal_transition");
  let goal, _kind =
    match Goal_store.upsert_goal config ~title:"Existing goal" () with
    | Ok payload -> payload
    | Error msg -> fail msg
  in
  let rejected_status =
    Tool_coord.dispatch (coord_ctx config) ~name:"masc_goal_upsert"
      ~args:
        (`Assoc
          [
            ("id", `String goal.id);
            ("status", `String "dropped");
          ])
  in
  let status_error = expect_error rejected_status in
  check string "terminal status blocked" "validation_error"
    (get_string_field status_error "error_code");
  let saved_goal =
    match Goal_store.get_goal config ~goal_id:goal.id with
    | Some goal -> goal
    | None -> fail "goal missing after rejected upsert"
  in
  check string "phase unchanged after rejected status" "executing"
    (Goal_phase.to_string saved_goal.phase)

let test_goal_upsert_normalizes_noop_verifier_policy () =
  let assert_no_policy args =
    with_room @@ fun config ->
    let created =
      Tool_coord.dispatch (coord_ctx config) ~name:"masc_goal_upsert"
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
    check bool "verifier policy omitted" true
      (Option.is_none saved_goal.verifier_policy)
  in
  assert_no_policy [ ("verifier_policy", `Assoc []) ];
  assert_no_policy
    [ ("verifier_policy", `Assoc [ ("mode", `String "none") ]) ]

let test_goal_upsert_rejects_malformed_verifier_policy_shape () =
  with_room @@ fun config ->
  let rejected =
    Tool_coord.dispatch (coord_ctx config) ~name:"masc_goal_upsert"
      ~args:
        (`Assoc
          [
            ("title", `String "Malformed verifier policy");
            ("verifier_policy", `Assoc [ ("mode", `String "review") ]);
          ])
  in
  let error = expect_error rejected in
  check string "validation error" "validation_error"
    (get_string_field error "error_code");
  check bool "error includes accepted policy shapes" true
    (contains_substring (Yojson.Safe.to_string error)
       "accepted verifier_policy shapes")

let test_goal_review_updates_status () =
  with_room @@ fun config ->
  let goal, _kind =
    match Goal_store.upsert_goal config ~title:"Review me" () with
    | Ok payload -> payload
    | Error msg -> fail msg
  in
  create_done_task config ~goal_id:goal.id ~title:"Review done task";
  let reviewed =
    Tool_coord.dispatch (coord_ctx config) ~name:"masc_goal_review"
      ~args:
        (`Assoc
          [
            ("goal_id", `String goal.id);
            ("outcome", `String "done");
            ("note", `String "completed from test");
          ])
  in
  let reviewed_json =
    match reviewed with
    | Some result -> parse_json_result result
    | None -> fail "masc_goal_review not handled"
  in
  let goal_json = Yojson.Safe.Util.member "goal" reviewed_json in
  let status =
    match Yojson.Safe.Util.member "status" goal_json with
    | `String s -> s
    | _ -> fail "status missing from goal review response"
  in
  check string "status updated to done" "done" status

let test_goal_transition_verification_to_completion () =
  with_room @@ fun config ->
  let verifier_policy =
    {
      Goal_verification.inherit_mode = Goal_verification.Extend;
      principals =
        [
          {
            kind = Goal_verification.Keeper;
            id = "keeper-alpha";
            display_name = Some "keeper-alpha";
          };
        ];
      required_verdicts = Some 1;
    }
  in
  let goal, _kind =
    match Goal_store.upsert_goal config ~title:"Verify me" ~verifier_policy () with
    | Ok payload -> payload
    | Error msg -> fail msg
  in
  create_done_task config ~goal_id:goal.id ~title:"Verify done task";
  let transitioned =
    Tool_coord.dispatch (coord_ctx config) ~name:"masc_goal_transition"
      ~args:
        (`Assoc
          [
            ("goal_id", `String goal.id);
            ("action", `String "request_complete");
            ("actor", principal_json ~kind:"operator" ~id:"planner");
          ])
  in
  let transitioned_json =
    match transitioned with
    | Some result -> parse_json_result result
    | None -> fail "masc_goal_transition not handled"
  in
  let transitioned_goal = Yojson.Safe.Util.member "goal" transitioned_json in
  check string "phase moved to awaiting_verification" "awaiting_verification"
    (get_string_field transitioned_goal "phase");
  let request_json =
    Yojson.Safe.Util.member "verification_request" transitioned_json
  in
  let request_id = get_string_field request_json "id" in
  let transitioned_summary =
    Yojson.Safe.Util.member "verification_summary" transitioned_json
  in
  check string "latest request visible while open" request_id
    (transitioned_summary
    |> Yojson.Safe.Util.member "latest_request"
    |> fun json -> get_string_field json "id");
  let verified =
    Tool_coord.dispatch (coord_ctx config) ~name:"masc_goal_verify"
      ~args:
        (`Assoc
          [
            ("goal_id", `String goal.id);
            ("request_id", `String request_id);
            ("principal", principal_json ~kind:"keeper" ~id:"keeper-alpha");
            ("decision", `String "approve");
            ("note", `String "checked receipt and tests");
            ( "evidence_refs",
              `List
                [
                  `String "receipt:keeper-alpha:turn-7";
                  `String "test:test_goal_tools";
                ] );
          ])
  in
  let verified_json =
    match verified with
    | Some result -> parse_json_result result
    | None -> fail "masc_goal_verify not handled"
  in
  let verified_goal = Yojson.Safe.Util.member "goal" verified_json in
  check string "phase moved to completed" "completed"
    (get_string_field verified_goal "phase");
  let verified_summary =
    Yojson.Safe.Util.member "verification_summary" verified_json
  in
  check bool "open request cleared after approve" true
    (verified_summary |> Yojson.Safe.Util.member "open_request" |> json_is_null);
  check int "approve count follows latest request" 1
    (verified_summary |> Yojson.Safe.Util.member "approve_count"
    |> Yojson.Safe.Util.to_int);
  let latest_request =
    Yojson.Safe.Util.member "latest_request" verified_summary
  in
  check string "approved latest request retained" request_id
    (get_string_field latest_request "id");
  check string "latest request status approved" "approved"
    (get_string_field latest_request "status");
  let vote =
    match latest_request |> Yojson.Safe.Util.member "votes" |> Yojson.Safe.Util.to_list with
    | vote :: _ -> vote
    | [] -> fail "expected verification vote"
  in
  check string "vote note retained" "checked receipt and tests"
    (get_string_field vote "note");
  check (list string) "vote evidence refs retained"
    [ "receipt:keeper-alpha:turn-7"; "test:test_goal_tools" ]
    (get_string_list_field vote "evidence_refs")

let test_goal_transition_rejected_verification_retains_evidence () =
  with_room @@ fun config ->
  let verifier_policy =
    {
      Goal_verification.inherit_mode = Goal_verification.Extend;
      principals =
        [
          {
            kind = Goal_verification.Keeper;
            id = "keeper-alpha";
            display_name = Some "keeper-alpha";
          };
        ];
      required_verdicts = Some 1;
    }
  in
  let goal, _kind =
    match Goal_store.upsert_goal config ~title:"Reject me" ~verifier_policy () with
    | Ok payload -> payload
    | Error msg -> fail msg
  in
  create_done_task config ~goal_id:goal.id ~title:"Reject done task";
  let transitioned =
    Tool_coord.dispatch (coord_ctx config) ~name:"masc_goal_transition"
      ~args:
        (`Assoc
          [
            ("goal_id", `String goal.id);
            ("action", `String "request_complete");
            ("actor", principal_json ~kind:"operator" ~id:"planner");
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
    Tool_coord.dispatch (coord_ctx config) ~name:"masc_goal_verify"
      ~args:
        (`Assoc
          [
            ("goal_id", `String goal.id);
            ("request_id", `String request_id);
            ("principal", principal_json ~kind:"keeper" ~id:"keeper-alpha");
            ("decision", `String "reject");
            ("note", `String "receipt did not prove completion");
            ("evidence_refs", `List [ `String "receipt:keeper-alpha:turn-7" ]);
          ])
  in
  let rejected_json =
    match rejected with
    | Some result -> parse_json_result result
    | None -> fail "masc_goal_verify not handled"
  in
  check string "phase moved back to executing" "executing"
    (rejected_json |> Yojson.Safe.Util.member "goal" |> fun json ->
     get_string_field json "phase");
  let latest_request =
    rejected_json
    |> Yojson.Safe.Util.member "verification_summary"
    |> Yojson.Safe.Util.member "latest_request"
  in
  check int "reject count follows latest request" 1
    (rejected_json
    |> Yojson.Safe.Util.member "verification_summary"
    |> Yojson.Safe.Util.member "reject_count"
    |> Yojson.Safe.Util.to_int);
  check string "latest request status rejected" "rejected"
    (get_string_field latest_request "status");
  let vote =
    match latest_request |> Yojson.Safe.Util.member "votes" |> Yojson.Safe.Util.to_list with
    | vote :: _ -> vote
    | [] -> fail "expected reject vote"
  in
  check string "reject note retained" "receipt did not prove completion"
    (get_string_field vote "note");
  check (list string) "reject evidence retained"
    [ "receipt:keeper-alpha:turn-7" ]
    (get_string_list_field vote "evidence_refs")

let test_goal_transition_approval_gate () =
  with_room @@ fun config ->
  let verifier_policy =
    {
      Goal_verification.inherit_mode = Goal_verification.Extend;
      principals =
        [
          {
            kind = Goal_verification.Keeper;
            id = "keeper-alpha";
            display_name = Some "keeper-alpha";
          };
        ];
      required_verdicts = Some 1;
    }
  in
  let goal, _kind =
    match
      Goal_store.upsert_goal config ~title:"Approve me" ~verifier_policy
        ~require_completion_approval:true ()
    with
    | Ok payload -> payload
    | Error msg -> fail msg
  in
  create_done_task config ~goal_id:goal.id ~title:"Approval done task";
  let transitioned =
    Tool_coord.dispatch (coord_ctx config) ~name:"masc_goal_transition"
      ~args:
        (`Assoc
          [
            ("goal_id", `String goal.id);
            ("action", `String "request_complete");
            ("actor", principal_json ~kind:"operator" ~id:"planner");
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
    Tool_coord.dispatch (coord_ctx config) ~name:"masc_goal_verify"
      ~args:
        (`Assoc
          [
            ("goal_id", `String goal.id);
            ("request_id", `String request_id);
            ("principal", principal_json ~kind:"keeper" ~id:"keeper-alpha");
            ("decision", `String "approve");
          ])
  in
  let verified_json =
    match verified with
    | Some result -> parse_json_result result
    | None -> fail "masc_goal_verify not handled"
  in
  check string "phase moved to awaiting_approval" "awaiting_approval"
    (verified_json |> Yojson.Safe.Util.member "goal" |> fun json ->
     get_string_field json "phase");
  let approved =
    Tool_coord.dispatch (coord_ctx config) ~name:"masc_goal_transition"
      ~args:
        (`Assoc
          [
            ("goal_id", `String goal.id);
            ("action", `String "approve_completion");
            ("actor", principal_json ~kind:"operator" ~id:"planner");
          ])
  in
  let approved_json =
    match approved with
    | Some result -> parse_json_result result
    | None -> fail "masc_goal_transition not handled"
  in
  check string "phase moved to completed after approval" "completed"
    (approved_json |> Yojson.Safe.Util.member "goal" |> fun json ->
     get_string_field json "phase")

let test_goal_review_done_uses_transition_flow () =
  with_room @@ fun config ->
  let verifier_policy =
    {
      Goal_verification.inherit_mode = Goal_verification.Extend;
      principals =
        [
          {
            kind = Goal_verification.Keeper;
            id = "keeper-alpha";
            display_name = Some "keeper-alpha";
          };
        ];
      required_verdicts = Some 1;
    }
  in
  let goal, _kind =
    match Goal_store.upsert_goal config ~title:"Compat me" ~verifier_policy () with
    | Ok payload -> payload
    | Error msg -> fail msg
  in
  create_done_task config ~goal_id:goal.id ~title:"Compat done task";
  let reviewed =
    Tool_coord.dispatch (coord_ctx config) ~name:"masc_goal_review"
      ~args:
        (`Assoc
          [
            ("goal_id", `String goal.id);
            ("outcome", `String "done");
          ])
  in
  let reviewed_json =
    match reviewed with
    | Some result -> parse_json_result result
    | None -> fail "masc_goal_review not handled"
  in
  check string "legacy done routes to awaiting_verification"
    "awaiting_verification"
    (reviewed_json |> Yojson.Safe.Util.member "goal" |> fun json ->
     get_string_field json "phase")

let test_goal_completion_requires_linked_task () =
  with_room @@ fun config ->
  let goal, _kind =
    match Goal_store.upsert_goal config ~title:"No task completion" () with
    | Ok payload -> payload
    | Error msg -> fail msg
  in
  let completed =
    Tool_coord.dispatch (coord_ctx config) ~name:"masc_goal_transition"
      ~args:
        (`Assoc
          [
            ("goal_id", `String goal.id);
            ("action", `String "request_complete");
            ("actor", principal_json ~kind:"operator" ~id:"planner");
          ])
  in
  let error_json = expect_error completed in
  check string "zero task completion blocked" "conflict"
    (get_string_field error_json "error_code");
  check bool "error mentions linked task" true
    (contains_substring (Yojson.Safe.to_string error_json) "linked task")

let test_goal_completion_blocks_open_tasks () =
  with_room @@ fun config ->
  let goal, _kind =
    match Goal_store.upsert_goal config ~title:"Open task completion" () with
    | Ok payload -> payload
    | Error msg -> fail msg
  in
  ignore
    (Coord_task.add_task ~goal_id:goal.id config ~title:"Still open"
       ~priority:3 ~description:"open");
  let completed =
    Tool_coord.dispatch (coord_ctx config) ~name:"masc_goal_transition"
      ~args:
        (`Assoc
          [
            ("goal_id", `String goal.id);
            ("action", `String "request_complete");
            ("actor", principal_json ~kind:"operator" ~id:"planner");
          ])
  in
  let error_json = expect_error completed in
  check string "open task completion blocked" "conflict"
    (get_string_field error_json "error_code")

let test_goal_completion_override_allows_empty_goal () =
  with_room @@ fun config ->
  let goal, _kind =
    match Goal_store.upsert_goal config ~title:"Override completion" () with
    | Ok payload -> payload
    | Error msg -> fail msg
  in
  let completed =
    Tool_coord.dispatch (coord_ctx config) ~name:"masc_goal_transition"
      ~args:
        (`Assoc
          [
            ("goal_id", `String goal.id);
            ("action", `String "request_complete");
            ("actor", principal_json ~kind:"operator" ~id:"planner");
            ("override_note", `String "metric-only manual completion");
          ])
  in
  let completed_json =
    match completed with
    | Some result -> parse_json_result result
    | None -> fail "masc_goal_transition not handled"
  in
  check string "override completes goal" "completed"
    (completed_json |> Yojson.Safe.Util.member "goal" |> fun json ->
     get_string_field json "phase")

let test_operator_actions_require_operator_principal () =
  with_room @@ fun config ->
  let goal, _kind =
    match Goal_store.upsert_goal config ~title:"Only operators can block" () with
    | Ok payload -> payload
    | Error msg -> fail msg
  in
  let blocked =
    Tool_coord.dispatch (coord_ctx config) ~name:"masc_goal_transition"
      ~args:
        (`Assoc
          [
            ("goal_id", `String goal.id);
            ("action", `String "operator_block");
            ("actor", principal_json ~kind:"keeper" ~id:"keeper-alpha");
          ])
  in
  let error_json = expect_error blocked in
  check string "keeper blocked by validation"
    "validation_error"
    (get_string_field error_json "error_code");
  let saved_goal =
    match Goal_store.get_goal config ~goal_id:goal.id with
    | Some goal -> goal
    | None -> fail "goal missing after rejected operator_block"
  in
  check string "phase unchanged" "executing"
    (Goal_phase.to_string saved_goal.phase)

let test_completion_approval_requires_operator_principal () =
  with_room @@ fun config ->
  let goal, _kind =
    match
      Goal_store.upsert_goal config ~title:"Only operators can approve"
        ~phase:Goal_phase.Awaiting_approval ()
    with
    | Ok payload -> payload
    | Error msg -> fail msg
  in
  let approved =
    Tool_coord.dispatch (coord_ctx config) ~name:"masc_goal_transition"
      ~args:
        (`Assoc
          [
            ("goal_id", `String goal.id);
            ("action", `String "approve_completion");
            ("actor", principal_json ~kind:"keeper" ~id:"keeper-alpha");
          ])
  in
  let error_json = expect_error approved in
  check string "keeper approval blocked by validation"
    "validation_error"
    (get_string_field error_json "error_code");
  let saved_goal =
    match Goal_store.get_goal config ~goal_id:goal.id with
    | Some goal -> goal
    | None -> fail "goal missing after rejected approve_completion"
  in
  check string "phase unchanged" "awaiting_approval"
    (Goal_phase.to_string saved_goal.phase)

let () =
  run "goal_tools"
    [
      ( "tool_coord",
        [
          test_case "upsert and list" `Quick test_goal_upsert_and_list;
          test_case "list filters by phase" `Quick test_goal_list_filters_by_phase;
          test_case "list ignores blank optional filters" `Quick
            test_goal_list_ignores_blank_optional_filters;
          test_case "upsert rejects lifecycle fields" `Quick
            test_goal_upsert_rejects_lifecycle_fields;
          test_case "upsert normalizes no-op verifier policy" `Quick
            test_goal_upsert_normalizes_noop_verifier_policy;
          test_case "upsert rejects malformed verifier policy shape" `Quick
            test_goal_upsert_rejects_malformed_verifier_policy_shape;
          test_case "review updates status" `Quick test_goal_review_updates_status;
          test_case "transition verify complete" `Quick
            test_goal_transition_verification_to_completion;
          test_case "rejected verification retains evidence" `Quick
            test_goal_transition_rejected_verification_retains_evidence;
          test_case "approval gate" `Quick
            test_goal_transition_approval_gate;
          test_case "review done compatibility" `Quick
            test_goal_review_done_uses_transition_flow;
          test_case "completion requires linked task" `Quick
            test_goal_completion_requires_linked_task;
          test_case "completion blocks open tasks" `Quick
            test_goal_completion_blocks_open_tasks;
          test_case "completion override allows empty goal" `Quick
            test_goal_completion_override_allows_empty_goal;
          test_case "operator-only actions enforce operator principal" `Quick
            test_operator_actions_require_operator_principal;
          test_case "approval requires operator principal" `Quick
            test_completion_approval_requires_operator_principal;
        ] );
    ]
