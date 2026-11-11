module Status = Masc.Keeper_cleanup_status
module Step = Masc.Keeper_cleanup_step

let row keeper attempt : Status.row =
  { keeper; attempt; finished_at = 1.; reclaimed_at = None }
;;

let builds failed = Status.Guest_builds (Status.Reclaimed { Status.cleaned = 1; failed })

let workspace failed =
  Status.Remote_workspace
    (Status.Reclaimed
       { Status.removed = 1; skipped = 0; failed; freed_kib = 0; available_kib = 1 })
;;

let keepers rows = List.map (fun (found : Status.row) -> found.keeper) rows

let test_rows_that_ask_for_a_look_come_first () =
  let first, others =
    Masc_tui_storage.arrange
      [ row "quiet-b" (builds 0)
      ; row "left-b" (workspace 2)
      ; row "failed-b" (Status.Remote_workspace (Status.Failed "ssh: timeout"))
      ; row "busy" (Status.Guest_builds (Status.Deferred "turn busy"))
      ; row "left-a" (builds 1)
      ; row "failed-a" (Status.Guest_builds (Status.Failed "exit=1"))
      ; row "stopped" (Status.Guest_builds Status.Not_running)
      ; row "quiet-a" (workspace 0)
      ]
  in
  Alcotest.(check (list string))
    "failed attempts, then runs that left entries behind, each by Keeper name"
    [ "failed-a"; "failed-b"; "left-a"; "left-b" ]
    (keepers first);
  Alcotest.(check (list string))
    "every other row, by Keeper name"
    [ "busy"; "quiet-a"; "quiet-b"; "stopped" ]
    (keepers others)
;;

let step =
  Alcotest.testable
    (fun ppf candidate -> Format.pp_print_string ppf (Step.to_string candidate))
    Step.equal
;;

let test_one_keepers_rows_follow_the_step_list () =
  let first, others =
    Masc_tui_storage.arrange [ row "keeper" (workspace 0); row "keeper" (builds 0) ]
  in
  Alcotest.(check int) "neither asks for a look" 0 (List.length first);
  let ran = List.map (fun (found : Status.row) -> Status.step found.attempt) others in
  Alcotest.(check (list step))
    "in the order the steps run"
    (List.filter (fun candidate -> List.exists (Step.equal candidate) ran) Step.all)
    ran
;;

let () =
  Alcotest.run
    "TUI storage reading"
    [ ( "rows"
      , [ Alcotest.test_case
            "Rows that ask for a look come first"
            `Quick
            test_rows_that_ask_for_a_look_come_first
        ; Alcotest.test_case
            "One Keeper's rows follow the step list"
            `Quick
            test_one_keepers_rows_follow_the_step_list
        ] )
    ]
;;
