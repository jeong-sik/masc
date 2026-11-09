open Alcotest
module Fleet_summary = Masc_tui_fleet_summary

let reading =
  testable
    (fun formatter value ->
      Format.pp_print_string formatter
        (match value with
         | Fleet_summary.Running -> "running"
         | Fleet_summary.Turn_capacity -> "turn capacity"
         | Fleet_summary.Blocker -> "blocker"
         | Fleet_summary.Proactive_interval -> "proactive interval"))
    ( = )

let select ~cells readings =
  Fleet_summary.select ~cells ~lead_cells:16 ~separator_cells:3 readings

let test_selection_charges_lead_and_separators () =
  let readings = [ Fleet_summary.Running, 11; Fleet_summary.Turn_capacity, 19 ] in
  check (list reading) "the complete prefix fits at its exact boundary"
    [ Fleet_summary.Running; Fleet_summary.Turn_capacity ]
    (select ~cells:52 readings);
  check (list reading) "one fewer cell drops the rightmost reading"
    [ Fleet_summary.Running ]
    (select ~cells:51 readings)

let test_selection_drops_the_rightmost_reading_first () =
  let readings =
    [ Fleet_summary.Running, 11
    ; Fleet_summary.Turn_capacity, 19
    ; Fleet_summary.Blocker, 24
    ]
  in
  check (list reading) "the blocker yields before either count"
    [ Fleet_summary.Running; Fleet_summary.Turn_capacity ]
    (select ~cells:60 readings)

let test_an_oversized_blocker_preserves_earlier_counts () =
  let readings =
    [ Fleet_summary.Running, 11
    ; Fleet_summary.Turn_capacity, 19
    ; Fleet_summary.Blocker, 100
    ]
  in
  check (list reading) "the oversized tail is the only omitted reading"
    [ Fleet_summary.Running; Fleet_summary.Turn_capacity ]
    (select ~cells:52 readings)

let test_no_reading_fits_inside_the_lead () =
  check (list reading) "no count is admitted without its whole cell budget" []
    (select ~cells:19 [ Fleet_summary.Running, 11 ])

let () =
  run "tui fleet summary"
    [ ( "reading selection"
      , [ test_case "lead and separators consume the cell budget" `Quick
            test_selection_charges_lead_and_separators
        ; test_case "the rightmost reading is dropped first" `Quick
            test_selection_drops_the_rightmost_reading_first
        ; test_case "an oversized blocker preserves earlier counts" `Quick
            test_an_oversized_blocker_preserves_earlier_counts
        ; test_case "no reading fits inside the lead" `Quick
            test_no_reading_fits_inside_the_lead
        ] )
    ]
