(* The fleet bulk cancel plans rows once and cancels exactly those rows, so a
   dry run and the execution it authorises can never disagree. These tests pin
   the pure planning and execution seams; the durable per-Keeper transition
   they call is covered by the event-queue suite. *)

open Alcotest

module Bulk = Server_dashboard_http_keeper_event_queue_bulk

let row ?(source_ref = String.make 64 'a') ?(source_incarnation = 1L) ~keeper ~source ~since () =
  { Bulk.keeper_name = keeper
  ; source_ref
  ; source_incarnation
  ; source_label = source
  ; since
  }
;;

let rows () =
  [ row ~keeper:"alpha" ~source:"board_signal" ~since:100.0 ()
  ; row ~keeper:"alpha" ~source:"schedule_due" ~since:90.0 ()
  ; row ~keeper:"beta" ~source:"board_signal" ~since:80.0 ()
  ]
;;

let test_parse_defaults_to_dry_run () =
  let body =
    {|{"schema":"keeper_event_queue.bulk.request.v1","action":"cancel","reason":"operator cleared the queue"}|}
  in
  match Bulk.parse body with
  | Error detail -> fail detail
  | Ok request ->
    check bool "dry run by default" true request.Bulk.dry_run;
    check (option string) "no confirm token" None request.confirm;
    check (option (list string)) "no keeper filter" None request.filter.keepers
;;

let test_parse_rejects_unknown_schema () =
  let body = {|{"schema":"nope","action":"cancel","reason":"x"}|} in
  match Bulk.parse body with
  | Ok _ -> fail "unknown schema was accepted"
  | Error _ -> ()
;;

let test_parse_accepts_execution_with_confirm () =
  let body =
    {|{"schema":"keeper_event_queue.bulk.request.v1","action":"cancel","dry_run":false,"confirm":"cancel-pending-events","reason":"operator cleared the queue"}|}
  in
  match Bulk.parse body with
  | Error detail -> fail detail
  | Ok request ->
    check bool "execution requested" false request.Bulk.dry_run;
    check (option string) "confirm token" (Some "cancel-pending-events") request.confirm
;;

let test_plan_filters_by_keeper () =
  let filter = { Bulk.keepers = Some [ "alpha" ]; sources = None } in
  let planned = Bulk.plan_rows filter (rows ()) in
  check int "only alpha rows" 2 (List.length planned);
  check bool "every planned row is alpha" true
    (List.for_all (fun r -> String.equal r.Bulk.keeper_name "alpha") planned)
;;

let test_plan_filters_by_source () =
  let filter = { Bulk.keepers = None; sources = Some [ "schedule_due" ] } in
  let planned = Bulk.plan_rows filter (rows ()) in
  check int "only schedule rows" 1 (List.length planned);
  check string "the schedule row's keeper" "alpha" (List.hd planned).Bulk.keeper_name
;;

let test_plan_without_filter_keeps_every_row () =
  let filter = { Bulk.keepers = None; sources = None } in
  check int "all rows" 3 (List.length (Bulk.plan_rows filter (rows ())))
;;

(* The invariant the operator relies on: the number a dry run reports is the
   number of rows the execution then cancels, and no filtered-out row is
   touched. *)
let test_execution_cancels_exactly_the_planned_rows () =
  let filter = { Bulk.keepers = Some [ "alpha" ]; sources = None } in
  let planned = Bulk.plan_rows filter (rows ()) in
  let seen = ref [] in
  let cancel ~operation_id:_ ~reason:_ r =
    seen := r :: !seen;
    `Assoc [ "keeper_name", `String r.Bulk.keeper_name; "ok", `Bool true ]
  in
  let results = Bulk.execute_rows ~cancel ~operation_id:"op" ~reason:"x" planned in
  check int "dry-run count equals executed count" (List.length planned)
    (List.length results);
  check int "recorder saw every planned row" (List.length planned)
    (List.length !seen);
  check bool "no beta row was cancelled" true
    (List.for_all (fun r -> not (String.equal r.Bulk.keeper_name "beta")) !seen)
;;

let test_count_by_keeper () =
  let counts = Bulk.count_by (fun r -> r.Bulk.keeper_name) (rows ()) in
  check (list (pair string int)) "keeper counts"
    [ "alpha", 2; "beta", 1 ]
    counts
;;

let test_oldest_age_is_positive () =
  match Bulk.oldest_age_seconds (rows ()) with
  | None -> fail "expected an oldest age"
  | Some age -> check bool "oldest age is positive" true (age > 0.0)
;;

let test_oldest_age_of_empty_is_none () =
  check (option (float 0.0)) "empty has no age" None (Bulk.oldest_age_seconds [])
;;

let () =
  run
    "keeper_event_queue_bulk"
    [ ( "parse"
      , [ test_case "defaults to dry run" `Quick test_parse_defaults_to_dry_run
        ; test_case "rejects unknown schema" `Quick test_parse_rejects_unknown_schema
        ; test_case
            "accepts execution with confirm"
            `Quick
            test_parse_accepts_execution_with_confirm
        ] )
    ; ( "plan"
      , [ test_case "filters by keeper" `Quick test_plan_filters_by_keeper
        ; test_case "filters by source" `Quick test_plan_filters_by_source
        ; test_case
            "without filter keeps every row"
            `Quick
            test_plan_without_filter_keeps_every_row
        ] )
    ; ( "execute"
      , [ test_case
            "cancels exactly the planned rows"
            `Quick
            test_execution_cancels_exactly_the_planned_rows
        ] )
    ; ( "counts"
      , [ test_case "counts by keeper" `Quick test_count_by_keeper
        ; test_case "oldest age is positive" `Quick test_oldest_age_is_positive
        ; test_case "empty has no age" `Quick test_oldest_age_of_empty_is_none
        ] )
    ]
;;
