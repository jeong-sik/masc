(* Every colour masc names, measured against the backgrounds it is drawn on.

   masc picks its semantic colours out of the terminal's own sixteen ANSI
   slots, so what they actually draw is decided by the reader's theme and not
   by this repo. The tokens were chosen against a dark terminal. This is where
   the other themes get a say.

   The schemes are real, from tinted-theming/schemes, and the slot each SGR
   code selects is the mapping base16's own shell template installs -- so a
   number here is what a reader on that theme sees, not an invention. *)

let check = Alcotest.check
let bool = Alcotest.bool

module Color = Masc_tui_color
module Palette = Masc_tui_terminal_palette

type scheme =
  { name : string
  ; light : bool
  ; base : string array (* base00 .. base0F, sixteen hex bodies *)
  }

let schemes =
  [ { name = "default-dark"; light = false
    ; base = [| "181818"; "282828"; "383838"; "585858"; "b8b8b8"; "d8d8d8"
              ; "e8e8e8"; "f8f8f8"; "ab4642"; "dc9656"; "f7ca88"; "a1b56c"
              ; "86c1b9"; "7cafc2"; "ba8baf"; "a16946" |] }
  ; { name = "default-light"; light = true
    ; base = [| "f8f8f8"; "e8e8e8"; "d8d8d8"; "b8b8b8"; "585858"; "383838"
              ; "282828"; "181818"; "ab4642"; "dc9656"; "f7ca88"; "a1b56c"
              ; "86c1b9"; "7cafc2"; "ba8baf"; "a16946" |] }
  ; { name = "solarized-dark"; light = false
    ; base = [| "002b36"; "073642"; "586e75"; "657b83"; "839496"; "93a1a1"
              ; "eee8d5"; "fdf6e3"; "dc322f"; "cb4b16"; "b58900"; "859900"
              ; "2aa198"; "268bd2"; "6c71c4"; "d33682" |] }
  ; { name = "solarized-light"; light = true
    ; base = [| "fdf6e3"; "eee8d5"; "93a1a1"; "839496"; "657b83"; "586e75"
              ; "073642"; "002b36"; "dc322f"; "cb4b16"; "b58900"; "859900"
              ; "2aa198"; "268bd2"; "6c71c4"; "d33682" |] }
  ; { name = "gruvbox-dark-hard"; light = false
    ; base = [| "1d2021"; "3c3836"; "504945"; "665c54"; "bdae93"; "d5c4a1"
              ; "ebdbb2"; "fbf1c7"; "fb4934"; "fe8019"; "fabd2f"; "b8bb26"
              ; "8ec07c"; "83a598"; "d3869b"; "d65d0e" |] }
  ; { name = "nord"; light = false
    ; base = [| "2E3440"; "3B4252"; "434C5E"; "4C566A"; "D8DEE9"; "E5E9F0"
              ; "ECEFF4"; "8FBCBB"; "BF616A"; "D08770"; "EBCB8B"; "A3BE8C"
              ; "88C0D0"; "81A1C1"; "B48EAD"; "5E81AC" |] }
  ; { name = "dracula"; light = false
    ; base = [| "282a36"; "21222c"; "44475A"; "6272a4"; "9ea8c7"; "f8f8f2"
              ; "f8f8f2"; "ffffff"; "ff5555"; "FFB86C"; "f1fa8c"; "50fa7b"
              ; "8be9fd"; "bd93f9"; "ff79c6"; "993333" |] }
  ; { name = "onedark"; light = false
    ; base = [| "282c34"; "353b45"; "3e4451"; "545862"; "565c64"; "abb2bf"
              ; "b6bdca"; "c8ccd4"; "e06c75"; "d19a66"; "e5c07b"; "98c379"
              ; "56b6c2"; "61afef"; "c678dd"; "be5046" |] }
  ; { name = "tokyo-night-dark"; light = false
    ; base = [| "1A1B26"; "16161E"; "2F3549"; "444B6A"; "787C99"; "A9B1D6"
              ; "CBCCD1"; "D5D6DB"; "C0CAF5"; "A9B1D6"; "0DB9D7"; "9ECE6A"
              ; "B4F9F8"; "2AC3DE"; "BB9AF7"; "F7768E" |] }
  ; { name = "catppuccin-mocha"; light = false
    ; base = [| "1e1e2e"; "181825"; "313244"; "45475a"; "585b70"; "cdd6f4"
              ; "f5e0dc"; "b4befe"; "f38ba8"; "fab387"; "f9e2af"; "a6e3a1"
              ; "94e2d5"; "89b4fa"; "cba6f7"; "f2cdcd" |] }
  ; { name = "github"; light = true
    ; base = [| "ffffff"; "f6f8fa"; "afb8c1"; "8c959f"; "6e7781"; "424a53"
              ; "32383f"; "1f2328"; "953800"; "0550ae"; "bf8700"; "0a3069"
              ; "116329"; "8250df"; "cf222e"; "82071e" |] }
  ; { name = "monokai"; light = false
    ; base = [| "272822"; "383830"; "49483e"; "75715e"; "a59f85"; "f8f8f2"
              ; "f5f4f1"; "f9f8f5"; "f92672"; "fd971f"; "f4bf75"; "a6e22e"
              ; "a1efe4"; "66d9ef"; "ae81ff"; "cc6633" |] }
  ]
