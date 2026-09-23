(* The reason a Keeper gives for its question is a block, not a line.

   [Terminal_text.single_line] escapes every control byte, and a newline is
   one: run over a body whole it prints "\x0A" at each break and returns one
   unbroken paragraph. Two of the three questions the live fleet was holding
   carried newlines in their context -- eleven in one -- so the pane drew the
   Keeper's own paragraph breaks into the middle of its sentences. *)

open Alcotest
module Prim = Masc_tui_render_prim
module Decode = Masc.Tui_decode

let row context : Decode.ask_row =
  { ar_keeper = "asker"
  ; ar_id = "ask-1"
  ; ar_asked_at = 1.0
  ; ar_context = Some context
  ; ar_questions = []
  ; ar_resolution = Decode.Ask_open
  }

let drawn context =
  let buf = Buffer.create 256 in
  Prim.draw_ask_context buf 120 ~row:(row context);
  Buffer.contents buf

let contains needle text = String_util.contains_substring text needle

let test_a_break_stays_a_break () =
  let text = drawn "first paragraph\n\nsecond paragraph" in
  check bool "no break is spelled into the sentence" false
    (contains "\\x0A" text);
  check bool "the first paragraph is there" true (contains "first paragraph" text);
  check bool "and so is the second" true (contains "second paragraph" text);
  (* Three source lines, so at least three drawn ones: the blank between the
     paragraphs is a line the reader can see. *)
  check bool "the block is taller than one line" true
    (List.length (String.split_on_char '\n' (String.trim text)) >= 3)

(* Per line, the escape still covers what it is for: a context that carries an
   escape byte cannot reach the terminal as a sequence. *)
let test_an_escape_byte_is_still_escaped () =
  let text = drawn "before\n\027[31mred\027[0m\nafter" in
  check bool "no raw escape reaches the buffer" false (contains "\027[31m" text);
  check bool "it is drawn as text" true (contains "\\x1B" text);
  check bool "the lines around it survive" true
    (contains "before" text && contains "after" text)

(* The questions are the ask and the reason explains it, so the reason is what
   the layout drops first. It dropped without a word: hidden questions are
   counted on a line of their own, folded asks are too, and only this one left
   no trace. *)
let test_a_dropped_reason_says_so () =
  check int "the surface says the reason did not fit" 1
    (Ast_grep.count_exact_string_literals_in_value_binding
       ~module_path:"bin/masc_tui_render.ml" ~binding_name:"draw_ask_questions"
       ~needle:"    %sthe reason did not fit -- a opens it%s")

let () =
  run "tui_ask_context_block"
    [ ( "context"
      , [ test_case "a break stays a break" `Quick test_a_break_stays_a_break
        ; test_case "an escape byte is still escaped" `Quick
            test_an_escape_byte_is_still_escaped
        ; test_case "a dropped reason says so" `Quick test_a_dropped_reason_says_so
        ] )
    ]
