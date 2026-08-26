open Alcotest

module Palette = Masc_tui_terminal_palette
module Testing = Palette.For_testing

let color_level =
  let print formatter = function
    | Palette.True_color -> Format.pp_print_string formatter "True_color"
    | Palette.Ansi256 -> Format.pp_print_string formatter "Ansi256"
    | Palette.Ansi16 -> Format.pp_print_string formatter "Ansi16"
    | Palette.Unknown -> Format.pp_print_string formatter "Unknown"
  in
  testable print ( = )
;;

let input ?(is_tty = true) ?(term = Some "xterm") ?(colorterm = None)
    ?(terminfo_rgb = None) ?(terminfo_colors = None) ()
    : Testing.classifier_input
  =
  { is_tty; term; colorterm; terminfo_rgb; terminfo_colors }
;;

let test_classifier_precedence () =
  let cases =
    [ ( "non-TTY wins over every positive signal"
      , input ~is_tty:false ~colorterm:(Some "truecolor")
          ~terminfo_rgb:(Some true) ~terminfo_colors:(Some 256) ()
      , Palette.Unknown )
    ; ( "missing TERM"
      , input ~term:None ~terminfo_rgb:(Some true) ()
      , Palette.Unknown )
    ; "empty TERM", input ~term:(Some "") ~terminfo_colors:(Some 256) (), Palette.Unknown
    ; ( "dumb TERM"
      , input ~term:(Some "DuMb") ~colorterm:(Some "truecolor") ()
      , Palette.Unknown )
    ; ( "native RGB with 24-bit colour count"
      , input ~terminfo_rgb:(Some true) ~terminfo_colors:(Some 16_777_216) ()
      , Palette.True_color )
    ; ( "RGB#1 normalized to presence cannot prove truecolor"
      , input ~terminfo_rgb:(Some true) ()
      , Palette.Unknown )
    ; ( "boolean RGB with 256 colours remains ANSI-256"
      , input ~terminfo_rgb:(Some true) ~terminfo_colors:(Some 256) ()
      , Palette.Ansi256 )
    ; ( "RGB below the 16m boundary remains ANSI-256"
      , input ~terminfo_rgb:(Some true)
          ~terminfo_colors:(Some 16_777_215) ()
      , Palette.Ansi256 )
    ; ( "16m colours without RGB presence remain ANSI-256"
      , input ~terminfo_colors:(Some 16_777_216) ()
      , Palette.Ansi256 )
    ; ( "COLORTERM exact, case-insensitive"
      , input ~colorterm:(Some "TrUeCoLoR") ()
      , Palette.True_color )
    ; ( "COLORTERM does not accept a suffix"
      , input ~colorterm:(Some "truecolor-24bit")
          ~terminfo_colors:(Some 256) ()
      , Palette.Ansi256 )
    ; "256 native colours", input ~terminfo_colors:(Some 256) (), Palette.Ansi256
    ; "255 native colours", input ~terminfo_colors:(Some 255) (), Palette.Ansi16
    ; "16 native colours", input ~terminfo_colors:(Some 16) (), Palette.Ansi16
    ; "15 native colours", input ~terminfo_colors:(Some 15) (), Palette.Unknown
    ; ( "TERM suffix is not capability evidence"
      , input ~term:(Some "xterm-256color") ()
      , Palette.Unknown )
    ; "terminfo failure", input (), Palette.Unknown
    ]
  in
  List.iter
    (fun (name, classifier_input, expected) ->
      check color_level name expected (Testing.classify classifier_input))
    cases
;;

let test_stdout_level_is_one_process_lazy () =
  let first = Palette.stdout_color_level () in
  let second = Palette.stdout_color_level () in
  check color_level "same cached process fact" first second;
  let target = Palette.make_rgb ~red:12 ~green:34 ~blue:56 in
  check bool "best_color reads the same owner" true
    (Palette.best_color target
     = Testing.best_color_for_level ~level:first target)
;;

let projected_view = function
  | None -> `None
  | Some projected ->
    Palette.fold_projected_color
      ~rgb:(fun color ->
        `Rgb (Palette.red color, Palette.green color, Palette.blue color))
      ~indexed:(fun index -> `Indexed index)
      projected
;;

let test_truecolor_projection_preserves_rgb () =
  let target = Palette.make_rgb ~red:12 ~green:34 ~blue:56 in
  check bool "RGB unchanged" true
    (projected_view
       (Testing.best_color_for_level ~level:Palette.True_color target)
     = `Rgb (12, 34, 56))
;;