;;

let color_of_hex text =
  let component offset =
    int_of_string ("0x" ^ String.sub text offset 2)
  in
  Palette.make_rgb ~red:(component 0) ~green:(component 2) ~blue:(component 4)
;;

let base scheme index = color_of_hex scheme.base.(index)

(* tinted-shell's base16 template: which palette entry each ANSI colour is.
   Bright 9 through 14 repeat 1 through 6 under base16; base24 splits them. *)
let ansi_slot =
  [| 0x0; 0x8; 0xB; 0xA; 0xD; 0xE; 0xC; 0x5
   ; 0x3; 0x8; 0xB; 0xA; 0xD; 0xE; 0xC; 0x7 |]
;;

let ansi scheme index = base scheme ansi_slot.(index)
let background scheme = base scheme 0x0
let foreground scheme = base scheme 0x5

(* Every colour something draws a meaning through, state and role alike, and
   the one table both the reading tests and the lifting tests measure. The
   role ones matter as much as the state ones: the tool trail is the row an
   operator scans to see what a keeper just did. *)
let named_colours =
  [ "status Ok", Masc_tui_theme.Bright_green
  ; "status Warn", Masc_tui_theme.Bright_yellow
  ; "status Bad", Masc_tui_theme.Bright_red
  ; "status Info", Masc_tui_theme.Bright_cyan
  ; "chat User origin", Masc_tui_theme.Bright_cyan
  ; "chat Keeper origin", Masc_tui_theme.Bright_blue
  ; "chat Tool origin", Masc_tui_theme.Bright_magenta
  ; "chat Thinking origin", Masc_tui_theme.Bright_black
  ; "Syntax.keyword", Masc_tui_theme.Bright_magenta
  ; "Syntax.string_", Masc_tui_theme.Bright_green
  ]
;;

let named_tokens =
  List.map
    (fun (label, colour) ->
      label, Masc_tui_theme.For_testing.ansi_color_index colour)
    named_colours
;;

(* What a colour has to clear to be read as text. WCAG 2 AA for body text. *)
let text_floor = 4.5

let test_lifting_makes_every_token_readable_on_every_scheme () =
  List.iter
    (fun scheme ->
      let bg = background scheme in
      List.iter
        (fun (label, index) ->
          let lifted =
            Color.lift_for_contrast ~background:bg ~floor:text_floor
              (ansi scheme index)
          in
          let ratio = Color.contrast_ratio lifted bg in
          check bool
            (Printf.sprintf "%s: %s reads at %.2f" scheme.name label ratio)
            true
            (ratio >= text_floor -. 0.01))
        named_tokens)
    schemes
;;

(* The point of moving lightness rather than the colour itself. A lift that
   changed the hue would answer the contrast question by making red not red,
   which is worse than the problem: red is how the row says what it is. *)
let max_hue_drift_degrees = 8.0

