(** A deliberately paused keeper must not pin operator_action_required.

    [keeper_event_queue_health_dimensions] splits the non-runnable backlog by
    whether an operator can act on it.  [recoverable] and [shutdown_fenced]
    clear on their own once the owner is restored or the shutdown finishes, so
    they warrant a prompt.  [paused_dead] and [retained_disabled] encode a
    decision the operator already made, so they must stay visible in
    [status_reasons] without demanding action -- otherwise one paused keeper
    raises a permanent alarm that buries the ones needing an answer.

    The fixture carries counts only, matching the durable summary: that summary
    states no [status] and no [operator_action_required], so this surface is
    the only place either is decided. Both are checked here, because the
    verdict used to travel as a boolean and as a status string, and narrowing
    only the boolean would leave the two disagreeing. *)

open Alcotest

module Fleet = Server_routes_http_runtime_health_fleet

let queue
      ?(runnable = 0)
      ?(recoverable = 0)
      ?(retained_disabled = 0)
      ?(paused_dead = 0)
      ?(shutdown_fenced = 0)
      ()
  =
  `Assoc
    [ "counts_complete", `Bool true
    ; "read_error_count", `Int 0
    ; "transition_outbox_count", `Int 0
    ; "runnable_backlog_count", `Int runnable
    ; "recoverable_backlog_count", `Int recoverable
    ; "retained_disabled_backlog_count", `Int retained_disabled
    ; "paused_dead_backlog_count", `Int paused_dead
    ; "shutdown_fenced_backlog_count", `Int shutdown_fenced
    ]
;;

let dimensions input =
  match Fleet.keeper_event_queue_health_dimensions ~source_unavailable:false input with
  | `Assoc fields -> fields
  | _ -> fail "expected an object"
;;

let bool_field name fields =
  match List.assoc_opt name fields with
  | Some (`Bool b) -> b
  | _ -> fail (name ^ " missing or not a bool")
;;

let string_field name fields =
  match List.assoc_opt name fields with
  | Some (`String s) -> s
  | _ -> fail (name ^ " missing or not a string")
;;

let string_list name fields =
  match List.assoc_opt name fields with
  | Some (`List items) ->
    List.filter_map (function `String s -> Some s | _ -> None) items
  | _ -> []
;;

let reasons fields = string_list "status_reasons" fields
let action_reasons fields = string_list "operator_action_reasons" fields

let test_paused_dead_is_not_actionable () =
  let fields = dimensions (queue ~paused_dead:74 ()) in
  check bool "a paused keeper alone does not demand operator action" false
    (bool_field "operator_action_required" fields)
;;

let test_retained_disabled_is_not_actionable () =
  let fields = dimensions (queue ~retained_disabled:5 ()) in
  check bool "autoboot/proactive off does not demand operator action" false
    (bool_field "operator_action_required" fields)
;;

let test_recoverable_is_actionable () =
  let fields = dimensions (queue ~recoverable:1 ()) in
  check bool "a recoverable owner still demands action" true
    (bool_field "operator_action_required" fields)
;;

let test_shutdown_fenced_is_actionable () =
  let fields = dimensions (queue ~shutdown_fenced:28 ()) in
  check bool "a fenced shutdown still demands action" true
    (bool_field "operator_action_required" fields)
;;

let test_paused_dead_stays_visible () =
  let fields = dimensions (queue ~paused_dead:74 ()) in
  check bool "the paused backlog is still reported with its depth" true
    (List.exists (String.equal "paused_dead_backlog=74") (reasons fields))
;;

let test_paused_dead_leaves_status_ok () =
  let fields = dimensions (queue ~paused_dead:74 ()) in
  check string "a paused keeper alone does not degrade the queue" "ok"
    (string_field "status" fields)
;;

(* Both halves of the verdict, per backlog kind. [runnable] is the case where
   they deliberately disagree: work in flight shows as a warning without asking
   the operator for anything, so no relation between the two fields can stand in
   for checking each one. *)
