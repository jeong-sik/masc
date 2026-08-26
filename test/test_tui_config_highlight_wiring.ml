(* Config draws the runtime file through the same lexer the Code surface uses.
   The state type holds coloured segments, so a loader that goes back to plain
   text stops compiling -- that half the compiler holds.

   This is the half it does not. [render_config] could concatenate the segment
   texts and drop the kinds; that still typechecks and the screen quietly goes
   back to grey. So the call is asserted here, at the binding that draws. *)

let render_config = "bin/masc_tui_render.ml"

(* Counted as an identifier rather than a call: the painter reaches the segments
   through [List.map lexed_span], so it is passed rather than applied and a
   call count sees nothing. *)
let test_the_config_surface_paints_its_segments () =
  let mentions =
    Ast_grep.count_identifiers_outside_calls_in_value_binding
      ~module_path:render_config ~binding_name:"render_config" ~callees:[]
      ~identifiers:[ "lexed_span" ]
  in
  Alcotest.(check bool)
    "render_config hands each segment to lexed_span" true (mentions > 0)

(* The painter moved out of the Code surface when Config started drawing the
   same rows. One table, or the two surfaces answer differently the first time
   either gains a kind. *)
let test_one_painter_serves_both_surfaces () =
  let mentions =
    Ast_grep.count_identifiers_outside_calls_in_value_binding
      ~module_path:render_config ~binding_name:"render_code" ~callees:[]
      ~identifiers:[ "lexed_span" ]
  in
  Alcotest.(check bool) "the Code surface reads the same painter" true
    (mentions > 0)

let () =
  Alcotest.run "masc_tui_config_highlight_wiring"
    [ ( "wiring"
      , [ Alcotest.test_case "the config surface paints its segments" `Quick
            test_the_config_surface_paints_its_segments
        ; Alcotest.test_case "one painter serves both surfaces" `Quick
            test_one_painter_serves_both_surfaces
        ] )
    ]