(* Below this a colour is a grey, and the hue of a grey is the angle of
   nothing. Only chromatic colours are held to the drift bound. *)
let chromatic_floor = 0.02

(* Oklab, written here rather than reached for, so this measures the lift with
   arithmetic the lift does not share. A hue check that borrowed the lift's
   own hue function would agree with it by construction. *)
let oklab color =
  let channel value =
    let value = float_of_int value /. 255. in
    if value <= 0.04045 then value /. 12.92
    else ((value +. 0.055) /. 1.055) ** 2.4
  in
  let red = channel (Palette.red color)
  and green = channel (Palette.green color)
  and blue = channel (Palette.blue color) in
  let long =
    Float.cbrt
      ((0.4122214708 *. red) +. (0.5363325363 *. green) +. (0.0514459929 *. blue))
  and medium =
    Float.cbrt
      ((0.2119034982 *. red) +. (0.6806995451 *. green) +. (0.1073969566 *. blue))
  and short =
    Float.cbrt
      ((0.0883024619 *. red) +. (0.2817188376 *. green) +. (0.6299787005 *. blue))
  in
  ( (0.2104542553 *. long) +. (0.7936177850 *. medium)
    -. (0.0040720468 *. short)
  , (1.9779984951 *. long) -. (2.4285922050 *. medium) +. (0.4505937099 *. short)
  , (0.0259040371 *. long) +. (0.7827717662 *. medium) -. (0.8086757660 *. short)
  )
;;

let lightness color =
  let value, _, _ = oklab color in
  value
;;

let chroma color =
  let _, green_red, blue_yellow = oklab color in
  sqrt ((green_red *. green_red) +. (blue_yellow *. blue_yellow))
;;

let hue_drift first second =
  let degrees color =
    let _, green_red, blue_yellow = oklab color in
    let raw = atan2 blue_yellow green_red *. 180. /. Float.pi in
    if raw < 0. then raw +. 360. else raw
  in
  let raw = Float.abs (degrees first -. degrees second) in
  Float.min raw (360. -. raw)
;;

let test_lifting_keeps_the_colour_it_lifted () =
  List.iter
    (fun scheme ->
      let bg = background scheme in
      List.iter
        (fun (label, index) ->
          let original = ansi scheme index in
          let lifted =
            Color.lift_for_contrast ~background:bg ~floor:text_floor original
          in
          let drift = hue_drift lifted original in
          if chroma original > chromatic_floor then
            check bool
              (Printf.sprintf "%s: %s drifts %.1f degrees" scheme.name label
                 drift)
              true
              (drift <= max_hue_drift_degrees))
        named_tokens)
    schemes
;;

