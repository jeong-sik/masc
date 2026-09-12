(* The Tools pane strip says which pane is open. The key that changes it is the
   footer's, which draws from the key table. The strip said it too, and said it
   in the other language the screen uses: "p:다음 탭" under a footer reading
   "p:section". One key, two labels, one screen. *)

open Masc_tui_types

let contains needle haystack =
  let n = String.length needle in
  let rec seek i =
    i + n <= String.length haystack
    && (String.equal (String.sub haystack i n) needle || seek (i + 1))
  in
  seek 0

let make_state () =
  create_state ~workspace:"" ~port:0 ~refresh_interval:0. ()

let test_the_strip_names_panes_and_leaves_the_key_to_the_footer () =
  let strip = Masc_tui_render_tools.tools_pane_strip (make_state ()) in
  List.iter
    (fun pane ->
      Alcotest.(check bool)
        (Printf.sprintf "the strip names the %s pane" pane)
        true (contains pane strip))
    [ "호출 범위"; "비동기 작업"; "Skill 기록"; "사용 집계"; "전체 도구" ];
  Alcotest.(check bool) "and advertises no key of its own" false
    (contains "p:" strip);
  Alcotest.(check bool) "which the footer does instead" true
    (contains "p:section" (Masc_tui_keys.footer_hints Tools))

let () =
  Alcotest.run "masc_tui_render_tools"
    [ ( "pane strip"
      , [ Alcotest.test_case "panes here, the key in the footer" `Quick
            test_the_strip_names_panes_and_leaves_the_key_to_the_footer
        ] )
    ]
