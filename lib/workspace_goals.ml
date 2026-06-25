module Format = Stdlib.Format
module Map = Stdlib.Map
module Set = Stdlib.Set
module Queue = Stdlib.Queue
module Hashtbl = Stdlib.Hashtbl
module Mutex = Stdlib.Mutex
module Option = Stdlib.Option
module Result = Stdlib.Result
module Sys = Stdlib.Sys
module Filename = Stdlib.Filename
module List = Stdlib.List
module Array = Stdlib.Array
module String = Stdlib.String
module Char = Stdlib.Char
module Int = Stdlib.Int
module Float = Stdlib.Float

(** Workspace_goals - Handlers for goal management tools. *)

open Workspace_types
open Tool_args

(* Local helpers: build typed [Tool_result.result] from response helpers.
   ~tool_name and ~start_time are threaded through from dispatch.

   RFC-0189 PR-1b.8: handlers return [Tool_result.result]. Failure class is
   [Workflow_rejection] for every error path: all call sites here surface
   caller-input rejections (typed codes [Validation_error] / [Not_found] /
   [Conflict], or [validation_error_response] from [Tool_args]) — none
   originate from internal-state failures. The plain [error_result] helper
   was dead (0 callers) and removed. *)
let ok_result ~tool_name ~start_time fields : Tool_result.result =
  Tool_result.make_ok ~tool_name ~start_time ~data:(ok_assoc fields) ()
;;

let error_result_typed ~tool_name ~start_time ~code msg : Tool_result.result =
  Tool_result.make_err
    ~tool_name
    ~class_:Tool_result.Workflow_rejection
    ~start_time
    (error_response_typed ~code msg)
;;

let validation_error_result
      ~tool_name
      ~start_time
      (errors : field_error list)
  : Tool_result.result
  =
  Tool_result.make_err
    ~tool_name
    ~class_:Tool_result.Workflow_rejection
    ~start_time
    (validation_error_response errors)
;;

let principal_matches_authenticated_caller
      (ctx : context)
      (principal : Goal_verification.goal_principal)
  =
  String.equal principal.id ctx.agent_name
;;

let caller_is_goal_operator (ctx : context) =
  (Atomic.get Workspace_hooks.is_admin_agent_fn)
    ~base_path:ctx.config.base_path
    ~agent_name:ctx.agent_name
  ||
  match Auth.read_initial_admin ctx.config.base_path with
  | Some admin -> String.equal admin ctx.agent_name
  | None -> false
;;

let principal_binding_error ~field ctx principal =
  Printf.sprintf
    "%s id must match authenticated caller (%s)"
    field
    ctx.agent_name
;;

let operator_action_error action =
  Printf.sprintf
    "goal transition action %s requires an operator caller"
    (Goal_phase.action_to_string action)
;;

let goal_status_strings = [ "active"; "paused"; "done"; "dropped" ]

(* RFC-0089: derive the accepted-value sets from the Goal_phase ADT (the goal
   lifecycle SSOT) instead of hand-rolling them here, so the validator, the MCP
   schema enum, and the type can never drift apart. *)
let goal_phase_strings = List.map Goal_phase.to_string Goal_phase.all

let goal_transition_action_strings =
  List.map Goal_phase.action_to_string Goal_phase.all_actions
;;

let goal_vote_decision_strings = [ "approve"; "reject" ]

let make_enum_field_error ~field ~allowed ~received =
  { field
  ; constraint_violated = One_of allowed
  ; message = Printf.sprintf "%s must be one of: %s" field (String.concat ", " allowed)
  ; expected = Some (String.concat "|" allowed)
  ; received = Some received
  }
;;

let make_type_field_error ~field ~constraint_violated ~expected ~received =
  { field
  ; constraint_violated
  ; message = Printf.sprintf "%s must be a %s" field expected
  ; expected = Some expected
  ; received = Some received
  }
;;

(* RFC-0294: parse_optional_horizon removed with the workspace-goal horizon.
   The masc_goal_* schemas no longer advertise a horizon arg; rejection of an
   unexpected horizon key is governed by the schema's additionalProperties
   policy, not a hand-written substring guard. *)

