(** Coord_goals - Handlers for goal management tools. *)

open Coord_types
open Tool_args

let goal_horizon_strings = [ "short"; "mid"; "long" ]
let goal_status_strings = [ "active"; "paused"; "done"; "dropped" ]
let goal_phase_strings =
  [
    "executing";
    "awaiting_verification";
    "awaiting_approval";
    "blocked";
    "paused";
    "completed";
    "dropped";
  ]

let goal_review_outcome_strings = [ "done"; "progress"; "blocked"; "dropped" ]
let goal_transition_action_strings =
  [
    "request_complete";
    "approve_completion";
    "reject_completion";
    "pause";
    "resume";
    "operator_block";
    "operator_unblock";
    "drop";
    "reopen";
  ]

let goal_vote_decision_strings = [ "approve"; "reject" ]
let goal_principal_kind_strings = [ "operator"; "keeper" ]

let make_enum_field_error ~field ~allowed ~received =
  {
    field;
    constraint_violated = One_of allowed;
    message =
      Printf.sprintf "%s must be one of: %s" field (String.concat ", " allowed);
    expected = Some (String.concat "|" allowed);
    received = Some received;
  }

let make_type_field_error ~field ~constraint_violated ~expected ~received =
  {
    field;
    constraint_violated;
    message = Printf.sprintf "%s must be a %s" field expected;
    expected = Some expected;
    received = Some received;
  }

let parse_optional_horizon args field =
  match Yojson.Safe.Util.member field args with
  | `Null -> Ok None
  | `String raw -> (
      match Goal_store.parse_horizon (Some raw) with
      | Some horizon -> Ok (Some horizon)
      | None ->
          Error
            (make_enum_field_error ~field ~allowed:goal_horizon_strings
               ~received:raw))
  | json ->
      Error
        (make_type_field_error ~field ~constraint_violated:Type_string
           ~expected:"string"
           ~received:(Yojson.Safe.to_string json))

let parse_optional_goal_status args field =
  match Yojson.Safe.Util.member field args with
  | `Null -> Ok None
  | `String raw -> (
      match Goal_store.parse_goal_status (Some raw) with
      | Some status -> Ok (Some status)
      | None ->
          Error
            (make_enum_field_error ~field ~allowed:goal_status_strings
               ~received:raw))
  | json ->
      Error
        (make_type_field_error ~field ~constraint_violated:Type_string
           ~expected:"string"
           ~received:(Yojson.Safe.to_string json))

let parse_optional_goal_phase args field =
  match Yojson.Safe.Util.member field args with
  | `Null -> Ok None
  | `String raw -> (
      match Goal_store.parse_goal_phase (Some raw) with
      | Some phase -> Ok (Some phase)
      | None ->
          Error
            (make_enum_field_error ~field ~allowed:goal_phase_strings
               ~received:raw))
  | json ->
      Error
        (make_type_field_error ~field ~constraint_violated:Type_string
           ~expected:"string"
           ~received:(Yojson.Safe.to_string json))

let parse_optional_review_outcome args field =
  match Yojson.Safe.Util.member field args with
  | `Null -> Ok None
  | `String raw -> (
      match Goal_store.parse_review_outcome raw with
      | Some outcome -> Ok (Some outcome)
      | None ->
          Error
            (make_enum_field_error ~field ~allowed:goal_review_outcome_strings
               ~received:raw))
  | json ->
      Error
        (make_type_field_error ~field ~constraint_violated:Type_string
           ~expected:"string"
           ~received:(Yojson.Safe.to_string json))

let parse_optional_priority args field =
  match Yojson.Safe.Util.member field args with
  | `Null -> Ok None
  | `Int n ->
      if n < 1 || n > 5 then
        Error
          {
            field;
            constraint_violated = Min_int 1;
            message = "priority must be between 1 and 5";
            expected = Some "1..5";
            received = Some (string_of_int n);
          }
      else Ok (Some n)
  | json ->
      Error
        (make_type_field_error ~field ~constraint_violated:Type_int
           ~expected:"integer"
           ~received:(Yojson.Safe.to_string json))

