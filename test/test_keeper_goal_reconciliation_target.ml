(** Which keeper a Goal completion wakes when several carry the goal.

    The resolver reads the reverse index of keepers holding the goal in
    [active_goal_ids] and, before this change, failed outright whenever that
    index held more than one name. A collaboration mission puts five keepers on
    one goal, so every completion in the E0 campaign logged an ambiguity error.
    The failure left goal and task state untouched, so the next scan found the
    same goal ready and failed again — fifty-one hours of it in the live store.

    RFC-0362's [owner] already names the keeper responsible for turning the Goal
    into Tasks. These tests pin that it settles the tie, and that it never
    invents a target: a Goal with no owner, or one naming somebody who is not
    working under it, still fails. *)

open Alcotest
open Masc

let resolve = Keeper_goal_reconciliation_wake.resolve_ambiguous_assignment

let () =
  run "keeper_goal_reconciliation_target"
    [ ( "owner"
      , [ test_case "declared owner settles a multi-keeper goal" `Quick (fun () ->
            match
              resolve ~goal_id:"goal-collab" ~owner:(Some "coord")
                ~keeper_names:[ "build-a"; "build-b"; "coord"; "research"; "review" ]
            with
            | Ok name -> check string "wakes the owner" "coord" name
            | Error detail -> fail ("expected the owner, got error: " ^ detail))
        ; test_case "no declared owner stays an error" `Quick (fun () ->
            match
              resolve ~goal_id:"goal-ownerless" ~owner:None
                ~keeper_names:[ "build-a"; "build-b" ]
            with
            | Error detail ->
              check bool "names the missing owner" true
                (String_util.contains_substring detail "no declared owner")
            | Ok name ->
              fail ("an ownerless goal must not pick a target, picked: " ^ name))
        ; test_case "owner outside the working set stays an error" `Quick (fun () ->
            match
              resolve ~goal_id:"goal-stale-owner" ~owner:(Some "retired")
                ~keeper_names:[ "build-a"; "build-b" ]
            with
            | Error detail ->
              check bool "names the mismatch" true
                (String_util.contains_substring detail "not among its active keepers")
            | Ok name ->
              fail ("an owner nobody works under must not be woken, picked: " ^ name))
        ; test_case "single-keeper set still honours a matching owner" `Quick (fun () ->
            match
              resolve ~goal_id:"goal-solo" ~owner:(Some "solo")
                ~keeper_names:[ "solo" ]
            with
            | Ok name -> check string "wakes the owner" "solo" name
            | Error detail -> fail ("expected the owner, got error: " ^ detail))
        ] )
    ]
;;
