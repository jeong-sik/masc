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

;;

let expect_error (result : Tool_result.result option) =
  match result with
  | Some r when not (Tool_result.is_success r) -> Yojson.Safe.from_string ((Tool_result.message r))
  | Some r ->
    fail (Printf.sprintf "expected tool error, got success: %s" ((Tool_result.message r)))
  | None -> fail "tool not handled"
;;

let test_goal_list_preserves_source_failure () =
  with_workspace @@ fun config ->
  let list () = Tool_workspace.dispatch (workspace_ctx config)
    ~name:"masc_goal_list" ~args:(`Assoc []) in
  let _goal, _ = match Goal_store.upsert_goal config ~title:"Visible source"
      ~metric:"goals" ~target_value:"1" () with
    | Ok value -> value | Error detail -> fail detail
  in
  let path = Goal_store.goals_path config in
  let mirror = Fs_compat.load_file (path ^ ".last-good") in
  Fs_compat.save_file path "unreadable primary";
  let error = expect_error (list ()) in
  check string "source error is not an empty successful list" "internal_error"
    (get_string_field error "error_code");
  check string "listing preserves the primary bytes" "unreadable primary"
    (Fs_compat.load_file path);
  check string "listing preserves recovery bytes" mirror
    (Fs_compat.load_file (path ^ ".last-good"))
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
            ; "metric", `String "deploys shipped"
            ; "target_value", `String "1"
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
    match Goal_store.upsert_goal config ~title ~metric:"m" ~target_value:"1"
            ~phase () with
    | Ok _ -> ()
    | Error msg -> fail msg
  in
  create ~title:"Executing goal" ~phase:"executing";
  create ~title:"Dropped goal" ~phase:"dropped";
  let listed =
    Tool_workspace.dispatch
      (workspace_ctx config)
      ~name:"masc_goal_list"
      ~args:(`Assoc [ "phase", `String "dropped" ])
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
    check string "phase filter honored" "dropped" (get_string_field goal_json "phase")
  | _ -> fail "expected one filtered goal"
;;

let test_goal_list_includes_rollup () =
  with_workspace
  @@ fun config ->
  (match Goal_store.upsert_goal config ~title:"Executing goal" ~metric:"m"
           ~target_value:"1" () with
   | Ok _ -> ()
   | Error msg -> fail msg);
  (match Goal_store.upsert_goal config ~title:"Verifying goal" ~metric:"m"
           ~target_value:"1" ~phase:Goal_phase.Verifying () with
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
    (Yojson.Safe.Util.member "active_count" rollup |> Yojson.Safe.Util.to_int);
  check int "verifying goal is counted" 1
    (Yojson.Safe.Util.member "verifying_count" rollup |> Yojson.Safe.Util.to_int)
;;
let test_goal_list_ignores_blank_optional_filters () =
  with_workspace
  @@ fun config ->
  (match Goal_store.upsert_goal config ~title:"Blank filter goal" ~metric:"m"
           ~target_value:"1" () with
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
    (String_util.contains_substring (Yojson.Safe.to_string error_json) "status filter was removed");
  let field_errors =
    Yojson.Safe.Util.member "field_errors" error_json |> Yojson.Safe.Util.to_list
  in
  match field_errors with
  | field_error :: _ ->
    check string "field" "status" (get_string_field field_error "field")
  | [] -> fail "expected status field error"
;;

let test_goal_creation_emits_an_event () =
  with_workspace
  @@ fun config ->
  let events_path =
    Filename.concat
      (Filename.dirname (Goal_store.goals_path config))
      "goal_events.jsonl"
  in
  let events () =
    if Sys.file_exists events_path
    then
      Fs_compat.load_file events_path
      |> String.split_on_char '\n'
      |> List.filter (fun line -> String.trim line <> "")
    else []
  in
  check int "no goal has been opened yet" 0 (List.length (events ()));
  let upsert args =
    Tool_workspace.dispatch
      (workspace_ctx config)
      ~name:"masc_goal_upsert"
      ~args:(`Assoc args)
  in
  let created =
    match
      upsert
        [ "title", `String "Close the goal ledger"
        ; "metric", `String "goals counted"
        ; "target_value", `String "1"
        ]
    with
    | Some result -> parse_json_result result
    | None -> fail "masc_goal_upsert not handled"
  in
  let goal_id = get_string_field created "goal_id" in
  let lines = events () in
  check int "opening a goal records one event" 1 (List.length lines);
  let event = Yojson.Safe.from_string (List.hd lines) in
  check string "the event names creation" "goal_created"
    (get_string_field event "event_type");
  check string "the event names its goal" goal_id (get_string_field event "goal_id");
  (* The title has to outlive the goal's row in goals.json, which holds only the
     current set, so it travels in the payload rather than only in the store. *)
  check string "the payload carries the title as created" "Close the goal ledger"
    (get_string_field (Yojson.Safe.Util.member "payload" event) "title");
  (match upsert [ "id", `String goal_id; "title", `String "Renamed after the fact" ] with
   | Some _ -> ()
   | None -> fail "masc_goal_upsert not handled on update");
  check int "editing a goal is not a second beginning" 1 (List.length (events ()))
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
    (String_util.contains_substring (Yojson.Safe.to_string phase_error) "masc_goal_transition");
  let goal, _kind =
    match Goal_store.upsert_goal config ~title:"Existing goal" ~metric:"m"
            ~target_value:"1" () with
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

let request_complete config goal_id =
  Tool_workspace.dispatch
    (workspace_ctx config)
    ~name:"masc_goal_transition"
    ~args:
      (`Assoc
         [ "goal_id", `String goal_id
         ; "action", `String "request_complete"
         ])
;;

(* RFC-0387 stage 2: [request_complete] enters [Verifying]; [Completed] is
   reached only through the verifier's proof. *)
let prove_complete config goal_id =
  let request_id, criterion =
    match Goal_verification.get_record_authoritative config ~goal_id with
    | Ok (Some { Goal_verification.completion = Goal_verification.Proof_pending pending; _ }) ->
      pending.request_id, pending.criterion
    | _ -> fail "proof requires a durable pending request"
  in
  Some
    (Workspace_goals.commit_verifier_decision
       ~tool_name:"goal_verifier_commit"
       ~start_time:0.
       config
       ~goal_id
       ~request_id
       ~criterion
       ~verification_run_id:"goal-verifier-test-run"
       ~decision:Workspace_goals.Proof_proven
       ~evidence:"observed by the test verifier")
;;

let test_goal_completion_accepts_goal_without_tasks () =
  with_workspace
  @@ fun config ->
  let goal, _ =
    match
      Goal_store.upsert_goal config ~title:"Direct completion" ~metric:"m"
        ~target_value:"1" ()
    with
    | Ok payload -> payload
    | Error msg -> fail msg
  in
  check string "completion request enters verifying" "verifying"
    (transition_phase (request_complete config goal.id));
  check string "proof completes the goal" "awaiting_confirmation"
    (transition_phase (prove_complete config goal.id))
;;

let test_goal_completion_ignores_open_task_count () =
  with_workspace
  @@ fun config ->
  let goal, _ =
    match
      Goal_store.upsert_goal config ~title:"Open task completion" ~metric:"m"
        ~target_value:"1" ()
    with
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
  check string "open task does not gate the completion request" "verifying"
    (transition_phase (request_complete config goal.id));
  check string "proof completes the goal" "awaiting_confirmation"
    (transition_phase (prove_complete config goal.id))
;;

let test_goal_completion_ignores_metric_text () =
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
  check string "metric text does not gate the completion request" "verifying"
    (transition_phase (request_complete config goal.id));
  check string "proof completes the goal" "awaiting_confirmation"
    (transition_phase (prove_complete config goal.id))
;;
let test_confirmation_uses_token_bound_operator () =
  with_workspace @@ fun config ->
  Auth.save_auth_config config.base_path
    {Types.default_auth_config with enabled = true; require_token = true};
  let token role name = match Auth.create_token config.base_path ~agent_name:name ~role with
    | Ok (token, _) -> token | Error error -> fail (Types.masc_error_to_string error) in
  let worker = token Types.Worker "worker" and operator = token Types.Admin "operator" in
  let authorize token =
    let request = Httpun.Request.create ~headers:(Httpun.Headers.of_list
      ["authorization", "Bearer " ^ token; "x-agent-name", "pretend-human"])
      `POST "/api/v1/goals/confirmation" in
    Server_auth.authorize_token_bound_permission_request ~base_path:config.base_path
      ~permission:Types.CanAdmin request in
  (match authorize worker with Error _ -> () | Ok _ -> fail "Worker token became operator");
  (match authorize operator with
   | Ok actor -> check string "actor comes from credential, never header" "operator" actor
   | Error error -> fail (Types.masc_error_to_string error))
;;

let test_operator_confirmation_binds_current_proof () =
  with_workspace @@ fun config ->
  let goal, _ = match Goal_store.upsert_goal config ~title:"Human confirmed goal"
    ~metric:"observed artifacts" ~target_value:"1" () with
    | Ok value -> value | Error detail -> fail detail in
  ignore (request_complete config goal.id);
  check string "verifier cannot complete" "awaiting_confirmation"
    (transition_phase (prove_complete config goal.id));
  let verdict = match Goal_verification.get_record_authoritative config ~goal_id:goal.id with
    | Ok (Some {completion = Goal_verification.Proof_proven verdict; _}) -> verdict
    | _ -> fail "missing current proof" in
  let confirm ?(request_id=verdict.request_id) ?(run_id=verdict.verification_run_id)
      ?(operator_id="authenticated-operator") () =
    Server_routes_http_routes_verification.For_testing.commit_goal_confirmation_json
      ~config ~operator_id (`Assoc ["goal_id", `String goal.id;
        "criterion_revision", `String goal.criterion_revision; "request_id", `String request_id;
        "verification_run_id", `String run_id]) in
  (match confirm ~request_id:"another-request" () with
   | Error _ -> () | Ok _ -> fail "stale request accepted");
  (match confirm ~run_id:"another-run" () with
   | Error _ -> () | Ok _ -> fail "wrong verifier run accepted");
  (* Simulate the narrow crash boundary after durable confirmation but before
     the goal phase write, then retry the actual application operation. *)
  (match Goal_verification.record_human_confirmation config ~goal_id:goal.id verdict
      ~operator_id:"authenticated-operator" with
   | Ok _ -> () | Error detail -> fail detail);
  let first = match confirm ~operator_id:"another-operator" () with Ok json -> json | Error detail -> fail detail in
  check string "operator confirmation completes" "completed"
    Yojson.Safe.Util.(member "goal" first |> member "phase" |> to_string);
  let history_path = Filename.concat (Workspace_utils.masc_dir config) "goal_events.jsonl" in
  let history = Fs_compat.load_file history_path in
  let completion_events = String.split_on_char '\n' history
    |> List.filter (fun line -> line <> "") |> List.map Yojson.Safe.from_string
    |> List.filter (fun json -> Yojson.Safe.Util.(member "payload" json |> member "phase") = `String "completed") in
  (match completion_events with
   | [event] -> check string "crash retry event credits persisted first operator" "authenticated-operator"
       Yojson.Safe.Util.(member "payload" event |> member "actor" |> to_string)
   | _ -> fail "expected one completion event");
  let second_operator = Workspace_goals.confirm_completion config ~goal_id:goal.id
    ~operator_id:"another-operator" ~criterion_revision:goal.criterion_revision
    ~request_id:verdict.request_id ~verification_run_id:verdict.verification_run_id in
  (match second_operator with
   | Ok json -> check bool "retry never rewrites original operator attribution" true (first = json)
   | Error detail -> fail detail);
  (match Server_routes_http_routes_verification.For_testing.commit_goal_confirmation_json
    ~config ~operator_id:"credential-owner" (`Assoc ["actor", `String "human"] ) with
   | Error _ -> () | Ok _ -> fail "body actor impersonation accepted");
  let second = match confirm () with Ok json -> json | Error detail -> fail detail in
  check bool "exact confirmation replay preserves timestamp and identity" true (first = second);
  check string "retries emit no duplicate confirmation event" history (Fs_compat.load_file history_path);
  (match Goal_verification.reopen_goal config ~goal_id:goal.id ~actor:"operator" ~note:None with
   | Ok _ -> () | Error detail -> fail detail);
  (match confirm () with Error _ -> () | Ok _ -> fail "reopen retained old confirmation authority");
  ignore (request_complete config goal.id);
  ignore (prove_complete config goal.id);
  (match confirm () with Error _ -> () | Ok _ -> fail "new request accepted old confirmation binding");
  (match Goal_store.upsert_goal config ~id:goal.id ~title:"Changed criterion"
     ~metric:"observed artifacts" ~target_value:"2" () with
   | Ok _ -> () | Error detail -> fail detail);
  (match confirm () with Error _ -> () | Ok _ -> fail "changed criterion accepted stale proof")
;;

let () =
  run
    "goal_tools"
    [ ( "tool_workspace"
      , [ test_case "confirmation requires token-bound operator" `Quick test_confirmation_uses_token_bound_operator
        ; test_case "operator confirms exact current proof" `Quick test_operator_confirmation_binds_current_proof
        ; test_case "upsert and list" `Quick test_goal_upsert_and_list
        ; test_case "list preserves source failure" `Quick test_goal_list_preserves_source_failure
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
            "creating a goal emits an event"
            `Quick
            test_goal_creation_emits_an_event
        ; test_case
            "goal review removed from dispatch"
            `Quick
            test_goal_review_removed_from_dispatch
        ; test_case
            "completion accepts no linked tasks"
            `Quick
            test_goal_completion_accepts_goal_without_tasks
        ; test_case
            "completion ignores open task count"
            `Quick
            test_goal_completion_ignores_open_task_count
        ; test_case
            "completion ignores metric text"
            `Quick
            test_goal_completion_ignores_metric_text
        ] )
    ]
;;
