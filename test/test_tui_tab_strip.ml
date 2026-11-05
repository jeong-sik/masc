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

(* A strip is whole or it is not drawn. Narrower than its current entry with
   the marks its position calls for, it cannot hold even that entry, and a
   strip cut to the width would end inside the name and name nothing. It draws
   nothing, so it presses nothing either and the clock drawn after it keeps
   its cells. *)
let test_a_strip_under_its_minimum_draws_nothing () =
  let tabs =
    [ ("stack", true, "stack"); ("request", false, "request"); ("proof", false, "proof") ]
  in
  let width = Masc_tui_ansi.tab_strip_min_width tabs - 1 in
  let registry = Masc_tui_hit.registry () in
  let drawn =
    Masc_tui_ansi.tab_strip ~width ~press:(Masc_tui_hit.mark registry) tabs
  in
  Alcotest.(check string) "nothing is drawn" "" drawn;
  let _lines, zones = Masc_tui_hit.extract registry [ drawn ^ "  12:00:00" ] in
  Alcotest.(check int) "nothing is pressable" 0
    (List.length (Masc_tui_hit.to_list zones))

(* At every width the strip is the whole strip when that fits, the window
   around the current entry when only that fits, and nothing below that. The
   window is no wider than the width and holds the current entry's label
   whole. The labels hold wide characters, so the cells are neither the bytes
   nor the characters. *)
let test_a_strip_is_whole_or_a_window_around_the_current_entry_or_absent () =
  let labels = [ "후보 순서"; "전체 런타임"; "기능 (11개)"; "클라이언트 (3개 연결)" ] in
  List.iteri
    (fun current current_label ->
      let tabs = List.mapi (fun index label -> (label, index = current)) labels in
      let whole = plain ~width:1000 tabs in
      let minimum =
        Masc_tui_ansi.tab_strip_min_width
          (List.map (fun (label, is_current) -> (label, is_current, ())) tabs)
      in
      for width = 0 to cells whole + 2 do
        let drawn = plain ~width tabs in
        let at = Printf.sprintf "%s at %d cells" current_label width in
        if width >= cells whole then Alcotest.(check string) (at ^ ": whole") whole drawn
        else if width >= minimum then begin
          Alcotest.(check bool) (at ^ ": within the width") true (cells drawn <= width);
          Alcotest.(check bool) (at ^ ": the current label is whole") true
            (Astring.String.is_infix ~affix:current_label drawn)
        end
        else Alcotest.(check string) (at ^ ": nothing") "" drawn
      done)
    labels

let () =
  Alcotest.run "tui_tab_strip"
    [ ( "tab strip"
      , [ Alcotest.test_case "a cut mark leads to the nearest hidden entry" `Quick
            test_a_cut_mark_leads_to_the_nearest_hidden_entry
        ; Alcotest.test_case "a strip under its minimum draws nothing" `Quick
            test_a_strip_under_its_minimum_draws_nothing
        ; Alcotest.test_case
            "a strip is whole, a window around the current entry, or absent" `Quick
            test_a_strip_is_whole_or_a_window_around_the_current_entry_or_absent
        ] )
    ]
