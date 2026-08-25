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

let () =
  run "tui_terminal_palette"
    [ ( "classifier"
      , [ test_case "precedence and conservative fallbacks" `Quick
            test_classifier_precedence
        ; test_case "stdout level is cached once" `Quick
            test_stdout_level_is_one_process_lazy
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
