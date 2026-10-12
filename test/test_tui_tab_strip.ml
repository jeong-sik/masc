(* The strips a reader switches along share one drawing: the current entry
   marked, the others plain, two cells between. Activity's readings and
   Config's panes used to put a "|" between names and a space before the
   unmarked ones, so a marked name sat hard against the bar before it:
   "runtime.toml |▸models | params". *)

let plain ?(width = 80) tabs =
  Masc_tui_theme.strip_sgr
    (Masc_tui_ansi.tab_strip ~width
       ~press:(fun () text -> text)
       (List.map (fun (label, current) -> (label, current, ())) tabs))

let cells = Masc_tui_message_layout.display_width

let test_a_cut_mark_leads_to_the_nearest_hidden_entry () =
  let names = [| "Info"; "Chat"; "Config"; "Logs"; "Calls"; "Memory"; "Runs" |] in
  let registry = Masc_tui_hit.registry () in
  let drawn =
    Masc_tui_ansi.tab_strip ~width:24 ~press:(Masc_tui_hit.mark registry)
      (Array.to_list (Array.map (fun name -> (name, name = "Logs", name)) names))
  in
  let _lines, zones = Masc_tui_hit.extract registry [ drawn ] in
  Alcotest.(check (list string))
    "the left cut, the drawn entries, the right cut"
    [ "Config"; "Logs"; "Calls"; "Memory" ]
    (List.map (fun (_, _, _, target) -> target) (Masc_tui_hit.to_list zones))

(* Narrower than its current entry, the strip is cut by [fit_width], which
   drops what follows the cut, a mark's close included. An unclosed mark runs
   to the end of the row, so a cut count's press would cover the clock drawn
   after the strip. A cut strip presses nothing past its own width. *)
let test_a_cut_strip_presses_nothing_past_its_width () =
  let tabs =
    [ ("stack", true, "stack"); ("request", false, "request"); ("proof", false, "proof") ]
  in
  let width = Masc_tui_ansi.tab_strip_min_width tabs - 1 in
  let registry = Masc_tui_hit.registry () in
  let drawn =
    Masc_tui_ansi.tab_strip ~width ~press:(Masc_tui_hit.mark registry) tabs
  in
  Alcotest.(check bool) "the strip is cut to its width" true (cells drawn <= width);
  let _lines, zones = Masc_tui_hit.extract registry [ drawn ^ "  12:00:00" ] in
  List.iter
    (fun (_, _, last, target) ->
      Alcotest.(check bool) (target ^ " ends within the strip") true (last <= width))
    (Masc_tui_hit.to_list zones)

let () =
  Alcotest.run "tui_tab_strip"
    [ ( "tab strip"
      , [ Alcotest.test_case "a cut mark leads to the nearest hidden entry" `Quick
            test_a_cut_mark_leads_to_the_nearest_hidden_entry
        ; Alcotest.test_case "a cut strip presses nothing past its width" `Quick
            test_a_cut_strip_presses_nothing_past_its_width
        ;

        ] )
    ]
