open Alcotest
module D = Masc_tui_input_decoder

let feed_all decoder text =
  List.concat_map (D.feed decoder) (List.init (String.length text) (String.get text))

let decode text = feed_all (D.create ()) text

let show_reply = function
  | D.Palette (_, Some _) -> "palette"
  | D.Palette (_, None) -> "palette-unparsed"
  | D.Theme_mode Masc_tui_terminal_palette.Dark -> "theme-dark"
  | D.Theme_mode Masc_tui_terminal_palette.Light -> "theme-light"
  | D.Cell_pixels (width, height) -> Printf.sprintf "cell %dx%d" width height
  | D.Graphics body -> "graphics " ^ body

let show = function
  | D.Key name -> "key " ^ name
  | D.Paste { Masc_tui_paste.text; dropped } ->
      Printf.sprintf "paste %S dropped=%d" text dropped
  | D.Mouse_wheel (Masc.Tui_decode.Wheel_up, row, column) ->
      Printf.sprintf "wheel-up %d,%d" row column
  | D.Mouse_wheel (Masc.Tui_decode.Wheel_down, row, column) ->
      Printf.sprintf "wheel-down %d,%d" row column
  | D.Mouse_left_press (row, column) -> Printf.sprintf "press %d,%d" row column
  | D.Mouse_left_release (row, column) ->
      Printf.sprintf "release %d,%d" row column
  | D.Reply reply -> "reply " ^ show_reply reply

let events = list string
let check_events label expected actual = check events label expected (List.map show actual)

let show_pending = function
  | None -> "none"
  | Some D.Prefix -> "prefix"
  | Some D.Sequence -> "sequence"
  | Some D.Character -> "character"
  | Some D.Pasting -> "pasting"
  | Some D.Draining -> "draining"

let csi_name parameters final =
  match Masc_tui_csi.name ~parameters ~final with
  | Some name -> "key " ^ name
  | None -> "key unknown-esc"

let test_plain_keys () =
  check_events "ASCII and a Hangul syllable" [ "key a"; "key 한" ] (decode "a한")

let test_split_character_waits () =
  let decoder = D.create () in
  let hangul = "한" in
  check_events "head alone emits nothing" [] (feed_all decoder (String.sub hangul 0 1));
  check_events "a quiet read does not drop it" [] (D.idle decoder);
  check string "held as a character" "character" (show_pending (D.pending decoder));
  check_events "the tail finishes it" [ "key 한" ]
    (feed_all decoder (String.sub hangul 1 2))

let test_malformed_character_keeps_next_byte () =
  check_events "the rejecting byte is read as itself" [ "key invalid-utf8"; "key a" ]
    (decode "\xeda")

let test_lone_escape_resolves_on_idle () =
  let decoder = D.create () in
  check_events "ESC waits" [] (D.feed decoder '\x1b');
  check_events "a quiet read makes it the key" [ "key esc" ] (D.idle decoder);
  check string "nothing held" "none" (show_pending (D.pending decoder))

let test_alt_backspace () =
  check_events "ESC DEL" [ "key alt-backspace" ] (decode "\x1b\x7f")

let test_csi_keys_use_the_key_table () =
  check_events "arrow and PageDown" [ csi_name "" 'A'; csi_name "6" '~' ]
    (decode "\x1b[A\x1b[6~")

let test_ss3_arrow () =
  check_events "ESC O A is the same arrow" [ csi_name "" 'A' ] (decode "\x1bOA")

let test_csi_waits_across_idle () =
  let decoder = D.create () in
  check_events "head" [] (feed_all decoder "\x1b[20");
  check_events "quiet read holds it" [] (D.idle decoder);
  check string "held as a sequence" "sequence" (show_pending (D.pending decoder));
  check_events "the rest becomes a paste, not text" [ "paste \"hi\" dropped=0" ]
    (feed_all decoder "0~hi\x1b[201~")

let test_paste_keeps_reply_looking_bytes () =
  let inside = "a\x1b]10;rgb:12/ab/00\x07\x1b[?997;1n" in
  check_events "reply-shaped bytes inside a paste are text"
    [ Printf.sprintf "paste %S dropped=0" inside ]
    (decode ("\x1b[200~" ^ inside ^ "\x1b[201~"))

let test_paste_normalizes_line_breaks () =
  check_events "CRLF becomes one LF" [ "paste \"a\\nb\" dropped=0" ]
    (decode "\x1b[200~a\r\nb\x1b[201~")

