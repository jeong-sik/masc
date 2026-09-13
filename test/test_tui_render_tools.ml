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
  let strip = Masc_tui_render_tools.tools_pane_strip ~cols:120 (make_state ()) in
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

(* The strip is the shared in-screen drawing: the open pane marked, two cells
   between names. It kept a bar between them after every other strip dropped
   it. *)
let test_the_strip_is_the_shared_drawing () =
  Alcotest.(check string) "the open pane marked, two cells apart"
    "\xe2\x96\xb8호출 범위  비동기 작업  Skill 기록  Skill 사용 집계  전체 도구"
    (Masc_tui_theme.strip_sgr
       (Masc_tui_render_tools.tools_pane_strip ~cols:120 (make_state ())))

(* The Keeper surface line says which of the two missing readings it is. It
   said "not loaded" under a failed inventory read. *)
let test_the_surface_line_tells_a_failed_read_from_an_unread_one () =
  let surface_line state =
    Masc_tui_render_tools.tools_display_lines state
    |> List.map snd
    |> List.find_opt (contains "Effective Keeper Surface")
    |> Option.value ~default:""
  in
  let unread = make_state () in
  Alcotest.(check string) "unread" " Effective Keeper Surface (not loaded)"
    (surface_line unread);
  let failed = make_state () in
  failed.tools_error <- Some "tool inventory load failed: HTTP 503";
  Alcotest.(check string) "failed" " Effective Keeper Surface (load failed)"
    (surface_line failed)

let () =
  Alcotest.run "masc_tui_render_tools"
    [ ( "pane strip"
      , [ Alcotest.test_case "panes here, the key in the footer" `Quick
            test_the_strip_names_panes_and_leaves_the_key_to_the_footer
        ; Alcotest.test_case "the surface line tells failed from unread" `Quick
            test_the_surface_line_tells_a_failed_read_from_an_unread_one
        ; Alcotest.test_case "the shared strip drawing" `Quick
            test_the_strip_is_the_shared_drawing
        ] )
    ]
