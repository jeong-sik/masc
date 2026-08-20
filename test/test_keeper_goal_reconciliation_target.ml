(** Who a Goal completion wakes when several keepers carry it.

    The resolver used to fail whenever the reverse index of [active_goal_ids]
    held more than one name. A collaboration mission puts five keepers on one
    goal, so every completion logged an ambiguity error, and since the failure
    changed no state the next scan found the same goal and failed again — 51
    hours of it in the live store (#29083).

    Treating several recipients as an error was the mistake. A wake is a message
    into a keeper's queue, not a contract, and MASC's own rule says not to use
    `Ambiguous` as a scheduling gate. So the gate is gone: everyone carrying the
    goal hears, and the declared owner (RFC-0362) narrows that when the Goal
    names one who is actually working under it. *)

open Alcotest
open Masc

let resolve = Keeper_goal_reconciliation_wake.resolve_assignment
let names = list string

let () =
  run "keeper_goal_reconciliation_target"
    [ ( "assignment"
      , [ test_case "several carriers all hear" `Quick (fun () ->
            check names "everyone carrying the goal"
              [ "build-a"; "build-b"; "coord"; "research"; "review" ]
              (resolve ~owner:None
                 ~keeper_names:[ "build-a"; "build-b"; "coord"; "research"; "review" ]))
        ; test_case "declared owner narrows the wake" `Quick (fun () ->
            check names "only the owner"
              [ "coord" ]
              (resolve ~owner:(Some "coord")
                 ~keeper_names:[ "build-a"; "build-b"; "coord" ]))
        ; test_case "owner outside the working set does not silence the rest" `Quick
            (fun () ->
              check names "everyone still hears"
                [ "build-a"; "build-b" ]
                (resolve ~owner:(Some "retired") ~keeper_names:[ "build-a"; "build-b" ]))
        ; test_case "single carrier is unchanged" `Quick (fun () ->
            check names "the one carrier" [ "solo" ] (resolve ~owner:None ~keeper_names:[ "solo" ]))
        ; test_case "nobody carrying stays empty" `Quick (fun () ->
            check names "no recipients" [] (resolve ~owner:(Some "coord") ~keeper_names:[]))
        ] )
    ]
;;
