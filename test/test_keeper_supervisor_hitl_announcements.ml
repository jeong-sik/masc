(* Pending HITL counts are state the supervisor sweep reads every 30 s. A
   line per sweep while nothing changed was five keepers times 120 lines an
   hour (#34643); a count is announced when it differs from the last one
   announced, including its return to zero. *)

module S = Masc.Keeper_supervisor

let announcement =
  Alcotest.testable
    (fun fmt (a : S.hitl_announcement) ->
       Format.fprintf fmt "%s=%d" a.keeper_name a.pending_count)
    (fun (a : S.hitl_announcement) b ->
       String.equal a.keeper_name b.keeper_name && a.pending_count = b.pending_count)
;;

let check label expected actual = Alcotest.(check (list announcement)) label expected actual

let test_first_sweep_announces_every_pending_keeper () =
  check
    "nothing announced yet"
    [ { keeper_name = "code-reviewer"; pending_count = 4 }
    ; { keeper_name = "verifier"; pending_count = 1 }
    ]
    (S.pending_hitl_announcements
       ~announced:[]
       ~counts:[ "code-reviewer", 4; "verifier", 1 ])
;;

let test_unchanged_counts_are_silent () =
  check
    "same counts as last sweep"
    []
    (S.pending_hitl_announcements
       ~announced:[ "code-reviewer", 4; "verifier", 1 ]
       ~counts:[ "code-reviewer", 4; "verifier", 1 ])
;;

let test_a_changed_count_is_announced_alone () =
  check
    "only the keeper whose count moved"
    [ { keeper_name = "verifier"; pending_count = 2 } ]
    (S.pending_hitl_announcements
       ~announced:[ "code-reviewer", 4; "verifier", 1 ]
       ~counts:[ "code-reviewer", 4; "verifier", 2 ])
;;

let test_a_cleared_keeper_is_announced_as_zero () =
  check
    "verifier left the pending set"
    [ { keeper_name = "verifier"; pending_count = 0 } ]
    (S.pending_hitl_announcements
       ~announced:[ "code-reviewer", 4; "verifier", 1 ]
       ~counts:[ "code-reviewer", 4 ])
;;

let () =
  Alcotest.run
    "keeper_supervisor_hitl_announcements"
    [ ( "announce on change"
      , [ Alcotest.test_case "first sweep announces every pending keeper" `Quick
            test_first_sweep_announces_every_pending_keeper
        ; Alcotest.test_case "unchanged counts are silent" `Quick
            test_unchanged_counts_are_silent
        ; Alcotest.test_case "a changed count is announced alone" `Quick
            test_a_changed_count_is_announced_alone
        ; Alcotest.test_case "a cleared keeper is announced as zero" `Quick
            test_a_cleared_keeper_is_announced_as_zero
        ] )
    ]
;;
