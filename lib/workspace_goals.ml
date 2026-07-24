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

let error_result_typed
      ?(class_ = Tool_result.Workflow_rejection)
      ~tool_name
      ~start_time
      ~code
      msg
  : Tool_result.result
  =
  let data =
    error_assoc
      [ "error_code", `String (error_code_to_string code)
      ; "message", `String msg
      ]
  in
  Tool_result.make_err
    ~tool_name
    ~class_
    ~start_time
    ~data
    (Yojson.Safe.to_string data)
;;

let validation_error_result
      ~tool_name
      ~start_time
      (errors : field_error list)
  : Tool_result.result
  =
  let data = validation_error_assoc errors in
  Tool_result.make_err
    ~tool_name
    ~class_:Tool_result.Workflow_rejection
    ~start_time
    ~data
    (Yojson.Safe.to_string data)
;;

let goal_status_strings = [ "active"; "paused"; "done"; "dropped" ]

(* RFC-0089: derive the accepted-value sets from the Goal_phase ADT (the goal
   lifecycle SSOT) instead of hand-rolling them here, so the validator, the MCP
   schema enum, and the type can never drift apart. *)
let goal_phase_strings = List.map Goal_phase.to_string Goal_phase.all

let goal_transition_action_strings =
  List.map Goal_phase.action_to_string Goal_phase.all_actions