let parse_optional_bool args field =
  match Yojson.Safe.Util.member field args with
  | `Null -> Ok None
  | `Bool value -> Ok (Some value)
  | json ->
      Error
        (make_type_field_error ~field ~constraint_violated:Type_bool
           ~expected:"boolean"
           ~received:(Yojson.Safe.to_string json))

let parse_optional_policy args field =
  match Yojson.Safe.Util.member field args with
  | `Null -> Ok None
  | json -> (
      match Goal_verification.goal_verifier_policy_of_yojson json with
      | Ok policy -> Ok (Some policy)
      | Error msg ->
          Error
            {
              field;
              constraint_violated = Type_string;
              message = msg;
              expected = Some "goal_verifier_policy";
              received = Some (Yojson.Safe.to_string json);
            })

let parse_optional_principal args field =
  match Yojson.Safe.Util.member field args with
  | `Null -> Ok None
  | json -> (
      match Goal_verification.goal_principal_of_yojson json with
      | Ok principal -> Ok (Some principal)
      | Error msg ->
          Error
            {
              field;
              constraint_violated = Type_string;
              message = msg;
              expected = Some "goal_principal";
              received = Some (Yojson.Safe.to_string json);
            })

let parse_optional_vote_decision args field =
  match Yojson.Safe.Util.member field args with
  | `Null -> Ok None
  | `String raw -> (
      match
        String.trim raw |> String.lowercase_ascii
        |> Goal_verification.vote_decision_of_string
      with
      | Some decision -> Ok (Some decision)
      | None ->
          Error
            (make_enum_field_error ~field ~allowed:goal_vote_decision_strings
               ~received:raw))
  | json ->
      Error
        (make_type_field_error ~field ~constraint_violated:Type_string
           ~expected:"string"
           ~received:(Yojson.Safe.to_string json))

let parse_optional_transition_action args field =
  match Yojson.Safe.Util.member field args with
  | `Null -> Ok None
  | `String raw -> (
      match Goal_phase.parse_action raw with
      | Some action -> Ok (Some action)
      | None ->
          Error
            (make_enum_field_error ~field ~allowed:goal_transition_action_strings
               ~received:raw))
  | json ->
      Error
        (make_type_field_error ~field ~constraint_violated:Type_string
           ~expected:"string"
           ~received:(Yojson.Safe.to_string json))

let actor_must_be_operator action =
  match action with
  | Goal_phase.Operator_block
  | Goal_phase.Operator_unblock
  | Goal_phase.Approve_completion
  | Goal_phase.Reject_completion ->
      true
  | Goal_phase.Request_complete
  | Goal_phase.Pause
  | Goal_phase.Resume
  | Goal_phase.Drop
  | Goal_phase.Reopen ->
      false

