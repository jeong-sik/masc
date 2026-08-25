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

(* Stands in for an [assertions] element that was not a JSON string. It is
   deliberately not a valid assertion name, so [check_assertion] reports it
   with [passed = false] and [expected_assertions] instead of the caller
   losing the element silently. *)
let unreadable_assertion = "<non-string assertion>"

let assertion_kind_of_string_lenient = function
  | "task_claimed" -> Some Task_claimed
  | "current_task_set" -> Some Current_task_set
  | _ -> None
;;

let assertion_passes st = function
  | Task_claimed -> st.task_claimed
  | Current_task_set -> st.current_task_set
;;

let check_assertion st assertion =
  match assertion_kind_of_string_lenient assertion with
  | Some kind ->
    let passed = assertion_passes st kind in
    `Assoc
      [ "assertion", `String assertion
      ; "passed", `Bool passed
      ]
  | None ->
    `Assoc
      [ "assertion", `String assertion
      ; "passed", `Bool false
      ; ( "expected_assertions"
        , `List (List.map (fun value -> `String value) valid_assertion_strings) )
      ]
;;

let handle_check ~(inspect_state : context -> agent_state) ~tool_name ~start_time ctx args
  =
  let st = inspect_state ctx in
  let default_assertions = [ "task_claimed"; "current_task_set" ] in
  let assertions =
    match Json_util.assoc_member_opt "assertions" args with
    | Some (`List items) ->
      (* Total, so the list the caller sent and the list that gets checked
         have the same length. [List.filter_map] dropped anything that was
         not a JSON string before it reached [check_assertion], so the
         element never appeared in the response and [all_passed] answered a
         narrower question than the caller asked. [check_assertion] already
         handles input it cannot read -- an unrecognised name comes back
         [passed = false] with [expected_assertions] -- and a wrong-typed
         element now takes that same path. *)
      let parsed =
        List.map
          (function
            | `String s -> s
            | _ -> unreadable_assertion)
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
  let result =
    `Assoc
      [ "assertions", `List results
      ; "all_passed", `Bool all_passed
      ]
  in
  Tool_result.make_ok ~tool_name ~start_time ~data:result ()
;;