let test_replies () =
  let theme =
    match Masc_tui_terminal_palette.parse_theme_mode_parameters "?997;1" with
    | Some Masc_tui_terminal_palette.Dark -> "reply theme-dark"
    | Some Masc_tui_terminal_palette.Light -> "reply theme-light"
    | None -> fail "fixture: ?997;1 must parse"
  in
  check_events "OSC BEL, OSC ST, theme, cell size, graphics"
    [ "reply palette"; "reply palette"; theme; "reply cell 15x34";
      "reply graphics i=31;OK" ]
    (decode
       ("\x1b]10;rgb:12/ab/00\x07" ^ "\x1b]11;rgb:ffff/8080/0000\x1b\\"
      ^ "\x1b[?997;1n" ^ "\x1b[6;34;15t" ^ "\x1b_Gi=31;OK\x1b\\"))

let test_not_a_reply_is_a_key () =
  check_events "wrong report code falls to the key table" [ csi_name "8;34;15" 't' ]
    (decode "\x1b[8;34;15t")

let test_unasked_osc_is_swallowed () =
  check_events "an OSC that is not a palette answer types nothing" [ "key x" ]
    (decode "\x1b]52;c;aGk=\x07x")

let test_oversized_graphics_reply_is_dropped () =
  let body = "G" ^ String.make 5000 'a' in
  check_events "no truncated answer, and the stream continues" [ "key x" ]
    (decode ("\x1b_" ^ body ^ "\x1b\\x"))

let test_split_graphics_reply_within_a_burst () =
  let decoder = D.create () in
  check_events "head" [] (feed_all decoder "\x1b_Gi=31;");
  check string "held as a prefix" "prefix" (show_pending (D.pending decoder));
  check_events "the rest of the burst closes it" [ "reply graphics i=31;OK" ]
    (feed_all decoder "OK\x1b\\")

let test_body_with_a_gap_is_dropped () =
  let decoder = D.create () in
  ignore (feed_all decoder "\x1b]10;rgb:12");
  check_events "a quiet read drops the body" [] (D.idle decoder);
  check_events "later typing is keys" [ "key h"; "key i" ] (feed_all decoder "hi")

let test_alt_bracket_is_escape_then_keys () =
  let decoder = D.create () in
  ignore (feed_all decoder "\x1b]");
  check_events "Alt+] with nothing after it" [ "key esc" ] (D.idle decoder);
  check_events "typing continues" [ "key h" ] (D.feed decoder 'h')

let test_sgr_mouse () =
  check_events "wheel, press, release"
    [ "wheel-up 5,10"; "press 3,4"; "release 3,4" ]
    (decode "\x1b[<64;10;5M\x1b[<0;4;3M\x1b[<0;4;3m")

(* The same events SGR gives, with the position the three bytes carry: "*"
   and "%" are column 10 and row 5 offset by 32. *)
let test_x10_mouse () =
  let wheel_up_button = Char.chr (64 + 32) and left_button = Char.chr 32
  and release_button = Char.chr (3 + 32) in
  check_events "three raw bytes after CSI M"
    [ "wheel-up 5,10"; "press 5,10"; "release 5,10"; "key x" ]
    (decode
       (Printf.sprintf "\x1b[M%c*%%\x1b[M%c*%%\x1b[M%c*%%x" wheel_up_button
          left_button release_button))

let test_x10_mouse_short_on_idle () =
  let decoder = D.create () in
  check_events "report head" [] (feed_all decoder "\x1b[M");
  check_events "no button byte" [ "key unknown-esc" ] (D.idle decoder);
  (* A wheel button with no position is not acted on: where it happened is
     what decides whether it scrolls a pane or the surface. *)
  check_events "button byte only" [] (feed_all decoder "\x1b[M`");
  check_events "no column" [ "key unknown-esc" ] (D.idle decoder);
  check_events "button and column" [] (feed_all decoder "\x1b[M`*");
  check_events "no row" [ "key unknown-esc" ] (D.idle decoder)

(* X10 has one release code for every button. A right click is not the left
   button's release, and a right click made while the left button is held
   leaves that press open for its own release. *)
let test_x10_release_ends_the_press_made_last () =
  let report button = Printf.sprintf "\x1b[M%c*%%" (Char.chr (32 + button)) in
  let left = 0 and right = 2 and release = 3 in
  check_events "a right click releases nothing"
    [ "key unknown-esc"; "key unknown-esc" ]
    (decode (report right ^ report release));
  check_events "left held across a right click"
    [ "press 5,10"; "key unknown-esc"; "key unknown-esc"; "release 5,10" ]
    (decode (report left ^ report right ^ report release ^ report release))

