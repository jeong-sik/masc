(* The Browser Lane's status row: the coordinator's HTTP badge, then the
   lane's own reading. The reading's colour was laid over the whole row, so it
   painted "coordinator HTTP" -- red beside a green [connected] when a read
   failed -- and the badge's reset left the failure message uncoloured. *)

let fresh () =
  Masc_tui_types.create_state ~workspace:"test" ~port:8935 ~refresh_interval:2.0 ()

let red = "\027[31m"
let reset = "\027[0m"
let failure = "Read/action failed: HTTP 503"

let row () = Masc_tui_render_prim.coordinator_status_row (fresh ()) ~style:red failure

let test_the_label_wears_no_reading_colour () =
  Alcotest.(check bool) "the row opens on the plain label" true
    (String.starts_with ~prefix:"  coordinator HTTP " (row ()))

let test_the_reading_wears_its_colour () =
  Alcotest.(check bool) "the colour stands right before the reading and closes after it"
    true
    (String.ends_with ~suffix:(red ^ failure ^ reset) (row ()))

let () =
  Alcotest.run "tui_coordinator_status_row"
    [ ( "coordinator status row"
      , [ Alcotest.test_case "the label wears no reading colour" `Quick
            test_the_label_wears_no_reading_colour
        ; Alcotest.test_case "the reading wears its colour" `Quick
            test_the_reading_wears_its_colour
        ] )
    ]