let indexed target =
  match projected_view (Testing.best_color_for_level ~level:Palette.Ansi256 target) with
  | `Indexed index -> index
  | `Rgb _ -> fail "ANSI-256 projection remained RGB"
  | `None -> fail "ANSI-256 projection disappeared"
;;

let test_ansi256_projection_uses_only_fixed_entries () =
  let rgb red green blue = Palette.make_rgb ~red ~green ~blue in
  check int "fixed black, not terminal-defined slot 0" 16 (indexed (rgb 0 0 0));
  check int "exact cube entry" 52 (indexed (rgb 95 0 0));
  check int "nearest grayscale entry" 241 (indexed (rgb 100 100 100));
  check int "distance tie chooses the lower fixed index" 16 (indexed (rgb 4 4 4));
  List.iter
    (fun target ->
      let index = indexed target in
      check bool "index remains in 16..255" true (index >= 16 && index <= 255))
    [ rgb 1 2 3; rgb 127 84 201; rgb 255 255 255 ]
;;

let test_unsupported_levels_do_not_invent_a_background () =
  let target = Palette.make_rgb ~red:12 ~green:34 ~blue:56 in
  List.iter
    (fun level ->
      check bool "no projection" true
        (projected_view (Testing.best_color_for_level ~level target) = `None))
    [ Palette.Ansi16; Palette.Unknown ]
;;


(* Stdlib has no substring search. Small enough to write than to reach for. *)
let contains haystack needle =
  let hay = String.length haystack and pin = String.length needle in
  let rec scan offset =
    if offset + pin > hay then false
    else if String.equal (String.sub haystack offset pin) needle then true
    else scan (offset + 1)
  in
  scan 0
;;

(* The query has to actually ask, and the answers have to be understood.
   OSC 10 and 11 name the text and the page; OSC 4 names each of the sixteen
   entries an SGR colour code selects, which is the only way to know what a
   code will draw on this terminal rather than on the one it was picked
   against. *)
let test_the_query_asks_for_the_page_and_every_slot () =
  check bool "asks for the foreground" true
    (contains Palette.query "\x1b]10;?");
  check bool "asks for the background" true
    (contains Palette.query "\x1b]11;?");
  for index = 0 to Palette.ansi_slot_count - 1 do
    check bool
      (Printf.sprintf "asks for palette entry %d" index)
      true
      (contains Palette.query
         (Printf.sprintf "\x1b]4;%d;?" index))
  done
;;

let slot_of body =
  match Palette.parse_response body with
  | Palette.Palette_response { slot; color } -> Some (slot, color)
  | Palette.Not_palette_response -> None
;;

let test_a_slot_answer_is_read_back_to_its_own_index () =
  (match slot_of "4;3;rgb:f7f7/caca/8888" with
   | Some (Palette.Ansi 3, Some color) ->
     check int "red component" 0xf7 (Palette.red color);
     check int "green component" 0xca (Palette.green color);
     check int "blue component" 0x88 (Palette.blue color)
   | Some _ | None -> fail "expected palette entry 3");
  (* An answer for a slot outside the sixteen is not an answer to anything
     this asked, so it is passed through rather than stored somewhere. *)
  check bool "an index past the sixteen is not a palette answer" true
    (slot_of "4;200;rgb:0000/0000/0000" = None);
  check bool "a malformed index is not a palette answer" true
    (slot_of "4;x;rgb:0000/0000/0000" = None)
;;

(* Sixteen unknown entries are a terminal that answered the page and not the
   palette -- a multiplexer, or an emulator without OSC 4. It is still a
   palette: the background is what every reading is measured against. *)
let test_a_page_without_a_palette_is_still_a_palette () =
  let rgb red green blue = Palette.make_rgb ~red ~green ~blue in
  match
    Palette.of_responses ~foreground:(Some (rgb 200 200 200))
      ~background:(Some (rgb 20 20 20))
      ~ansi:(Array.make Palette.ansi_slot_count None)
  with
  | None -> fail "a foreground and a background are enough"
  | Some palette ->
    check int "background survives" 20 (Palette.red (Palette.background palette));
    check bool "every slot reads as unknown" true
      (List.for_all
         (fun index -> Palette.ansi palette index = None)
         (List.init Palette.ansi_slot_count Fun.id));
    check bool "an index past the sixteen is unknown, not an error" true
      (Palette.ansi palette Palette.ansi_slot_count = None)
;;

let () =
  run "tui_terminal_palette"
    [ ( "classifier"
      , [ test_case "precedence and conservative fallbacks" `Quick
            test_classifier_precedence
        ; test_case "stdout level is cached once" `Quick
            test_stdout_level_is_one_process_lazy
        ] )
    ; ( "osc palette"
      , [ test_case "the query asks for the page and every slot" `Quick
            test_the_query_asks_for_the_page_and_every_slot
        ; test_case "a slot answer keeps its index" `Quick
            test_a_slot_answer_is_read_back_to_its_own_index
        ; test_case "a page without a palette is still a palette" `Quick
            test_a_page_without_a_palette_is_still_a_palette
        ] )
    ; ( "projection"
      , [ test_case "truecolor preserves RGB" `Quick
            test_truecolor_projection_preserves_rgb
        ; test_case "ANSI-256 uses fixed xterm entries" `Quick
            test_ansi256_projection_uses_only_fixed_entries
        ; test_case "ANSI-16 and unknown stay absent" `Quick
            test_unsupported_levels_do_not_invent_a_background
        ] )
    ]
;;
