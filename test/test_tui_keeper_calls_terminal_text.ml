(* A runtime roster name is external text. It must reach the terminal through
   the same control-byte escaping as the other Keeper surfaces. This checks
   that safety boundary, not the wording, placement, or order of screen rows. *)

open Alcotest
module Types = Masc_tui_types

let test_runtime_keeper_name_is_terminal_text () =
  let state = Types.create_state ~workspace:"" ~port:0 () in
  let rendered =
    Masc_tui_render_prim.keeper_calls_heading ~cols:120 state
      ~keeper_name:"alpha\n\027]0;owned\007" ~readings:[]
  in
  let rows = [ Masc_tui_theme.strip_sgr rendered ] in
  List.iter
    (fun row ->
      check bool "no roster control byte reaches a terminal row" false
        (String.exists (fun ch -> Char.code ch < 0x20 || Char.code ch = 0x7f) row))
    rows;
  List.iter
    (fun escaped ->
      check bool "the roster controls remain visible as escapes" true
        (List.exists (fun row -> String_util.contains_substring row escaped) rows))
    [ "\\x0A"; "\\x1B]0;owned"; "\\x07" ]

let () =
  run "tui_keeper_calls_terminal_text"
    [ ( "runtime roster"
      , [ test_case "the selected keeper name is escaped" `Quick
            test_runtime_keeper_name_is_terminal_text ] )
    ]