(* A colour the theme already made readable is the theme's call, not ours. *)
let test_a_colour_that_already_reads_is_left_alone () =
  List.iter
    (fun scheme ->
      let bg = background scheme in
      List.iter
        (fun (label, index) ->
          let original = ansi scheme index in
          if Color.contrast_ratio original bg >= text_floor then
            check bool
              (Printf.sprintf "%s: %s is untouched" scheme.name label)
              true
              (Color.lift_for_contrast ~background:bg ~floor:text_floor
                 original
               = original))
        named_tokens)
    schemes
;;

(* The receding token, against real themes rather than four hand-picked ones.
   It has the opposite errand and the same floor to respect. *)
let recede_floor = 3.0
let recede_max_ratio = 0.4

let test_receding_moves_toward_the_background_on_every_scheme () =
  List.iter
    (fun scheme ->
      let bg = background scheme in
      let fg = foreground scheme in
      match
        Color.recede_toward ~background:bg ~floor:recede_floor
          ~max_ratio:recede_max_ratio fg
      with
      | None ->
        (* Only a theme whose own text is already under the floor. None of
           these twelve is, so reaching here is the fixture drifting. *)
        Alcotest.failf "%s: the theme's own text does not clear %.1f"
          scheme.name recede_floor
      | Some receded ->
        let ratio = Color.contrast_ratio receded bg in
        check bool
          (Printf.sprintf "%s: receded text reads at %.2f" scheme.name ratio)
          true
          (ratio >= recede_floor -. 0.01);
        (* The direction SGR 2 gets wrong on a light terminal. *)
        let closer =
          Float.abs
            (lightness receded -. lightness bg)
          < Float.abs
              (lightness fg -. lightness bg)
        in
        check bool
          (Printf.sprintf "%s: receded text sits nearer the background"
             scheme.name)
          true closer)
    schemes
;;


(* End to end: build the palette the terminal would have reported for this
   scheme, hand it to the theme, and see what actually goes out on the wire.

   The capability and the colour flag are supplied rather than read, because
   a test whose answer depends on where it runs is a test that can pass by
   not running. *)
let palette_of scheme =
  Palette.of_responses
    ~foreground:(Some (foreground scheme))
    ~background:(Some (background scheme))
    ~ansi:(Array.init Palette.ansi_slot_count (fun index ->
               Some (ansi scheme index)))
;;

let readable scheme colour =
  Masc_tui_theme.For_testing.ansi_readable ~colors_enabled:true
    ~project:
      (Palette.For_testing.best_color_for_level
         ~level:Palette.True_color)
    (palette_of scheme) colour
;;


let truecolor_prefix = "\027[38;2;"

let test_a_failing_theme_entry_is_replaced_and_a_passing_one_is_not () =
  List.iter
    (fun scheme ->
      let bg = background scheme in
      List.iter
        (fun (label, colour) ->
          let entry =
            ansi scheme (Masc_tui_theme.For_testing.ansi_color_index colour)
          in
          let ratio = Color.contrast_ratio entry bg in
          let drawn = readable scheme colour in
          if ratio >= text_floor then
            check bool
              (Printf.sprintf "%s: %s reads at %.2f and keeps the theme's own"
                 scheme.name label ratio)
              true
              (String.equal drawn (Masc_tui_theme.For_testing.ansi_color_code colour))
          else
            check bool
              (Printf.sprintf "%s: %s only reads at %.2f and is replaced"
                 scheme.name label ratio)
              true
              (String.starts_with ~prefix:truecolor_prefix drawn))
        named_colours)
    schemes
;;

(* A terminal that answered OSC 10 and 11 but not OSC 4 knows its page and not
   its palette, which is most multiplexers. Nothing is lifted there, because
   there is nothing to measure. *)
let test_an_unanswered_palette_changes_nothing () =
  List.iter
    (fun scheme ->
      let without_ansi =
        Palette.of_responses
          ~foreground:(Some (foreground scheme))
          ~background:(Some (background scheme))
          ~ansi:(Array.make Palette.ansi_slot_count None)
      in
      List.iter
        (fun (label, colour) ->
          check bool
            (Printf.sprintf "%s: %s keeps its plain code" scheme.name label)
            true
            (String.equal
               (Masc_tui_theme.For_testing.ansi_readable ~colors_enabled:true
                  ~project:
                    (Palette.For_testing.best_color_for_level
                       ~level:Palette.True_color)
                  without_ansi colour)
               (Masc_tui_theme.For_testing.ansi_color_code colour)))
        named_colours)
    schemes
;;


(* The keeper list draws what is about to happen to a keeper in colour alone.
   The cell's other three readings are carried by a glyph, a word and a column
   of their own, and a distinct glyph per action was tried and rejected -- four
   shapes is what keeps the column legible. So the four colours are the whole
   signal, and they have to stay apart for a reader who cannot separate red
   from green: roughly one man in twelve.

   Machado et al. 2009, severity 1.0, the matrices every colour-vision
   simulator uses. Written here rather than reached for, like the hue check
   above: an independent computation, not the renderer checking itself. *)
let simulate_deficiency kind color =
  let matrix =
    match kind with
    | `Deuteranopia ->
      [| [| 0.367322; 0.860646; -0.227968 |]
       ; [| 0.280085; 0.672501; 0.047413 |]
       ; [| -0.011820; 0.042940; 0.968881 |]
      |]
    | `Protanopia ->
      [| [| 0.152286; 1.052583; -0.204868 |]
       ; [| 0.114503; 0.786281; 0.099216 |]
       ; [| -0.003882; -0.048116; 1.051998 |]
      |]
  in
  let linear value =
    let value = float_of_int value /. 255. in
    if value <= 0.04045 then value /. 12.92
    else ((value +. 0.055) /. 1.055) ** 2.4
  in
  let encode value =
    let value = Float.max 0. (Float.min 1. value) in
    let value =
      if value <= 0.0031308 then 12.92 *. value
      else (1.055 *. (value ** (1. /. 2.4))) -. 0.055
    in
    int_of_float (Float.round (Float.max 0. (Float.min 1. value) *. 255.))
  in
  let red = linear (Palette.red color)
  and green = linear (Palette.green color)
  and blue = linear (Palette.blue color) in
  let channel row =
    (matrix.(row).(0) *. red)
    +. (matrix.(row).(1) *. green)
    +. (matrix.(row).(2) *. blue)
  in
  Palette.make_rgb ~red:(encode (channel 0)) ~green:(encode (channel 1))
    ~blue:(encode (channel 2))
;;

let oklab_distance first second =
  let lightness, green_red, blue_yellow = oklab first in
  let other_lightness, other_green_red, other_blue_yellow = oklab second in
  sqrt
    (((lightness -. other_lightness) ** 2.)
     +. ((green_red -. other_green_red) ** 2.)
     +. ((blue_yellow -. other_blue_yellow) ** 2.))
;;

(* The measured floor. Green put the closest pair at 0.015 on solarized-dark;
   magenta puts it at 0.027 across every scheme and both deficiencies. Held
   just under that, so a colour chosen back toward the collision fails here
   rather than in someone's terminal. *)
let action_separation_floor = 0.025

let keeper_action_colours =
  [ "Auto_restart", Masc_tui_theme.Bright_red
  ; "Recover", Masc_tui_theme.Bright_yellow
  ; "Probe", Masc_tui_theme.Bright_cyan
  ; "Direct_message", Masc_tui_theme.Bright_magenta
  ]
;;

let rec pairs = function
  | [] -> []
  | first :: rest -> List.map (fun other -> first, other) rest @ pairs rest
;;

let test_keeper_action_colours_stay_apart_without_red_and_green () =
  List.iter
    (fun scheme ->
      List.iter
        (fun kind ->
          List.iter
            (fun ((left_label, left), (right_label, right)) ->
              let separation =
                oklab_distance
                  (simulate_deficiency kind
                     (ansi scheme
                        (Masc_tui_theme.For_testing.ansi_color_index left)))
                  (simulate_deficiency kind
                     (ansi scheme
                        (Masc_tui_theme.For_testing.ansi_color_index right)))
              in
              check bool
                (Printf.sprintf "%s: %s and %s stay %.3f apart" scheme.name
                   left_label right_label separation)
                true
                (separation >= action_separation_floor))
            (pairs keeper_action_colours))
        [ `Deuteranopia; `Protanopia ])
    schemes
;;

let () =
  Alcotest.run "masc-tui-theme-contrast"
    [ ( "readability across themes"
      , [ Alcotest.test_case "lifting makes every token readable" `Quick
            test_lifting_makes_every_token_readable_on_every_scheme
        ; Alcotest.test_case "lifting keeps the colour it lifted" `Quick
            test_lifting_keeps_the_colour_it_lifted
        ; Alcotest.test_case "a readable colour is left alone" `Quick
            test_a_colour_that_already_reads_is_left_alone
        ; Alcotest.test_case "receding moves toward the background" `Quick
            test_receding_moves_toward_the_background_on_every_scheme
        ; Alcotest.test_case "a failing entry is replaced, a passing one is not"
            `Quick
            test_a_failing_theme_entry_is_replaced_and_a_passing_one_is_not
        ; Alcotest.test_case "an unanswered palette changes nothing" `Quick
            test_an_unanswered_palette_changes_nothing
        ; Alcotest.test_case
            "keeper action colours stay apart without red and green" `Quick
            test_keeper_action_colours_stay_apart_without_red_and_green
        ] )
    ]
;;