let parse_optional_goal_status args field =
  match Json_util.assoc_member_opt field args with
  | None | Some `Null -> Ok None
  | Some (`String raw) when String.trim raw = "" -> Ok None
  | Some (`String raw) ->
    (match Goal_store.parse_goal_status (Some raw) with
     | Some status -> Ok (Some status)
     | None ->
       Error (make_enum_field_error ~field ~allowed:goal_status_strings ~received:raw))
  | Some json ->
    Error
      (make_type_field_error
         ~field
         ~constraint_violated:Type_string
         ~expected:"string"
         ~received:(Yojson.Safe.to_string json))
;;

let parse_optional_goal_phase args field =
  match Json_util.assoc_member_opt field args with
  | None | Some `Null -> Ok None
  | Some (`String raw) when String.trim raw = "" -> Ok None
  | Some (`String raw) ->
    (match Goal_store.parse_goal_phase (Some raw) with
     | Some phase -> Ok (Some phase)
     | None ->
       Error (make_enum_field_error ~field ~allowed:goal_phase_strings ~received:raw))
  | Some json ->
    Error
      (make_type_field_error
         ~field
         ~constraint_violated:Type_string
         ~expected:"string"
         ~received:(Yojson.Safe.to_string json))
;;

let reject_retired_goal_list_status args =
  match args with
  | `Assoc fields ->
    (match List.assoc_opt "status" fields with
     | None -> Ok ()
     | Some json ->
       Error
         { field = "status"
         ; constraint_violated = One_of goal_phase_strings
         ; message = "status filter was removed from masc_goal_list; use phase"
         ; expected = Some "phase"
         ; received = Some (Yojson.Safe.to_string json)
         })
  | _ -> Ok ()
;;

let goal_upsert_lifecycle_error ~tool_name ~start_time field =
  error_result_typed
    ~tool_name
    ~start_time
    ~code:Validation_error
    (Printf.sprintf
       "masc_goal_upsert does not accept lifecycle field %s; use masc_goal_transition / \
        masc_goal_verify for goal lifecycle moves"
       field)
;;

let parse_optional_priority args field =
  match Json_util.assoc_member_opt field args with
  | None | Some `Null -> Ok None
  | Some (`Int n) ->
    if n < 1 || n > 5
    then
      Error
        { field
        ; constraint_violated = Min_int 1
        ; message = "priority must be between 1 and 5"
        ; expected = Some "1..5"
        ; received = Some (Int.to_string n)
        }
    else Ok (Some n)
  | Some json ->
    Error
      (make_type_field_error
         ~field
         ~constraint_violated:Type_int
         ~expected:"integer"
         ~received:(Yojson.Safe.to_string json))
;;

let parse_optional_bool args field =
  match Json_util.assoc_member_opt field args with
  | None | Some `Null -> Ok None
  | Some (`Bool value) -> Ok (Some value)
  | Some json ->
    Error
      (make_type_field_error
         ~field
         ~constraint_violated:Type_bool
         ~expected:"boolean"
         ~received:(Yojson.Safe.to_string json))
;;

let verifier_policy_shape_hint =
  "omit/null/{} or {\"mode\":\"none\"} for no verifier policy, or use canonical \
   {\"inherit_mode\":\"extend|replace\",\"principals\":[...]}"
;;

let is_noop_verifier_policy_json = function
  | `Assoc [] -> true
  | `Assoc [ ("mode", `String raw) ] ->
    String.equal "none" (String.lowercase_ascii (String.trim raw))
  | _ -> false
;;

let parse_optional_policy args field =
  match Json_util.assoc_member_opt field args with
  | None | Some `Null -> Ok None
  | Some json when is_noop_verifier_policy_json json -> Ok None
  | Some json ->
    (match Goal_verification.goal_verifier_policy_of_yojson json with
     | Ok policy -> Ok (Some policy)
     | Error msg ->
       let message =
         msg ^ "; accepted verifier_policy shapes: " ^ verifier_policy_shape_hint
       in
       Error
         { field
         ; constraint_violated = Type_string
         ; message
         ; expected = Some verifier_policy_shape_hint
         ; received = Some (Yojson.Safe.to_string json)
         })
;;

let parse_optional_principal args field =
  match Json_util.assoc_member_opt field args with
  | None | Some `Null -> Ok None
  | Some json ->
    (match Goal_verification.goal_principal_of_yojson json with
     | Ok principal -> Ok (Some principal)
     | Error msg ->
       Error
         { field
         ; constraint_violated = Type_string
         ; message = msg
         ; expected = Some "goal_principal"
         ; received = Some (Yojson.Safe.to_string json)
         })
;;

let parse_optional_vote_decision args field =
  match Json_util.assoc_member_opt field args with
  | None | Some `Null -> Ok None
  | Some (`String raw) ->
    (match
       String.trim raw
       |> String.lowercase_ascii
       |> Goal_verification.vote_decision_of_string
     with
     | Some decision -> Ok (Some decision)
     | None ->
       Error
         (make_enum_field_error ~field ~allowed:goal_vote_decision_strings ~received:raw))
  | Some json ->
    Error
      (make_type_field_error
         ~field
         ~constraint_violated:Type_string
         ~expected:"string"
         ~received:(Yojson.Safe.to_string json))
;;

let parse_optional_transition_action args field =
  match Json_util.assoc_member_opt field args with
  | None | Some `Null -> Ok None
  | Some (`String raw) ->
    (match Goal_phase.parse_action raw with
     | Some action -> Ok (Some action)
     | None ->
       Error
         (make_enum_field_error
            ~field
            ~allowed:goal_transition_action_strings
            ~received:raw))
  | Some json ->
    Error
      (make_type_field_error
         ~field
         ~constraint_violated:Type_string
         ~expected:"string"
         ~received:(Yojson.Safe.to_string json))
