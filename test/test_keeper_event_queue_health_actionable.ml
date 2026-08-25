(** A deliberately paused keeper must not pin operator_action_required.

    [keeper_event_queue_health_dimensions] splits the non-runnable backlog by
    whether an operator can act on it.  [recoverable] and [shutdown_fenced]
    clear on their own once the owner is restored or the shutdown finishes, so
    they warrant a prompt.  [paused_dead] and [retained_disabled] encode a
    decision the operator already made, so they must stay visible in
    [status_reasons] without demanding action -- otherwise one paused keeper
    raises a permanent alarm that buries the ones needing an answer. *)

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
    [ "status", `String "ok"
    ; "counts_complete", `Bool true
    ; "read_error_count", `Int 0
    ; "transition_outbox_count", `Int 0
    ; "operator_action_required", `Bool false
    ; "runnable_backlog_count", `Int runnable
    ; "recoverable_backlog_count", `Int recoverable
    ; "retained_disabled_backlog_count", `Int retained_disabled
    ; "paused_dead_backlog_count", `Int paused_dead
    ; "shutdown_fenced_backlog_count", `Int shutdown_fenced
    ]
;;

let dimensions input =
  match Fleet.keeper_event_queue_health_dimensions ~stale_after_sec:600.0 input with
  | `Assoc fields -> fields
  | _ -> fail "expected an object"
;;

let bool_field name fields =
  match List.assoc_opt name fields with
  | Some (`Bool b) -> b
  | _ -> fail (name ^ " missing or not a bool")
;;

let reasons fields =
  match List.assoc_opt "status_reasons" fields with
  | Some (`List items) ->
    List.filter_map (function `String s -> Some s | _ -> None) items
  | _ -> []
;;

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

let test_mixed_backlog_is_actionable () =
  let fields = dimensions (queue ~paused_dead:74 ~recoverable:1 ()) in
  check bool "a recoverable entry is not masked by paused ones" true
    (bool_field "operator_action_required" fields)
;;

let () =
  run "Keeper event queue health actionability"
    [ ( "operator_intended"
      , [ test_case "paused_dead" `Quick test_paused_dead_is_not_actionable
        ; test_case "retained_disabled" `Quick test_retained_disabled_is_not_actionable
        ; test_case "stays visible" `Quick test_paused_dead_stays_visible
        ] )
    ; ( "actionable"
      , [ test_case "recoverable" `Quick test_recoverable_is_actionable
        ; test_case "shutdown_fenced" `Quick test_shutdown_fenced_is_actionable
        ; test_case "mixed" `Quick test_mixed_backlog_is_actionable
        ] )
    ]
;;