;;

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
  (* The typed goal_status is gone (RFC-0352 slice 1); the arg survives only
     so an explicit "status" input keeps its two-stage rejection: enum
     validation first, then the lifecycle-arg rejection in the handler. *)
  match Json_util.assoc_member_opt field args with
  | None | Some `Null -> Ok None
  | Some (`String raw) when String.trim raw = "" -> Ok None
  | Some (`String raw) ->
    let normalized = String.lowercase_ascii (String.trim raw) in
    if List.mem normalized goal_status_strings
    then Ok (Some normalized)
    else Error (make_enum_field_error ~field ~allowed:goal_status_strings ~received:raw)
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
       "masc_goal_upsert does not accept lifecycle field %s; use masc_goal_transition"
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

let update_goal_phase (ctx : context) (goal : Goal_store.goal) ~phase ?note () =
  let last_review_note, last_review_at =
    match note, phase with
    | Some note, _ -> Some note, Some (Masc_domain.now_iso ())
    | None, Goal_phase.Executing -> None, None
    | None,
      (Goal_phase.Blocked | Goal_phase.Paused | Goal_phase.Completed | Goal_phase.Dropped)
      ->
      goal.last_review_note, goal.last_review_at
  in
  Goal_store.update_goal_if_unchanged ctx.config ~expected:goal (fun current ->
    { current with
      phase
    ; last_review_note
    ; last_review_at
    ; completion_review_failure = None
    ; completion_receipt = None
    })
;;

let emit_goal_event (ctx : context) ~goal_id ~event_type ~payload =
  let path =
    Filename.concat (Workspace_utils.masc_dir ctx.config) "goal_events.jsonl"
  in
  Fs_compat.append_jsonl
    path
    (`Assoc
       [ "ts", `String (Masc_domain.now_iso ())
       ; "goal_id", `String goal_id
       ; "event_type", `String event_type
       ; "payload", payload
       ])
;;

let goal_completion_evidence (ctx : context) (goal : Goal_store.goal) =
  match Workspace.read_backlog_r ctx.config with
  | Error msg -> Error ("Goal completion task evidence unavailable: " ^ msg)
  | Ok backlog ->
    (match Workspace_goal_index.read_goal_task_links_r ctx.config with
     | Error msg -> Error ("Goal completion task links unavailable: " ^ msg)
     | Ok goal_task_links ->
       let index =
         Workspace_goal_index.build_goal_task_index
           ~goal_task_links
           backlog.tasks
       in
       let linked_tasks =
         Workspace_goal_index.tasks_for_goal index ~goal_id:goal.id
       in
       let child_goals =
         Goal_store.list_goals ctx.config ()
         |> List.filter (fun (candidate : Goal_store.goal) ->
              candidate.parent_goal_id = Some goal.id)
       in
       Ok (linked_tasks, child_goals))
;;

let persist_nonterminal_goal_review
      (ctx : context)
      (goal : Goal_store.goal)
      ~failure
      ~reason
  =
  Goal_store.update_goal_if_unchanged ctx.config ~expected:goal (fun current ->
    { current with
      last_review_note = Some reason
    ; last_review_at = Some (Masc_domain.now_iso ())
    ; completion_review_failure = Some failure
    ; completion_receipt = None
    })
;;

let conditional_goal_error_result
      ~tool_name
      ~start_time
      (error : Goal_store.conditional_update_error)
  =
  let code =
    match error with
    | Goal_store.Goal_not_found -> Not_found
    | Goal_store.Goal_snapshot_changed -> Conflict
    | Goal_store.Goal_persistence_failed _ -> Internal_error
  in
  let class_ =
    match error with
    | Goal_store.Goal_not_found | Goal_store.Goal_snapshot_changed ->
      Tool_result.Workflow_rejection
    | Goal_store.Goal_persistence_failed _ -> Tool_result.Runtime_failure
  in
  error_result_typed
    ~class_
    ~tool_name
    ~start_time
    ~code
    (Goal_store.conditional_update_error_to_string error)
;;

let handle_goal_completion_request
      ~tool_name
      ~start_time
      (ctx : context)
      (goal : Goal_store.goal)
      ~completion_claim
  =
  match goal_completion_evidence ctx goal with
  | Error msg ->
    (match
       persist_nonterminal_goal_review
         ctx
         goal
         ~failure:Goal_store.Unavailable
         ~reason:msg
     with
     | Error error ->
       conditional_goal_error_result ~tool_name ~start_time error
     | Ok _ ->
       error_result_typed
         ~class_:Tool_result.Transient_error
         ~tool_name
         ~start_time
         ~code:Precondition_failed
         (msg ^ "; Goal remains nonterminal"))
  | Ok (linked_tasks, child_goals) ->
    let request : Goal_completion_reviewer.review_request =
      { goal
      ; completion_claim
      ; agent_name = ctx.agent_name
      ; linked_tasks
      ; child_goals
      }
    in
    let review = Goal_completion_reviewer.review request in
    (match review.verdict, review.gate, review.review_prompt_sha256 with
     | Some Goal_completion_reviewer.Approve,
       Goal_completion_reviewer.Structured_tool,
       Some review_prompt_sha256 ->
       let reviewed_at = Masc_domain.now_iso () in
       let receipt : Goal_store.completion_receipt =
         { evaluator_runtime = review.evaluator_runtime
         ; reviewed_at
         ; reviewed_goal_updated_at = goal.updated_at
         ; review_prompt_sha256
         ; completion_claim
         ; linked_task_ids =
             List.map (fun (task : Masc_domain.task) -> task.id) linked_tasks
         }
       in
       (match
          Goal_store.update_goal_if_unchanged
            ctx.config
            ~expected:goal
            (fun current ->
               { current with
                 phase = Goal_phase.Completed
               ; last_review_note = Some "Configured LLM approved Goal completion"
               ; last_review_at = Some reviewed_at
               ; completion_review_failure = None
               ; completion_receipt = Some receipt
               })
        with
        | Error error ->
          conditional_goal_error_result ~tool_name ~start_time error
        | Ok updated_goal ->
          emit_goal_event
            ctx
            ~goal_id:goal.id
            ~event_type:"goal_completion_approved"
            ~payload:
              (`Assoc
                 [ "actor", `String ctx.agent_name
                 ; "evaluator_runtime", `String review.evaluator_runtime
                 ; "reviewed_at", `String reviewed_at
                 ]);
          ok_result
            ~tool_name
            ~start_time
            [ "goal_id", `String goal.id
            ; "action", `String "request_complete"
            ; "goal", Goal_store.goal_to_yojson updated_goal
            ])
     | Some (Goal_completion_reviewer.Reject reason),
       Goal_completion_reviewer.Structured_tool,
       _ ->
       (match
          persist_nonterminal_goal_review
            ctx
            goal
            ~failure:Goal_store.Rejected
            ~reason
        with
        | Error error ->
          conditional_goal_error_result ~tool_name ~start_time error
        | Ok _ ->
          error_result_typed
            ~tool_name
            ~start_time
            ~code:Precondition_failed
            ("Configured LLM rejected Goal completion: " ^ reason))
     | None,
       ( Goal_completion_reviewer.Invalid_verdict
       | Goal_completion_reviewer.Evaluator_unavailable ),
       _ ->
       let reason =
         Option.value
           ~default:"Configured LLM returned no valid Goal completion verdict"
           review.fallback_reason
       in
       (match
          persist_nonterminal_goal_review
            ctx
            goal
            ~failure:Goal_store.Unavailable
            ~reason
        with
        | Error error ->
          conditional_goal_error_result ~tool_name ~start_time error
        | Ok _ ->
          error_result_typed
            ~class_:Tool_result.Transient_error
            ~tool_name
            ~start_time
            ~code:Precondition_failed
            (reason ^ "; Goal remains nonterminal"))
     | Some _, (Goal_completion_reviewer.Invalid_verdict
               | Goal_completion_reviewer.Evaluator_unavailable), _
     | None, Goal_completion_reviewer.Structured_tool, _
     | Some Goal_completion_reviewer.Approve,
       Goal_completion_reviewer.Structured_tool,
       None ->
       error_result_typed
         ~class_:Tool_result.Runtime_failure
         ~tool_name
         ~start_time
         ~code:Internal_error
         "Goal completion reviewer returned an inconsistent typed outcome")
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
    , parse_optional_priority args "priority" )
  with
  | Error err, _, _ | _, Error err, _ | _, _, Error err ->
    validation_error_result ~tool_name ~start_time [ err ]
  | Ok status, Ok phase, Ok priority ->
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
            ?parent_goal_id
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

let handle_goal_transition ~tool_name ~start_time (ctx : context) args
    : Tool_result.result =
  match
    ( validate_string_required args "goal_id"
    , parse_optional_transition_action args "action" )
  with
  | Error err, _ | _, Error err ->
    validation_error_result ~tool_name ~start_time [ err ]
  | Ok goal_id, Ok (Some action) ->
    let note = get_string_opt args "note" in
    (match Goal_store.get_goal ctx.config ~goal_id with
     | None ->
       error_result_typed ~tool_name ~start_time ~code:Not_found "goal not found"
     | Some goal ->
       (match Goal_phase.decide_transition ~phase:goal.phase ~action with
        | Error msg ->
          error_result_typed ~tool_name ~start_time ~code:Conflict msg
        | Ok Goal_phase.Complete ->
          handle_goal_completion_request
            ~tool_name
            ~start_time
            ctx
            goal
            ~completion_claim:(Option.value ~default:"" note)
        | Ok (Goal_phase.Move_to phase) ->
          (match update_goal_phase ctx goal ~phase ?note () with
           | Error error ->
             conditional_goal_error_result ~tool_name ~start_time error
           | Ok updated_goal ->
             emit_goal_event
               ctx
               ~goal_id
               ~event_type:"goal_phase"
               ~payload:
                 (`Assoc
                    [ "phase", Goal_phase.to_yojson updated_goal.phase
                    ; "actor", `String ctx.agent_name
                    ]);
             ok_result
               ~tool_name
               ~start_time
               [ "goal_id", `String goal_id
               ; "action", `String (Goal_phase.action_to_string action)
               ; "goal", Goal_store.goal_to_yojson updated_goal
               ])))
  | Ok _, Ok None ->
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
;;
