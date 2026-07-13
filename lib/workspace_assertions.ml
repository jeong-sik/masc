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

(** Workspace_assertions - State inspection and assertion-based verification *)

open Masc_domain
open Workspace_types

type agent_state =
  { task_claimed : bool
  ; current_task_set : bool
  }

type assertion_kind =
  | Task_claimed
  | Current_task_set

let assertion_kind_to_string = function
  | Task_claimed -> "task_claimed"
  | Current_task_set -> "current_task_set"
;;

let all_assertion_kinds = [ Task_claimed; Current_task_set ]

let valid_assertion_strings = List.map assertion_kind_to_string all_assertion_kinds

let assertion_kind_of_string_lenient = function
  | "task_claimed" -> Some Task_claimed
  | "current_task_set" -> Some Current_task_set
  | _ -> None
;;

let assertion_fix_hint = function
  | Task_claimed -> "Claim a task with masc_transition(action=claim) or keeper_task_claim"
  | Current_task_set ->
    "Call masc_plan_set_task to choose or re-sync the active task when current_task is \
     unset, stale, or ambiguous"
;;

let assertion_passes st = function
  | Task_claimed -> st.task_claimed
  | Current_task_set -> st.current_task_set
;;

let check_assertion st assertion =
  match assertion_kind_of_string_lenient assertion with
  | Some kind ->
    let passed = assertion_passes st kind in
    let fix_hint = assertion_fix_hint kind in
    `Assoc
      [ "assertion", `String assertion
      ; "passed", `Bool passed
      ; ("fix_hint", if passed then `Null else `String fix_hint)
      ]
  | None ->
    `Assoc
      [ "assertion", `String assertion
      ; "passed", `Bool false
      ; ( "fix_hint"
        , `String
            (Printf.sprintf
               "Unknown assertion: %s (expected one of: %s)"
               assertion
               (String.concat ", " valid_assertion_strings)) )
      ]
;;

let state_to_json st =
  `Assoc
    [ "task_claimed", `Bool st.task_claimed
    ; "current_task_set", `Bool st.current_task_set
    ; "session_active", `Bool false
    ]
;;

let handle_check ~(inspect_state : context -> agent_state) ~tool_name ~start_time ctx args
  =
  let st = inspect_state ctx in
  let default_assertions = [ "task_claimed"; "current_task_set" ] in
  let assertions =
    match Json_util.assoc_member_opt "assertions" args with
    | Some (`List items) ->
      let parsed =
        List.filter_map
          (function
            | `String s -> Some s
            | _ -> None)
          items
      in
      (match parsed with
       | [] -> default_assertions
       | _ -> parsed)
    | _ -> default_assertions
  in
  let results = List.map (check_assertion st) assertions in
  let all_passed =
    List.for_all
      (fun r ->
         match Json_util.assoc_member_opt "passed" r with
         | Some (`Bool b) -> b
         | _ -> false)
      results
  in
  let fix_hint =
    if all_passed
    then `Null
    else (
      let first_fail =
        List.find_opt
          (fun r ->
             match Json_util.assoc_member_opt "passed" r with
             | Some (`Bool false) -> true
             | _ -> false)
          results
      in
      match first_fail with
      | Some r ->
        (match Json_util.assoc_member_opt "fix_hint" r with
         | Some v -> v
         | None -> `Null)
      | None -> `Null)
  in
  let result =
    `Assoc
      [ "assertions", `List results
      ; "all_passed", `Bool all_passed
      ; "fix_hint", fix_hint
      ]
  in
  Tool_result.make_ok ~tool_name ~start_time ~data:result ()
;;