;;

let validate_goal_completion_ready config ~goal_id ~override_note =
  match override_note with
  | Some note when not (String.equal (String.trim note) "") -> Ok ()
  | _ ->
    (match Workspace_goal_index.build_goal_task_index_for_config_checked config with
     | Error msg ->
       Error ("goal completion readiness unavailable: " ^ msg)
     | Ok index ->
    let linked_tasks =
      Workspace_goal_index.tasks_for_goal index ~goal_id
    in
    let open_count =
      linked_tasks
      |> List.filter (fun (task : Masc_domain.task) ->
        not (Masc_domain.task_status_is_terminal task.task_status))
      |> List.length
    in
    let done_count =
      linked_tasks
      |> List.filter (fun (task : Masc_domain.task) ->
        Masc_domain.task_status_is_done task.task_status)
      |> List.length
    in
    if
      match linked_tasks with
      | [] -> true
      | _ -> false
    then
      Error
        "goal completion requires at least one linked task; provide override_note to \
         force"
    else if open_count > 0
    then
      Error
        (Printf.sprintf
           "goal completion blocked: %d linked task(s) are still open; provide \
            override_note to force"
           open_count)
    else if done_count = 0
    then
      Error
        "goal completion blocked: linked tasks are terminal but none are done; provide \
         override_note to force"
    else Ok ())
;;

let completion_ready_precondition config ~goal_id ~override_note _current =
  validate_goal_completion_ready config ~goal_id ~override_note
;;

let parse_optional_string_list args field =
  match Json_util.assoc_member_opt field args with
  | None | Some `Null -> Ok None
  | Some (`List values) ->
    (try Ok (Some (List.map (function `String s -> s | _ -> "") values)) with
     | Eio.Cancel.Cancelled _ as e -> raise e
     | _ ->
       Error
         (make_type_field_error
            ~field
            ~constraint_violated:Type_string
            ~expected:"string[]"
            ~received:(Yojson.Safe.to_string (`List values))))
  | Some json ->
    Error
      (make_type_field_error
         ~field
         ~constraint_violated:Type_string
         ~expected:"string[]"
         ~received:(Yojson.Safe.to_string json))
;;

let goal_policy_nodes = Workspace_goals_verification.goal_policy_nodes
let verification_summary_json = Workspace_goals_verification.verification_summary_json
let update_goal_phase = Workspace_goals_verification.update_goal_phase

let emit_goal_event = Workspace_goals_verification.emit_goal_event

let cancel_verification_request_after_phase_failure
      ctx
      ~goal_id
      ~request_id
      ~original_error
  =
  let reason = "failed_to_persist_awaiting_verification_phase" in
  match Goal_verification.cancel_request ctx.config ~request_id with
  | Ok _ ->
    emit_goal_event
      ctx
      ~goal_id
      ~event_type:"goal_verification_resolved"
      ~payload:
        (`Assoc
            [ "request_id", `String request_id
            ; "status", `String "cancelled"
            ; "reason", `String reason
            ]);
    original_error
  | Error cancel_error ->
    Log.Misc.warn
      "goal verification compensation cancel failed for %s after phase update \
       failure: %s"
      request_id
      cancel_error;
    Printf.sprintf
      "%s (also failed to cancel verification request %s: %s)"
      original_error
      request_id
      cancel_error
;;

let cancel_stale_open_verification_requests_before_new_request ctx ~goal_id =
  match
    Goal_verification.cancel_open_requests_for_goal_except
      ctx.config
      ~goal_id
      ~active_request_id:None
  with
  | Error msg -> Error msg
  | Ok cancelled ->
    List.iter
      (fun (request : Goal_verification.goal_verification_request) ->
         emit_goal_event
           ctx
           ~goal_id
           ~event_type:"goal_verification_resolved"
           ~payload:
             (`Assoc
                 [ "request_id", `String request.id
                 ; "status", `String "cancelled"
                 ; ( "reason"
                   , `String "stale_open_request_before_new_verification" )
                 ]))
      cancelled;
    Ok ()
;;

