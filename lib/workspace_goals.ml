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
    match note with
    | Some note -> Some note, Some (Masc_domain.now_iso ())
    | None -> goal.last_review_note, goal.last_review_at
  in
  Goal_store.update_goal ctx.config ~goal_id:goal.id (fun current ->
    { current with
      phase
    ; status = Goal_store.goal_status_of_phase phase
    ; last_review_note
    ; last_review_at
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
            ?status
            ?phase
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
        | Ok outcome ->
          let phase =
            match outcome with
            | Goal_phase.Complete -> Goal_phase.Completed
            | Goal_phase.Move_to phase -> phase
          in
          (match update_goal_phase ctx goal ~phase ?note () with
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
