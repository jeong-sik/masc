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

(* Below the micro-floor (6 cells) the strip draws nothing so 1-2 char
   stubs never steal cells from the clock beside it. Between 6 cells and
   [tab_strip_min_width], staged degradation preserves the active tab
   within [width]. *)
let test_a_strip_under_its_compact_floor_draws_nothing () =
  let tabs =
    [ ("stack", true, "stack"); ("request", false, "request"); ("proof", false, "proof") ]
  in
  let registry = Masc_tui_hit.registry () in
  let drawn =
    Masc_tui_ansi.tab_strip ~width:5 ~press:(Masc_tui_hit.mark registry) tabs
  in
  Alcotest.(check string) "nothing is drawn under 6 cells" "" drawn;
  let _lines, zones = Masc_tui_hit.extract registry [ drawn ^ "  12:00:00" ] in
  Alcotest.(check int) "nothing is pressable under 6 cells" 0
    (List.length (Masc_tui_hit.to_list zones));
  let narrow = Masc_tui_ansi.tab_strip_min_width tabs - 1 in
  let narrow_registry = Masc_tui_hit.registry () in
  let degraded_drawn =
    Masc_tui_ansi.tab_strip ~width:narrow
      ~press:(Masc_tui_hit.mark narrow_registry) tabs
  in
  let degraded_lines, narrow_zones =
    Masc_tui_hit.extract narrow_registry [ degraded_drawn ]
  in
  let degraded =
    Masc_tui_theme.strip_sgr (String.concat "" degraded_lines)
  in
  Alcotest.(check bool) "preserves active tab under full min_width" true
    (cells degraded > 0 && cells degraded <= narrow);
  Alcotest.(check (list string))
    "compact window registers only its drawn entries"
    [ "stack"; "request" ]
    (List.map (fun (_, _, _, target) -> target)
       (Masc_tui_hit.to_list narrow_zones));
  let floor_registry = Masc_tui_hit.registry () in
  let floor_drawn =
    Masc_tui_ansi.tab_strip ~width:6
      ~press:(Masc_tui_hit.mark floor_registry) tabs
  in
  let _floor_lines, floor_zones =
    Masc_tui_hit.extract floor_registry [ floor_drawn ]
  in
  Alcotest.(check (list string))
    "compact floor registers only the active tab without leaking cut marks"
    [ "stack" ]
    (List.map (fun (_, _, _, target) -> target)
       (Masc_tui_hit.to_list floor_zones))

(* At every width the strip never exceeds [width]: whole when that fits,
   windowed with full current label at or above [tab_strip_min_width],
   staged compact active tab down to 6 cells, and absent below 6 cells. *)
let test_a_strip_degrades_cleanly_at_every_width () =
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
        Alcotest.(check bool) (at ^ ": within the width") true (cells drawn <= width);
        if width >= cells whole then Alcotest.(check string) (at ^ ": whole") whole drawn
        else if width >= minimum then
          Alcotest.(check bool) (at ^ ": the current label is whole") true
            (Astring.String.is_infix ~affix:current_label drawn)
        else if width >= 6 then
          Alcotest.(check bool) (at ^ ": keeps active tab orientation") true
            (cells drawn > 0)
        else Alcotest.(check string) (at ^ ": nothing below 6 cells") "" drawn
      done)
    labels

let () =
  Alcotest.run "tui_tab_strip"
    [ ( "tab strip"
      , [ Alcotest.test_case "a cut mark leads to the nearest hidden entry" `Quick
            test_a_cut_mark_leads_to_the_nearest_hidden_entry
        ; Alcotest.test_case "a strip under its compact floor draws nothing" `Quick
            test_a_strip_under_its_compact_floor_draws_nothing
        ; Alcotest.test_case
            "a strip degrades cleanly across every width" `Quick
            test_a_strip_degrades_cleanly_at_every_width
        ] )
    ]