let rollback_verification_vote_after_phase_failure
      ctx
      ~goal_id
      ~expected_current
      ~snapshot
      ~event_status
      ~original_error
  =
  match
    Goal_verification.restore_request_snapshot
      ctx.config
      ~expected_current
      ~snapshot
  with
  | Ok restored ->
    emit_goal_event
      ctx
      ~goal_id
      ~event_type:"goal_verification_vote_rolled_back"
      ~payload:
        (`Assoc
            [ "request_id", `String restored.id
            ; "failed_status", `String event_status
            ; "restored_status", `String "open"
            ; "reason", `String "failed_to_persist_goal_phase_after_vote"
            ]);
    Printf.sprintf
      "%s (verification request %s restored to open after failed goal phase \
       write)"
      original_error
      restored.id
  | Error rollback_error ->
    Log.Misc.warn
      "goal verification vote rollback failed for %s after phase update \
       failure: %s"
      expected_current.id
      rollback_error;
    Printf.sprintf
      "%s (also failed to rollback verification request %s: %s)"
      original_error
      expected_current.id
      rollback_error
;;

let validate_goal_active_verification_request goal ~request_id =
  if goal.Goal_store.phase <> Goal_phase.Awaiting_verification
  then
    Error
      (Printf.sprintf
         "goal %s is not awaiting verification; refusing vote for request %s"
         goal.id
         request_id)
  else
    match goal.active_verification_request_id with
    | Some active_id when String.equal active_id request_id -> Ok ()
    | Some active_id ->
      Error
        (Printf.sprintf
           "goal verification request %s is not active for goal %s (active: %s)"
           request_id
           goal.id
           active_id)
    | None ->
      Error
        (Printf.sprintf
           "goal %s has no active verification request; refusing vote for \
            request %s"
           goal.id
           request_id)
;;

let handle_goal_list ~tool_name ~start_time (ctx : context) args : Tool_result.result =
  match
    ( reject_retired_goal_list_status args
    , parse_optional_goal_phase args "phase" )
  with
  | Error err, _ | _, Error err ->
    validation_error_result ~tool_name ~start_time [ err ]
  | Ok (), Ok phase ->
    let goals = Goal_store.list_goals ctx.config ?phase () in
    let rollup = Goal_store.compute_rollup goals in
    ok_result
      ~tool_name
      ~start_time
      [ "generated_at", `String (Masc_domain.now_iso ())
      ; "count", `Int (List.length goals)
      ; "goals", `List (List.map Goal_store.goal_to_yojson goals)
      ; "rollup", Goal_store.rollup_to_yojson rollup
      ]
;;

let handle_goal_upsert ~tool_name ~start_time (ctx : context) args : Tool_result.result =
  match
    ( parse_optional_goal_status args "status"
    , parse_optional_goal_phase args "phase"
    , parse_optional_priority args "priority"
    , parse_optional_policy args "verifier_policy"
    , parse_optional_bool args "require_completion_approval" )
  with
  | Error err, _, _, _, _
  | _, Error err, _, _, _
  | _, _, Error err, _, _
  | _, _, _, Error err, _
  | _, _, _, _, Error err -> validation_error_result ~tool_name ~start_time [ err ]
  | ( Ok status
    , Ok phase
    , Ok priority
    , Ok verifier_policy
    , Ok require_completion_approval ) ->
    let id = get_string_opt args "id" in
    let title = get_string_opt args "title" in
    let metric = get_string_opt args "metric" in
    let target_value = get_string_opt args "target_value" in
    let due_date = get_string_opt args "due_date" in
    let parent_goal_id = get_string_opt args "parent_goal_id" in
    (match phase, status with
     | Some _, _ -> goal_upsert_lifecycle_error ~tool_name ~start_time "phase"
     | _, Some _ -> goal_upsert_lifecycle_error ~tool_name ~start_time "status"
     | _ ->
       (match
          Goal_store.upsert_goal
            ctx.config
            ?id
            ?title
            ?metric
            ?target_value
            ?due_date
            ?priority
            ?status
            ?phase
            ?parent_goal_id
            ?verifier_policy
            ?require_completion_approval
            ()
        with
        | Error msg ->
          error_result_typed ~tool_name ~start_time ~code:Validation_error msg
        | Ok (goal, action) ->
          let action_name =
            match action with
            | `created -> "created"
            | `updated -> "updated"
          in
          ok_result
            ~tool_name
            ~start_time
            [ "action", `String action_name
            ; "goal_id", `String goal.id
            ; "goal", Goal_store.goal_to_yojson goal
            ; ( "task_goal_id_example"
              , `String
                  (Printf.sprintf
                     {|masc_add_task({title: "Implement %s", goal_id: "%s"})|}
                     goal.title
                     goal.id) )
            ; "task_link_field", `String "goal_id"
            ; "task_link_mode", `String "structured_goal_id"
            ; ( "linked_task_title_example"
              , `String (Printf.sprintf "[child] %s" goal.title) )
            ]))
;;

