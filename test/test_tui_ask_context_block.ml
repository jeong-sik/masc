(* The reason a Keeper gives for its question is a block, not a line.

   [Terminal_text.single_line] escapes every control byte, and a newline is
   one: run over a body whole it prints "\x0A" at each break and returns one
   unbroken paragraph. Two of the three questions the live fleet was holding
   carried newlines in their context -- eleven in one -- so the pane drew the
   Keeper's own paragraph breaks into the middle of its sentences. *)

open Alcotest
module Prim = Masc_tui_render_prim

let row context : Masc.Tui_decode_asks.ask_row =
  { ar_keeper = "asker"
  ; ar_id = "ask-1"
  ; ar_asked_at = 1.0
  ; ar_context = Some context
  ; ar_questions = []
  ; ar_resolution = Masc.Tui_decode_asks.Ask_open
  }

let drawn context =
  let buf = Buffer.create 256 in
  Prim.draw_ask_context buf 120 ~row:(row context);
  Buffer.contents buf

let contains needle text = String_util.contains_substring text needle

let test_an_escape_byte_is_still_escaped () =
  let text = drawn "before\n\027[31mred\027[0m\nafter" in
  check bool "no raw escape reaches the buffer" false (contains "\027[31m" text);
  check bool "it is drawn as text" true (contains "\\x1B" text);
  check bool "the lines around it survive" true
    (contains "before" text && contains "after" text)

let () =
  run "tui_ask_context_block"
    [ ( "context"
      , [ test_case "an escape byte is still escaped" `Quick
            test_an_escape_byte_is_still_escaped

        ] )
    ]
