(** Every surface footer ends with the same status facts.

    Before Masc_tui_footer each of the 21 footers spelled [Port: %d] into its
    own format string, so a screen could carry a different spelling, a
    different separator, or no port at all and nothing would say so. These
    tests pin the shared tail. *)

let check_string = Alcotest.(check string)

let test_port_closes_every_footer () =
  check_string "port closes a plain footer"
    "<dim>  j/k:move  Tab:next  | Port: 8935<reset>\n"
    (Masc_tui_footer.line ~dim:"<dim>" ~reset:"<reset>" ~port:8935
       ~hints:"j/k:move  Tab:next" ())

let test_extra_facts_precede_port () =
  check_string "a surface's own fact reads before the port"
    "<dim>  q:quit  | Refresh: 5s | Port: 8935<reset>\n"
    (Masc_tui_footer.line
       ~status:[ Masc_tui_footer.Refresh_interval 5.0 ]
       ~dim:"<dim>" ~reset:"<reset>" ~port:8935 ~hints:"q:quit" ())

let test_hints_do_not_change_the_tail () =
  (* Two surfaces with nothing in common still end identically. *)
  let tail line =
    let marker = "  | " in
    let index = Str.search_forward (Str.regexp_string marker) line 0 in
    String.sub line index (String.length line - index)
  in
  let overview =
    Masc_tui_footer.line ~dim:"" ~reset:"" ~port:8935
      ~hints:"j/k:events  t:tasks  q:quit" ()
  in
  let help =
    Masc_tui_footer.line ~dim:"" ~reset:"" ~port:8935
      ~hints:"j/k:scroll  Esc:close" ()
  in
  check_string "same tail" (tail overview) (tail help)

let tests =
  [ ( "tui-footer-status-items"
    , [ Alcotest.test_case "port closes every footer" `Quick
          test_port_closes_every_footer
      ; Alcotest.test_case "extra facts precede port" `Quick
          test_extra_facts_precede_port
      ; Alcotest.test_case "hints do not change the tail" `Quick
          test_hints_do_not_change_the_tail
      ] )
  ]

let () = Alcotest.run "tui_footer_status_items" tests