let handle_goal_transition ~tool_name ~start_time (ctx : context) args : Tool_result.result =
  match
    ( validate_string_required args "goal_id"
    , parse_optional_transition_action args "action"
    , parse_optional_principal args "actor" )
  with
  | Error err, _, _ | _, Error err, _ | _, _, Error err ->
    validation_error_result ~tool_name ~start_time [ err ]
  | Ok goal_id, Ok (Some action), Ok (Some actor) ->
    if not (principal_matches_authenticated_caller ctx actor)
    then
      error_result_typed
        ~tool_name
        ~start_time
        ~code:Validation_error
        (principal_binding_error ~field:"actor" ctx actor)
    else if
      Workspace_goals_verification.actor_must_be_operator action
      && not (caller_is_goal_operator ctx)
    then
      error_result_typed
        ~tool_name
        ~start_time
        ~code:Conflict
        (operator_action_error action)
    else
    let note = get_string_opt args "note" in
    let override_note = get_string_opt args "override_note" in
    let request_completion_precondition =
      if action = Goal_phase.Request_complete
      then Some (completion_ready_precondition ctx.config ~goal_id ~override_note)
      else None
    in
    (match Goal_store.get_goal ctx.config ~goal_id with
      | None -> error_result_typed ~tool_name ~start_time ~code:Not_found "goal not found"
      | Some goal ->
        (match
           if action = Goal_phase.Request_complete
           then validate_goal_completion_ready ctx.config ~goal_id ~override_note
           else Ok ()
         with
         | Error msg -> error_result_typed ~tool_name ~start_time ~code:Conflict msg
         | Ok () ->
           let goals = Goal_store.list_goals ctx.config () in
           let effective_policy =
             Goal_verification.effective_policy_for_nodes
               ~goals:(goal_policy_nodes goals)
               ~goal_id
           in
           (match effective_policy with
            | Error msg ->
              error_result_typed ~tool_name ~start_time ~code:Validation_error msg
            | Ok effective_policy ->
              let has_effective_verifier_policy = Option.is_some effective_policy in
              (match
                 Goal_phase.decide_transition
                   ~phase:goal.phase
                   ~action
                   ~has_effective_verifier_policy
                   ~require_completion_approval:goal.require_completion_approval
               with
               | Error msg -> error_result_typed ~tool_name ~start_time ~code:Conflict msg
               | Ok Goal_phase.Open_verification ->
                 (match effective_policy with
                  | None ->
                    error_result_typed
                      ~tool_name
                      ~start_time
                      ~code:Internal_error
                      "effective verifier policy missing"
                  | Some effective_policy ->
                    (match
                       Goal_verification.exclude_requester
                         ~policy_snapshot:effective_policy
                         ~requested_by:actor
                     with
                     | Error msg ->
                       error_result_typed
                         ~tool_name
                         ~start_time
                         ~code:Validation_error
                         msg
                     | Ok policy_snapshot ->
                       (match
                          cancel_stale_open_verification_requests_before_new_request
                            ctx
                            ~goal_id
                        with
                        | Error msg ->
                          error_result_typed
                            ~tool_name
                            ~start_time
                            ~code:Internal_error
                            msg
                        | Ok () ->
                       (match
                          Goal_verification.create_request
                            ctx.config
                            ~goal_id
                            ~requested_by:actor
                            ~policy_snapshot
                        with
                        | Error msg ->
                          error_result_typed
                            ~tool_name
                            ~start_time
                            ~code:Internal_error
                            msg
                        | Ok request ->
                          (match
                             update_goal_phase
                               ctx
                               goal
                               ~phase:Goal_phase.Awaiting_verification
                               ?note
                               ?precondition:request_completion_precondition
                               ~active_verification_request_id:request.id
                               ()
                           with
                           | Error msg ->
                             let msg =
                               cancel_verification_request_after_phase_failure
                                 ctx
                                 ~goal_id
                                 ~request_id:request.id
                                 ~original_error:msg
                             in
                             error_result_typed
                               ~tool_name
                               ~start_time
                               ~code:Internal_error
                               msg
                           | Ok updated_goal ->
                             emit_goal_event
                               ctx
                               ~goal_id
                               ~event_type:"goal_phase"
                               ~payload:
                                 (`Assoc
                                     [ "phase", Goal_phase.to_yojson updated_goal.phase
                                     ; ( "actor"
                                       , Goal_verification.goal_principal_to_yojson actor
                                       )
                                     ]);
                             emit_goal_event
                               ctx
                               ~goal_id
                               ~event_type:"goal_verification_opened"
                               ~payload:
                                 (`Assoc
                                     [ ( "request"
                                       , Goal_verification
                                         .goal_verification_request_to_yojson
                                           request )
                                     ]);
                             ok_result
                               ~tool_name
                               ~start_time
                               [ "goal_id", `String goal_id
                               ; "action", `String (Goal_phase.action_to_string action)
                               ; "goal", Goal_store.goal_to_yojson updated_goal
                               ; ( "verification_request"
                                 , Goal_verification.goal_verification_request_to_yojson
                                     request )
                               ; ( "verification_summary"
                                 , verification_summary_json
                                     updated_goal
                                     (Some policy_snapshot)
                                     (Some request) )
                               ])))))
               | Ok Goal_phase.Open_approval ->
                 (match Goal_approval.open_request ctx.config ~goal_id ~opened_by:actor () with
                  | Error msg ->
                    error_result_typed ~tool_name ~start_time ~code:Conflict msg
                  | Ok approval_request ->
                    (match
                       update_goal_phase
                         ctx
                         goal
                         ~phase:Goal_phase.Awaiting_approval
                         ?note
                         ?precondition:request_completion_precondition
                         ~clear_active_verification_request:true
                         ()
                     with
                     | Error msg ->
                       ignore
                         (Goal_approval.resolve_open_request
                            ctx.config
                            ~goal_id
                            ~status:Goal_approval.Cancelled
                            ~resolved_by:actor
                            ~note:"failed to persist Awaiting_approval phase"
                            ());
                       error_result_typed ~tool_name ~start_time ~code:Internal_error msg
                     | Ok updated_goal ->
                       emit_goal_event
                         ctx
                         ~goal_id
                         ~event_type:"goal_phase"
                         ~payload:
                           (`Assoc
                               [ "phase", Goal_phase.to_yojson updated_goal.phase
                               ; "actor", Goal_verification.goal_principal_to_yojson actor
                               ]);
                       emit_goal_event
                         ctx
                         ~goal_id
                         ~event_type:"goal_approval_opened"
                         ~payload:
                           (`Assoc
                               [ "approval_request"
                               , Goal_approval.approval_request_to_yojson
                                   approval_request
                               ; ( "actor"
                                 , Goal_verification.goal_principal_to_yojson actor
                                 )
                               ]);
                       ok_result
                         ~tool_name
                         ~start_time
                         [ "goal_id", `String goal_id
                         ; "action", `String (Goal_phase.action_to_string action)
                         ; "goal", Goal_store.goal_to_yojson updated_goal
                         ; ( "approval_request"
                           , Goal_approval.approval_request_to_yojson
                               approval_request )
                         ; ( "verification_summary"
                           , verification_summary_json updated_goal effective_policy None )
                         ]))
               | Ok Goal_phase.Complete ->
                 (match
                    update_goal_phase
                      ctx
                      goal
                      ~phase:Goal_phase.Completed
                      ?note
                      ?precondition:request_completion_precondition
                      ~clear_active_verification_request:true
                      ()
                  with
                  | Error msg ->
                    error_result_typed ~tool_name ~start_time ~code:Internal_error msg
                  | Ok updated_goal ->
                    emit_goal_event
                      ctx
                      ~goal_id
                      ~event_type:"goal_phase"
                      ~payload:
                        (`Assoc
                            [ "phase", Goal_phase.to_yojson updated_goal.phase
                            ; "actor", Goal_verification.goal_principal_to_yojson actor
                            ]);
                    ok_result
                      ~tool_name
                      ~start_time
                      [ "goal_id", `String goal_id
                      ; "action", `String (Goal_phase.action_to_string action)
                      ; "goal", Goal_store.goal_to_yojson updated_goal
                      ; ( "verification_summary"
                        , verification_summary_json updated_goal effective_policy None )
                      ])
               | Ok (Goal_phase.Move_to next_phase) ->
                 (match goal.active_verification_request_id, next_phase with
                  | ( Some request_id
                    , ( Goal_phase.Blocked
                      | Goal_phase.Dropped
                      | Goal_phase.Executing ) )
                    when goal.phase = Goal_phase.Awaiting_verification ->
                    (* Leaving verification through an operator transition is
                       not a quorum verdict. Seal the open request as cancelled;
                       quorum failure is handled in [handle_goal_verify] as
                       [Rejected] and moves the goal back to [Executing]. *)
                    (match Goal_verification.cancel_request ctx.config ~request_id with
                     | Ok _ ->
                       emit_goal_event
                         ctx
                         ~goal_id
                         ~event_type:"goal_verification_resolved"
                         ~payload:
                           (`Assoc
                               [ "request_id", `String request_id
                               ; "status", `String "cancelled"
                               ])
                     | Error msg ->
                       Log.Misc.warn
                         "goal verification cancel_request failed for %s: %s"
                         request_id
                         msg)
                  | None, _ -> ()
                  | Some _, _ -> ());
                 let approval_resolution =
                   if
                     goal.phase = Goal_phase.Awaiting_approval
                     && (action = Goal_phase.Approve_completion
                         || action = Goal_phase.Reject_completion)
                   then
                     Goal_approval.resolve_open_request
                       ctx.config
                       ~goal_id
                       ~status:
                         (if action = Goal_phase.Approve_completion
                          then Goal_approval.Approved
                          else Goal_approval.Rejected)
                       ~resolved_by:actor
                       ?note
                       ()
                     |> Result.map Option.some
                   else Ok None
                 in
                 (match approval_resolution with
                  | Error msg ->
                    error_result_typed ~tool_name ~start_time ~code:Conflict msg
                  | Ok resolved_approval_request ->
                 (match
                    update_goal_phase
                      ctx
                      goal
                      ~phase:next_phase
                      ?note
                      ~clear_active_verification_request:
                        (not (next_phase = Goal_phase.Awaiting_verification))
                      ()
                  with
                  | Error msg ->
                    error_result_typed ~tool_name ~start_time ~code:Internal_error msg
                  | Ok updated_goal ->
                    emit_goal_event
                      ctx
                      ~goal_id
                      ~event_type:"goal_phase"
                      ~payload:
                        (`Assoc
                            [ "phase", Goal_phase.to_yojson updated_goal.phase
                            ; "actor", Goal_verification.goal_principal_to_yojson actor
                            ]);
                    let () =
                      match resolved_approval_request with
                      | None -> ()
                      | Some request ->
                        emit_goal_event
                          ctx
                          ~goal_id
                          ~event_type:"goal_approval_resolved"
                          ~payload:
                            (`Assoc
                                [ ( "decision"
                                  , `String
                                      (if action = Goal_phase.Approve_completion
                                       then "approve"
                                       else "reject") )
                                ; ( "actor"
                                  , Goal_verification.goal_principal_to_yojson actor
                                  )
                                ; ( "approval_request"
                                  , Goal_approval.approval_request_to_yojson request )
                                ])
                    in
                    ok_result
                      ~tool_name
                      ~start_time
                      [ "goal_id", `String goal_id
                      ; "action", `String (Goal_phase.action_to_string action)
                      ; "goal", Goal_store.goal_to_yojson updated_goal
                      ; ( "approval_request"
                        , match resolved_approval_request with
                          | Some request -> Goal_approval.approval_request_to_yojson request
                          | None -> `Null )
                      ; ( "verification_summary"
                        , verification_summary_json updated_goal effective_policy None )
                      ])))))))
  | Ok _, Ok None, _ ->
    validation_error_result
      ~tool_name
      ~start_time
      [ { field = "action"
        ; constraint_violated = Required
        ; message = "action is required"
        ; expected = Some "string"
        ; received = None
        }
      ]
  | Ok _, _, Ok None ->
    validation_error_result
      ~tool_name
      ~start_time
      [ { field = "actor"
        ; constraint_violated = Required
        ; message = "actor is required"
        ; expected = Some "goal_principal"
        ; received = None
        }
      ]