let test_csi_overflow_is_escape () =
  check_events "parameters past the bound" [ "key esc"; "key x" ]
    (decode ("\x1b[" ^ String.make 17 '1' ^ "x"))

let test_cancel_drops_a_held_sequence () =
  let decoder = D.create () in
  ignore (feed_all decoder "\x1b[200");
  D.cancel_pending decoder;
  check string "nothing held" "none" (show_pending (D.pending decoder));
  check_events "the next byte is a plain key" [ "key ~" ] (D.feed decoder '~')

let test_cancel_leaves_a_paste () =
  let decoder = D.create () in
  ignore (feed_all decoder "\x1b[200~ab");
  D.cancel_pending decoder;
  check string "still pasting" "pasting" (show_pending (D.pending decoder))

let test_recover_paste_drains_the_tail () =
  let decoder = D.create () in
  ignore (feed_all decoder "\x1b[200~draft");
  (match D.recover_paste decoder with
   | Some { Masc_tui_paste.text; _ } -> check string "what arrived so far" "draft" text
   | None -> fail "expected a recovered paste");
  check string "draining" "draining" (show_pending (D.pending decoder));
  check_events "the tail is dropped up to the end marker" [ "key x" ]
    (feed_all decoder "tail\x1b[201~x")

let test_abandon_draining_reads_input_again () =
  let decoder = D.create () in
  ignore (feed_all decoder "\x1b[200~draft");
  ignore (D.recover_paste decoder);
  D.abandon_draining decoder;
  check string "nothing held" "none" (show_pending (D.pending decoder));
  check_events "the next byte is a key" [ "key x" ] (D.feed decoder 'x')

let test_recover_outside_a_paste () =
  check bool "nothing to recover" true (Option.is_none (D.recover_paste (D.create ())))

let () =
  run "tui_input_decoder"
    [ ( "keys",
        [ test_case "plain keys" `Quick test_plain_keys;
          test_case "split character waits" `Quick test_split_character_waits;
          test_case "malformed character keeps next byte" `Quick
            test_malformed_character_keeps_next_byte;
          test_case "lone escape on idle" `Quick test_lone_escape_resolves_on_idle;
          test_case "alt-backspace" `Quick test_alt_backspace;
          test_case "CSI keys" `Quick test_csi_keys_use_the_key_table;
          test_case "SS3 arrow" `Quick test_ss3_arrow;
          test_case "CSI overflow" `Quick test_csi_overflow_is_escape ] );
      ( "paste",
        [ test_case "CSI waits across idle" `Quick test_csi_waits_across_idle;
          test_case "reply-looking bytes stay text" `Quick
            test_paste_keeps_reply_looking_bytes;
          test_case "line breaks" `Quick test_paste_normalizes_line_breaks;
          test_case "cancel leaves a paste" `Quick test_cancel_leaves_a_paste;
          test_case "recover drains the tail" `Quick test_recover_paste_drains_the_tail;
          test_case "abandon draining" `Quick test_abandon_draining_reads_input_again;
          test_case "recover outside a paste" `Quick test_recover_outside_a_paste ] );
      ( "replies",
        [ test_case "replies" `Quick test_replies;
          test_case "not a reply is a key" `Quick test_not_a_reply_is_a_key;
          test_case "unasked OSC" `Quick test_unasked_osc_is_swallowed;
          test_case "oversized graphics reply" `Quick
            test_oversized_graphics_reply_is_dropped;
          test_case "split graphics reply within a burst" `Quick
            test_split_graphics_reply_within_a_burst;
          test_case "body with a gap is dropped" `Quick test_body_with_a_gap_is_dropped;
          test_case "Alt+] is escape then keys" `Quick
            test_alt_bracket_is_escape_then_keys ] );
      ( "mouse",
        [ test_case "SGR" `Quick test_sgr_mouse;
          test_case "X10" `Quick test_x10_mouse;
          test_case "X10 short on idle" `Quick test_x10_mouse_short_on_idle;
          test_case "X10 release ends the press made last" `Quick
            test_x10_release_ends_the_press_made_last ] );
      ( "cancel",
        [ test_case "drops a held sequence" `Quick test_cancel_drops_a_held_sequence ] )
    ]