let test_both_verdict_fields_per_backlog_kind () =
  List.iter
    (fun (label, input, expected_status, expected_action) ->
       let fields = dimensions input in
       check string (label ^ ": status") expected_status
         (string_field "status" fields);
       check bool (label ^ ": operator_action_required") expected_action
         (bool_field "operator_action_required" fields))
    [ "paused_dead", queue ~paused_dead:74 (), "ok", false
    ; "retained_disabled", queue ~retained_disabled:5 (), "ok", false
    ; "runnable", queue ~runnable:18 (), "warning", false
    ; "recoverable", queue ~recoverable:1 (), "warning", true
    ; "shutdown_fenced", queue ~shutdown_fenced:28 (), "warning", true
    ]
;;

let test_mixed_backlog_is_actionable () =
  let fields = dimensions (queue ~paused_dead:74 ~recoverable:1 ()) in
  check bool "a recoverable entry is not masked by paused ones" true
    (bool_field "operator_action_required" fields)
;;

(* The verdict was right and the list beside it was not. #34781 stopped a
   paused keeper opening the alarm; the health rollup then hoisted every
   [status_reasons] entry of a section whose gate had opened for another
   reason, so the paused-dead line arrived in the operator list anyway
   (#34894). [operator_action_reasons] is the subset behind the verdict. *)
let test_action_reasons_exclude_the_operators_own_decision () =
  let fields =
    dimensions (queue ~runnable:33 ~recoverable:105 ~paused_dead:41 ~retained_disabled:5 ())
  in
  check bool "the mix still demands action" true
    (bool_field "operator_action_required" fields);
  check (list string) "everything stays on screen"
    [ "runnable_backlog=33"
    ; "recoverable_backlog=105"
    ; "retained_disabled_backlog=5"
    ; "paused_dead_backlog=41"
    ]
    (reasons fields);
  check (list string) "only the recoverable backlog needs an answer"
    [ "recoverable_backlog=105" ]
    (action_reasons fields)
;;

let test_action_reasons_are_empty_when_nothing_needs_an_answer () =
  let fields = dimensions (queue ~runnable:18 ~paused_dead:74 ()) in
  check bool "neither kind demands action" false
    (bool_field "operator_action_required" fields);
  check (list string) "and neither is offered as one" [] (action_reasons fields)
;;

let test_a_storage_read_error_needs_an_answer () =
  let fields =
    dimensions
      (`Assoc
         [ "counts_complete", `Bool true
         ; "read_error_count", `Int 2
         ; "transition_outbox_count", `Int 0
         ; "runnable_backlog_count", `Int 0
         ; "recoverable_backlog_count", `Int 0
         ; "retained_disabled_backlog_count", `Int 0
         ; "paused_dead_backlog_count", `Int 9
         ; "shutdown_fenced_backlog_count", `Int 0
         ])
  in
  check (list string) "the storage error is the answer owed, not the paused backlog"
    [ "storage_read_error" ]
    (action_reasons fields)
;;

let () =
  run "Keeper event queue health actionability"
    [ ( "operator_intended"
      , [ test_case "paused_dead" `Quick test_paused_dead_is_not_actionable
        ; test_case "retained_disabled" `Quick test_retained_disabled_is_not_actionable
        ; test_case "stays visible" `Quick test_paused_dead_stays_visible
        ; test_case "status stays ok" `Quick test_paused_dead_leaves_status_ok
        ] )
    ; ( "both verdict fields"
      , [ test_case "per backlog kind" `Quick
            test_both_verdict_fields_per_backlog_kind
        ] )
    ; ( "actionable"
      , [ test_case "recoverable" `Quick test_recoverable_is_actionable
        ; test_case "shutdown_fenced" `Quick test_shutdown_fenced_is_actionable
        ; test_case "mixed" `Quick test_mixed_backlog_is_actionable
        ] )
    ; ( "reasons behind the verdict"
      , [ test_case "exclude the operator's own decision" `Quick
            test_action_reasons_exclude_the_operators_own_decision
        ; test_case "empty when nothing needs an answer" `Quick
            test_action_reasons_are_empty_when_nothing_needs_an_answer
        ; test_case "a storage read error needs an answer" `Quick
            test_a_storage_read_error_needs_an_answer
        ] )
    ]
;;