;;

let handle_goal_verify ~tool_name ~start_time (ctx : context) args : Tool_result.result =
  match
    ( validate_string_required args "goal_id"
    , parse_optional_principal args "principal"
    , parse_optional_vote_decision args "decision"
    , parse_optional_string_list args "evidence_refs" )
  with
  | Error err, _, _, _ | _, Error err, _, _ | _, _, Error err, _ | _, _, _, Error err ->
    validation_error_result ~tool_name ~start_time [ err ]
  | Ok goal_id, Ok (Some principal), Ok (Some decision), Ok evidence_refs ->
    if not (principal_matches_authenticated_caller ctx principal)
    then
      error_result_typed
        ~tool_name
        ~start_time
        ~code:Validation_error
        (principal_binding_error ~field:"principal" ctx principal)
    else
    let note = get_string_opt args "note" in
    let evidence_refs = Option.value evidence_refs ~default:[] in
    let request_id = get_string_opt args "request_id" in
    (match Goal_store.get_goal ctx.config ~goal_id with
     | None -> error_result_typed ~tool_name ~start_time ~code:Not_found "goal not found"
     | Some goal ->
       let request_id =
         match request_id with
         | Some request_id -> Some request_id
         | None -> goal.active_verification_request_id
       in
       (match request_id with
        | None ->
          error_result_typed
            ~tool_name
            ~start_time
            ~code:Conflict
            "goal has no active verification request"
        | Some request_id ->
          (match validate_goal_active_verification_request goal ~request_id with
           | Error msg ->
             error_result_typed ~tool_name ~start_time ~code:Conflict msg
           | Ok () ->
          (match
             Goal_verification.submit_vote_with_snapshot
               ctx.config
               ~goal_id
               ~request_id
               ~principal
               ~decision
               ?note
               ~evidence_refs
               ()
           with
           | Error msg -> error_result_typed ~tool_name ~start_time ~code:Conflict msg
           | Ok submission ->
             let previous_request = submission.previous_request in
             let request = submission.request in
             let quorum_result = submission.quorum_result in
             let goals = Goal_store.list_goals ctx.config () in
             let effective_policy =
               Goal_verification.effective_policy_for_nodes
                 ~goals:(goal_policy_nodes goals)
                 ~goal_id
             in
             let effective_policy =
               match effective_policy with
               | Ok policy -> policy
               | Error _ -> None
             in
             emit_goal_event
               ctx
               ~goal_id
               ~event_type:"goal_vote"
               ~payload:
                 (`Assoc
                     [ ( "vote"
                       , match List.rev request.votes with
                         | last_vote :: _ ->
                           Goal_verification.goal_verification_vote_to_yojson last_vote
                         | [] -> `Null )
                     ]);
             let finalize ~phase ~event_status =
               let approval_precondition =
                 match phase, event_status with
                 | (Goal_phase.Completed | Goal_phase.Awaiting_approval), "approved" ->
                   Some (completion_ready_precondition ctx.config ~goal_id ~override_note:None)
                 | _ -> None
               in
               match
                 update_goal_phase
                   ctx
                   goal
                   ~phase
                   ?note
                   ?precondition:approval_precondition
                   ~clear_active_verification_request:true
                   ()
               with
               | Error msg ->
                 let msg =
                   Printf.sprintf
                     "goal verification request %s sealed as %s but failed to \
                      persist goal phase: %s"
                     request.id
                     event_status
                     msg
                 in
                 let msg =
                   rollback_verification_vote_after_phase_failure
                     ctx
                     ~goal_id
                     ~expected_current:request
                     ~snapshot:previous_request
                     ~event_status
                     ~original_error:msg
                 in
                 emit_goal_event
                   ctx
                   ~goal_id
                   ~event_type:"goal_verification_phase_update_failed"
                   ~payload:
                     (`Assoc
                         [ "request_id", `String request.id
                         ; "status", `String event_status
                         ; "error", `String msg
                         ]);
                 error_result_typed ~tool_name ~start_time ~code:Internal_error msg
               | Ok updated_goal ->
                 emit_goal_event
                   ctx
                   ~goal_id
                   ~event_type:"goal_verification_resolved"
                   ~payload:
                     (`Assoc
                         [ "request_id", `String request.id
                         ; "status", `String event_status
                         ]);
                 emit_goal_event
                   ctx
                   ~goal_id
                   ~event_type:"goal_phase"
                   ~payload:(`Assoc [ "phase", Goal_phase.to_yojson updated_goal.phase ]);
                 ok_result
                   ~tool_name
                   ~start_time
                   [ "goal_id", `String goal_id
                   ; "goal", Goal_store.goal_to_yojson updated_goal
                   ; ( "verification_request"
                     , Goal_verification.goal_verification_request_to_yojson request )
                   ; ( "verification_summary"
                     , verification_summary_json
                         ~latest_request:request
                         updated_goal
                         effective_policy
                         (if updated_goal.phase = Goal_phase.Awaiting_verification
                          then Some request
                          else None) )
                   ]
             in
             (match quorum_result with
              | Goal_verification.Pending ->
                ok_result
                  ~tool_name
                  ~start_time
                  [ "goal_id", `String goal_id
                  ; "goal", Goal_store.goal_to_yojson goal
                  ; ( "verification_request"
                    , Goal_verification.goal_verification_request_to_yojson request )
                  ; ( "verification_summary"
                    , verification_summary_json goal effective_policy (Some request) )
                  ]
              | Goal_verification.Passed ->
                if goal.require_completion_approval
                then
                  (match
                     Goal_approval.open_request
                       ctx.config
                       ~goal_id
                       ~verification_request_id:request.id
                       ~opened_by:principal
                       ()
                   with
                   | Error msg ->
                     error_result_typed ~tool_name ~start_time ~code:Conflict msg
                   | Ok approval_request ->
                     emit_goal_event
                       ctx
                       ~goal_id
                       ~event_type:"goal_approval_opened"
                       ~payload:
                         (`Assoc
                             [ "verification_request_id", `String request.id
                             ; ( "approval_request"
                               , Goal_approval.approval_request_to_yojson
                                   approval_request )
                             ; ( "actor"
                               , Goal_verification.goal_principal_to_yojson principal
                               )
                             ]);
                     let result =
                       finalize
                         ~phase:Goal_phase.Awaiting_approval
                         ~event_status:"approved"
                     in
                     if Tool_result.is_success result
                     then result
                     else (
                       ignore
                         (Goal_approval.resolve_open_request
                            ctx.config
                            ~goal_id
                            ~status:Goal_approval.Cancelled
                            ~resolved_by:principal
                            ~note:"failed to persist Awaiting_approval phase"
                            ());
                       result))
                else finalize ~phase:Goal_phase.Completed ~event_status:"approved"
              | Goal_verification.Failed ->
                finalize ~phase:Goal_phase.Executing ~event_status:"rejected")))))
  | Ok _, Ok None, _, _ ->
    validation_error_result
      ~tool_name
      ~start_time
      [ { field = "principal"
        ; constraint_violated = Required
        ; message = "principal is required"
        ; expected = Some "goal_principal"
        ; received = None
        }
      ]
  | Ok _, _, Ok None, _ ->
    validation_error_result
      ~tool_name
      ~start_time
      [ { field = "decision"
        ; constraint_violated = Required
        ; message = "decision is required"
        ; expected = Some "string"
        ; received = None
        }
      ]
;;