let parse_optional_string_list args field =
  match Yojson.Safe.Util.member field args with
  | `Null -> Ok None
  | `List values -> (
      try Ok (Some (List.map Yojson.Safe.Util.to_string values))
      with _ ->
        Error
          (make_type_field_error ~field ~constraint_violated:Type_string
             ~expected:"string[]"
             ~received:(Yojson.Safe.to_string (`List values))))
  | json ->
      Error
        (make_type_field_error ~field ~constraint_violated:Type_string
           ~expected:"string[]"
           ~received:(Yojson.Safe.to_string json))

let goal_policy_nodes goals =
  List.map
    (fun (goal : Goal_store.goal) ->
      {
        Goal_verification.goal_id = goal.id;
        parent_goal_id = goal.parent_goal_id;
        verifier_policy = goal.verifier_policy;
      })
    goals

let verification_summary_json (goal : Goal_store.goal)
    (effective_policy : Goal_verification.policy_snapshot option)
    (open_request : Goal_verification.goal_verification_request option) =
  let effective_policy_json =
    match effective_policy with
    | None -> `Null
    | Some policy -> Goal_verification.policy_snapshot_to_yojson policy
  in
  let open_request_json =
    match open_request with
    | None -> `Null
    | Some request -> Goal_verification.goal_verification_request_to_yojson request
  in
  let approve_count, reject_count, remaining_possible =
    match open_request with
    | None -> (0, 0, 0)
    | Some request ->
        ( Goal_verification.count_votes ~decision:Goal_verification.Approve request,
          Goal_verification.count_votes ~decision:Goal_verification.Reject request,
          Goal_verification.remaining_possible_votes request )
  in
  `Assoc
    [
      ("phase", Goal_phase.to_yojson goal.phase);
      ("effective_policy", effective_policy_json);
      ("open_request", open_request_json);
      ("approve_count", `Int approve_count);
      ("reject_count", `Int reject_count);
      ("remaining_possible", `Int remaining_possible);
      ("pending_verification_count", `Int (if open_request = None then 0 else 1));
    ]

let update_goal_phase (ctx : context) (goal : Goal_store.goal) ~phase ?note
    ?active_verification_request_id ?(clear_active_verification_request = false)
    () =
  let last_review_note, last_review_at =
    match note with
    | Some note -> (Some note, Some (Types.now_iso ()))
    | None -> (goal.last_review_note, goal.last_review_at)
  in
  Goal_store.update_goal ctx.config ~goal_id:goal.id (fun current ->
      {
        current with
        phase;
        status = Goal_store.goal_status_of_phase phase;
        active_verification_request_id =
          (if clear_active_verification_request then
             None
           else match active_verification_request_id with
          | Some value -> Some value
          | None -> current.active_verification_request_id);
        last_review_note;
        last_review_at;
      })

let emit_goal_event ctx ~goal_id ~event_type ~payload =
  Goal_verification.emit_event ctx.config ~goal_id ~event_type ~payload

let handle_goal_list (ctx : context) args =
  match
    parse_optional_horizon args "horizon",
    parse_optional_goal_status args "status",
    parse_optional_goal_phase args "phase"
  with
  | Error err, _, _
  | _, Error err, _
  | _, _, Error err ->
      validation_error_result [ err ]
  | Ok horizon, Ok status, Ok phase ->
      let goals = Goal_store.list_goals ctx.config ?horizon ?status ?phase () in
      let rollup = Goal_store.compute_rollup goals in
      ok_result
        [
          ("generated_at", `String (Types.now_iso ()));
          ("count", `Int (List.length goals));
          ("goals", `List (List.map Goal_store.goal_to_yojson goals));
          ("rollup", Goal_store.rollup_to_yojson rollup);
        ]

let handle_goal_upsert (ctx : context) args =
  match
    parse_optional_horizon args "horizon",
    parse_optional_goal_status args "status",
    parse_optional_goal_phase args "phase",
    parse_optional_priority args "priority",
    parse_optional_policy args "verifier_policy",
    parse_optional_bool args "require_completion_approval"
  with
  | Error err, _, _, _, _, _
  | _, Error err, _, _, _, _
  | _, _, Error err, _, _, _
  | _, _, _, Error err, _, _
  | _, _, _, _, Error err, _
  | _, _, _, _, _, Error err ->
      validation_error_result [ err ]
  | Ok horizon, Ok status, Ok phase, Ok priority, Ok verifier_policy,
    Ok require_completion_approval ->
      let id = get_string_opt args "id" in
      let title = get_string_opt args "title" in
      let metric = get_string_opt args "metric" in
      let target_value = get_string_opt args "target_value" in
      let due_date = get_string_opt args "due_date" in
      let parent_goal_id = get_string_opt args "parent_goal_id" in
      begin
        match phase with
        | Some Goal_phase.Awaiting_verification
        | Some Goal_phase.Awaiting_approval ->
            error_result_typed ~code:Validation_error
              "Use masc_goal_transition for verification and approval phases"
        | _ -> (
            match
              Goal_store.upsert_goal ctx.config ?id ?horizon ?title ?metric
                ?target_value ?due_date ?priority ?status ?phase ?parent_goal_id
                ?verifier_policy ?require_completion_approval ()
            with
            | Error msg -> error_result_typed ~code:Validation_error msg
            | Ok (goal, action) ->
                let action_name =
                  match action with
                  | `created -> "created"
                  | `updated -> "updated"
                in
                let task_marker = Printf.sprintf "[goal:%s]" goal.id in
                ok_result
                  [
                    ("action", `String action_name);
                    ("goal_id", `String goal.id);
                    ("goal", Goal_store.goal_to_yojson goal);
                    ( "task_goal_id_example",
                      `String
                        (Printf.sprintf
                           {|masc_add_task({title: "Implement %s", goal_id: "%s"})|}
                           goal.title goal.id) );
                    ("task_link_field", `String "goal_id");
                    ("task_link_mode", `String "structured_with_legacy_title_marker");
                    ("task_title_marker", `String task_marker);
                    ( "linked_task_title_example",
                      `String
                        (Printf.sprintf "%s[child] %s" task_marker goal.title) );
                  ])
      end

let handle_goal_transition (ctx : context) args =
  match validate_string_required args "goal_id", parse_optional_transition_action args "action",
        parse_optional_principal args "actor" with
  | Error err, _, _
  | _, Error err, _
  | _, _, Error err ->
      validation_error_result [ err ]
  | Ok goal_id, Ok (Some action), Ok (Some actor) -> (
      let note = get_string_opt args "note" in
      if actor_must_be_operator action
         && actor.Goal_verification.kind <> Goal_verification.Operator
      then
        error_result_typed ~code:Validation_error
          "actor.kind must be operator for this transition"
      else
        match Goal_store.get_goal ctx.config ~goal_id with
        | None -> error_result_typed ~code:Not_found "goal not found"
        | Some goal ->
            let goals = Goal_store.list_goals ctx.config () in
            let effective_policy =
              Goal_verification.effective_policy_for_nodes
                ~goals:(goal_policy_nodes goals) ~goal_id
            in
            begin
              match effective_policy with
              | Error msg -> error_result_typed ~code:Validation_error msg
              | Ok effective_policy ->
                  let has_effective_verifier_policy =
                    Option.is_some effective_policy
                  in
                  match
                    Goal_phase.decide_transition ~phase:goal.phase ~action
                      ~has_effective_verifier_policy
                      ~require_completion_approval:goal.require_completion_approval
                  with
                  | Error msg -> error_result_typed ~code:Conflict msg
                  | Ok Goal_phase.Open_verification -> (
                      match effective_policy with
                      | None ->
                          error_result_typed ~code:Internal_error
                            "effective verifier policy missing"
                      | Some effective_policy -> (
                          match
                            Goal_verification.exclude_requester
                              ~policy_snapshot:effective_policy ~requested_by:actor
                          with
                          | Error msg ->
                              error_result_typed ~code:Validation_error msg
                          | Ok policy_snapshot -> (
                              match
                                Goal_verification.create_request ctx.config ~goal_id
                                  ~requested_by:actor ~policy_snapshot
                              with
                              | Error msg ->
                                  error_result_typed ~code:Internal_error msg
                              | Ok request -> (
                                  match
                                    update_goal_phase ctx goal
                                      ~phase:Goal_phase.Awaiting_verification ?note
                                      ~active_verification_request_id:request.id ()
                                  with
                                  | Error msg ->
                                      error_result_typed ~code:Internal_error msg
                                  | Ok updated_goal ->
                                      emit_goal_event ctx ~goal_id ~event_type:"goal_phase"
                                        ~payload:
                                          (`Assoc
                                            [
                                              ("phase", Goal_phase.to_yojson updated_goal.phase);
                                              ("actor", Goal_verification.goal_principal_to_yojson actor);
                                            ]);
                                      emit_goal_event ctx ~goal_id
                                        ~event_type:"goal_verification_opened"
                                        ~payload:
                                          (`Assoc
                                            [
                                              ( "request",
                                                Goal_verification.goal_verification_request_to_yojson
                                                  request );
                                            ]);
                                      ok_result
                                        [
                                          ("goal_id", `String goal_id);
                                          ( "action",
                                            `String
                                              (Goal_phase.action_to_string action) );
                                          ("goal", Goal_store.goal_to_yojson updated_goal);
                                          ( "verification_request",
                                            Goal_verification.goal_verification_request_to_yojson
                                              request );
                                          ( "verification_summary",
                                            verification_summary_json updated_goal
                                              (Some policy_snapshot) (Some request) );
                                        ]))))
                  | Ok Goal_phase.Open_approval -> (
                      match
                        update_goal_phase ctx goal ~phase:Goal_phase.Awaiting_approval
                          ?note ~clear_active_verification_request:true ()
                      with
                      | Error msg -> error_result_typed ~code:Internal_error msg
                      | Ok updated_goal ->
                          emit_goal_event ctx ~goal_id ~event_type:"goal_phase"
                            ~payload:
                              (`Assoc
                                [
                                  ("phase", Goal_phase.to_yojson updated_goal.phase);
                                  ("actor", Goal_verification.goal_principal_to_yojson actor);
                                ]);
                          emit_goal_event ctx ~goal_id
                            ~event_type:"goal_approval_opened"
                            ~payload:
                              (`Assoc
                                [
                                  ("actor", Goal_verification.goal_principal_to_yojson actor);
                                ]);
                          ok_result
                            [
                              ("goal_id", `String goal_id);
                              ("action", `String (Goal_phase.action_to_string action));
                              ("goal", Goal_store.goal_to_yojson updated_goal);
                              ( "verification_summary",
                                verification_summary_json updated_goal
                                  effective_policy None );
                            ])
                  | Ok Goal_phase.Complete -> (
                      match
                        update_goal_phase ctx goal ~phase:Goal_phase.Completed ?note
                          ~clear_active_verification_request:true ()
                      with
                      | Error msg -> error_result_typed ~code:Internal_error msg
                      | Ok updated_goal ->
                          emit_goal_event ctx ~goal_id ~event_type:"goal_phase"
                            ~payload:
                              (`Assoc
                                [
                                  ("phase", Goal_phase.to_yojson updated_goal.phase);
                                  ("actor", Goal_verification.goal_principal_to_yojson actor);
                                ]);
                          ok_result
                            [
                              ("goal_id", `String goal_id);
                              ("action", `String (Goal_phase.action_to_string action));
                              ("goal", Goal_store.goal_to_yojson updated_goal);
                              ( "verification_summary",
                                verification_summary_json updated_goal
                                  effective_policy None );
                            ])
                  | Ok (Goal_phase.Move_to next_phase) ->
                      let _ =
                        match goal.active_verification_request_id, next_phase with
                        | Some request_id, Goal_phase.Dropped
                        | Some request_id, Goal_phase.Executing
                          when goal.phase = Goal_phase.Awaiting_verification ->
                            ignore (Goal_verification.cancel_request ctx.config ~request_id);
                            emit_goal_event ctx ~goal_id
                              ~event_type:"goal_verification_resolved"
                              ~payload:
                                (`Assoc
                                  [
                                    ("request_id", `String request_id);
                                    ("status", `String "cancelled");
                                  ])
                        | _ -> ()
                      in
                      match
                        update_goal_phase ctx goal ~phase:next_phase ?note
                          ~clear_active_verification_request:
                            (next_phase <> Goal_phase.Awaiting_verification)
                          ()
                      with
                      | Error msg -> error_result_typed ~code:Internal_error msg
                      | Ok updated_goal ->
                          emit_goal_event ctx ~goal_id ~event_type:"goal_phase"
                            ~payload:
                              (`Assoc
                                [
                                  ("phase", Goal_phase.to_yojson updated_goal.phase);
                                  ("actor", Goal_verification.goal_principal_to_yojson actor);
                                ]);
                          if action = Goal_phase.Approve_completion
                             || action = Goal_phase.Reject_completion then
                            emit_goal_event ctx ~goal_id
                              ~event_type:"goal_approval_resolved"
                              ~payload:
                                (`Assoc
                                  [
                                    ( "decision",
                                      `String
                                        (if action = Goal_phase.Approve_completion then
                                           "approve"
                                         else
                                           "reject") );
                                  ]);
                          ok_result
                            [
                              ("goal_id", `String goal_id);
                              ("action", `String (Goal_phase.action_to_string action));
                              ("goal", Goal_store.goal_to_yojson updated_goal);
                              ( "verification_summary",
                                verification_summary_json updated_goal
                                  effective_policy None );
                            ]
            end)
  | Ok _, Ok None, _ ->
      validation_error_result
        [
          {
            field = "action";
            constraint_violated = Required;
            message = "action is required";
            expected = Some "string";
            received = None;
          };
        ]
  | Ok _, _, Ok None ->
      validation_error_result
        [
          {
            field = "actor";
            constraint_violated = Required;
            message = "actor is required";
            expected = Some "goal_principal";
            received = None;
          };
        ]

let handle_goal_verify (ctx : context) args =
  match validate_string_required args "goal_id", parse_optional_principal args "principal",
        parse_optional_vote_decision args "decision",
        parse_optional_string_list args "evidence_refs" with
  | Error err, _, _, _
  | _, Error err, _, _
  | _, _, Error err, _
  | _, _, _, Error err ->
      validation_error_result [ err ]
  | Ok goal_id, Ok (Some principal), Ok (Some decision), Ok evidence_refs -> (
      let note = get_string_opt args "note" in
      let evidence_refs = Option.value evidence_refs ~default:[] in
      let request_id = get_string_opt args "request_id" in
      match Goal_store.get_goal ctx.config ~goal_id with
      | None -> error_result_typed ~code:Not_found "goal not found"
      | Some goal -> (
          let request_id =
            match request_id with
            | Some request_id -> Some request_id
            | None -> goal.active_verification_request_id
          in
          match request_id with
          | None ->
              error_result_typed ~code:Conflict
                "goal has no active verification request"
          | Some request_id -> (
              match
                Goal_verification.submit_vote ctx.config ~request_id ~principal
                  ~decision ?note ~evidence_refs ()
              with
              | Error msg -> error_result_typed ~code:Conflict msg
              | Ok (request, quorum_result) ->
                  let goals = Goal_store.list_goals ctx.config () in
                  let effective_policy =
                    Goal_verification.effective_policy_for_nodes
                      ~goals:(goal_policy_nodes goals) ~goal_id
                  in
                  let effective_policy =
                    match effective_policy with
                    | Ok policy -> policy
                    | Error _ -> None
                  in
                  emit_goal_event ctx ~goal_id ~event_type:"goal_vote"
                    ~payload:
                      (`Assoc
                        [
                          ( "vote",
                            match List.rev request.votes with
                            | last_vote :: _ ->
                                Goal_verification.goal_verification_vote_to_yojson
                                  last_vote
                            | [] -> `Null );
                        ]);
                  let finalize ~phase ~event_status =
                    match
                      update_goal_phase ctx goal ~phase ?note
                        ~clear_active_verification_request:true ()
                    with
                    | Error msg -> error_result_typed ~code:Internal_error msg
                    | Ok updated_goal ->
                        emit_goal_event ctx ~goal_id
                          ~event_type:"goal_verification_resolved"
                          ~payload:
                            (`Assoc
                              [
                                ("request_id", `String request.id);
                                ("status", `String event_status);
                              ]);
                        emit_goal_event ctx ~goal_id ~event_type:"goal_phase"
                          ~payload:
                            (`Assoc [ ("phase", Goal_phase.to_yojson updated_goal.phase) ]);
                        ok_result
                          [
                            ("goal_id", `String goal_id);
                            ("goal", Goal_store.goal_to_yojson updated_goal);
                            ( "verification_request",
                              Goal_verification.goal_verification_request_to_yojson
                                request );
                            ( "verification_summary",
                              verification_summary_json updated_goal
                                effective_policy
                                (if updated_goal.phase = Goal_phase.Awaiting_verification then
                                   Some request
                                 else
                                   None) );
                          ]
                  in
                  match quorum_result with
                  | Goal_verification.Pending ->
                      ok_result
                        [
                          ("goal_id", `String goal_id);
                          ("goal", Goal_store.goal_to_yojson goal);
                          ( "verification_request",
                            Goal_verification.goal_verification_request_to_yojson request );
                          ( "verification_summary",
                            verification_summary_json goal effective_policy
                              (Some request) );
                        ]
                  | Goal_verification.Passed ->
                      if goal.require_completion_approval then begin
                        emit_goal_event ctx ~goal_id
                          ~event_type:"goal_approval_opened"
                          ~payload:(`Assoc [ ("request_id", `String request.id) ]);
                        finalize ~phase:Goal_phase.Awaiting_approval
                          ~event_status:"approved"
                      end else
                        finalize ~phase:Goal_phase.Completed
                          ~event_status:"approved"
                  | Goal_verification.Failed ->
                      finalize ~phase:Goal_phase.Executing
                        ~event_status:"rejected")))
  | Ok _, Ok None, _, _ ->
      validation_error_result
        [
          {
            field = "principal";
            constraint_violated = Required;
            message = "principal is required";
            expected = Some "goal_principal";
            received = None;
          };
        ]
  | Ok _, _, Ok None, _ ->
      validation_error_result
        [
          {
            field = "decision";
            constraint_violated = Required;
            message = "decision is required";
            expected = Some "string";
            received = None;
          };
        ]

let handle_goal_review (ctx : context) args =
  match validate_string_required args "goal_id", parse_optional_review_outcome args "outcome",
        parse_optional_horizon args "new_horizon" with
  | Error err, _, _
  | _, Error err, _
  | _, _, Error err ->
      validation_error_result [ err ]
  | Ok goal_id, Ok (Some outcome), Ok new_horizon -> (
      let note = get_string_opt args "note" in
      match Goal_store.get_goal ctx.config ~goal_id with
      | None -> error_result_typed ~code:Not_found "goal not found"
      | Some goal -> (
          match goal.phase with
          | Goal_phase.Awaiting_verification
          | Goal_phase.Awaiting_approval ->
              error_result_typed ~code:Conflict
                "masc_goal_review is ambiguous while verification or approval is pending; use masc_goal_transition / masc_goal_verify"
          | _ -> (
              match outcome with
              | Goal_store.ReviewDone ->
                  handle_goal_transition ctx
                    (`Assoc
                      [
                        ("goal_id", `String goal_id);
                        ("action", `String "request_complete");
                        ( "actor",
                          Goal_verification.goal_principal_to_yojson
                            {
                              kind = Goal_verification.Operator;
                              id = ctx.agent_name;
                              display_name = Some ctx.agent_name;
                            } );
                        ( "note",
                          match note with Some value -> `String value | None -> `Null );
                      ])
              | Goal_store.ReviewProgress
              | Goal_store.ReviewBlocked
              | Goal_store.ReviewDropped -> (
                  match
                    Goal_store.review_goal ctx.config ~goal_id ~outcome ?new_horizon
                      ?note ()
                  with
                  | Error msg ->
                      error_result_typed ~code:Not_found msg
                  | Ok goal ->
                      ok_result
                        [
                          ("goal_id", `String goal.id);
                          ("goal", Goal_store.goal_to_yojson goal);
                        ]))))
  | Ok _, Ok None, _ ->
      validation_error_result
        [
          {
            field = "outcome";
            constraint_violated = Required;
            message = "outcome is required";
            expected = Some "string";
            received = None;
          };
        ]
