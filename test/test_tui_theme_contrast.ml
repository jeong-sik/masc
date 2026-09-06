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
let string = Alcotest.string
let int = Alcotest.int
let list = Alcotest.list
let fail = Alcotest.fail

module Color = Masc_tui_color
module Palette = Masc_tui_terminal_palette

module Catalog = Masc_tui_theme_catalog

(* [Catalog.all]/[Catalog.find] take [~base_path] as the project root and
   append "config/themes" to it themselves (theme_dirs_for_base in
   masc_tui_theme_catalog.ml); the caller passes the root, not the themes
   directory. A dune test runs in _build/default/test, where the process cwd
   has no [config] at all: the list would quietly narrow to the bundled
   themes and every contrast below would measure a copy instead of the
   shipped ones. The prompt gate (test_prompt_templates_render) reads its
   directory through DUNE_SOURCEROOT; this stanza deps (source_tree
   config/themes) the same directory, so the two halves agree here. *)
let themes_base_path () =
  match Sys.getenv_opt "DUNE_SOURCEROOT" with
  | Some root -> root
  | None -> Sys.getcwd ()
;;

(* The schemes are the ones masc ships, not a copy of them. A number here is
   what a reader who picks that theme sees. *)
type scheme =
  { name : string
  ; palette : Palette.t
  }

(* [all], not [bundled]. A scheme in config/themes shadows a bundled one of the
   same name, so [bundled] is the copy and [all] is what a reader gets. masc's
   own schemes live only in config/themes and would sit outside every contract
   below if this read the other list. If that directory is not found, [all]
   quietly narrows to [bundled] -- test_load_retro_themes_toml names the six
   and fails loudly, which is what keeps this coverage from shrinking in
   silence. *)
let schemes =
  List.map
    (fun shipped ->
      match Catalog.to_palette shipped with
      | Some palette -> { name = Catalog.name shipped; palette }
      | None ->
        Alcotest.failf "shipped scheme %s has malformed hex" (Catalog.name shipped))
    (Catalog.all ~base_path:(themes_base_path ()) ())
;;




let ansi scheme index =
  match Palette.ansi scheme.palette index with
  | Some color -> color
  | None -> Alcotest.failf "%s has no entry for ANSI %d" scheme.name index
;;

let background scheme = Palette.background scheme.palette
let foreground scheme = Palette.foreground scheme.palette

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

(* The slot hues, measured on all 43 shipped schemes -- 37 bundled and the
   six under config/themes.

   The worst pair in full colour vision is 0.023960: horizon-dark's yellow
   against its green, base0A EFB993 against base0B EFAF8E. The floor is
   0.023, which leaves about the same margin under the observation that the
   keeper action floor leaves under its own. It is a ratchet: a scheme added
   below it fails here rather than in a reader's terminal.

   Not comparable to that floor, though the two numbers look alike. The
   keeper action test measures only under simulated deficiency and never in
   full colour vision; this one is the other way round. Measured the same
   way, these five hues come to 0.003345 under deuteranopia (ayu-dark) and
   0.003246 under protanopia (ayu-light) -- both the yellow-green pair
   again, and both about seven times under 0.025.

   So colour does not carry this axis and is not asked to. The file list
   separates its kinds by glyph; test_tui_file_icon's [glyphs_distinct]
   checks those are distinct strings, which is byte distinctness and not a
   measurement of how far apart they read. Any axis moved onto these slots
   needs a second channel of its own. *)
let categorical_separation_floor = 0.023

let labelled_categories =
  List.map
    (fun slot ->
      ( (match slot with
         | Masc_tui_ansi.Theme.Slot_1 -> "Slot_1"
         | Masc_tui_ansi.Theme.Slot_2 -> "Slot_2"
         | Masc_tui_ansi.Theme.Slot_3 -> "Slot_3"
         | Masc_tui_ansi.Theme.Slot_4 -> "Slot_4"
         | Masc_tui_ansi.Theme.Slot_5 -> "Slot_5")
      , slot ))
    Masc_tui_ansi.Theme.all_categories
;;

let categorical_slot_colours =
  List.map
    (fun (label, slot) -> (label, Masc_tui_ansi.Theme.category_colour slot))
    labelled_categories
;;

(* A slot is the same bytes as some status token by construction: the theme
   names seven hues and status_ansi_color claims five of them. What must not
   happen is a slot aliasing a token drawn on the same terminal row, and the
   file list is where that bit: it draws Theme.bad () eight times and
   Theme.ok () once across the two panes write_two_panes joins, and for one
   commit its media mark was Bright_red -- Theme.bad () to the byte.

   So this holds the slot set clear of those two. Info and warn are still
   aliased, and are safe only because that surface draws neither; a surface
   reaching for slot 1 or 2 owes the same check this test makes here. *)
let test_no_categorical_slot_aliases_a_drawn_status_token () =
  let drawn = [ "bad", Masc_tui_ansi.Theme.bad; "ok", Masc_tui_ansi.Theme.ok ] in
  List.iter
    (fun (slot_label, _) ->
      List.iter
        (fun (status_label, token) ->
          check bool
            (Printf.sprintf "%s does not draw the same escape as %s" slot_label
               status_label)
            false
            (String.equal
               (Masc_tui_ansi.Theme.category
                  (List.assoc slot_label labelled_categories))
               (token ())))
        drawn)
    categorical_slot_colours
;;

let test_categorical_slots_hold_their_measured_floor () =
  List.iter
    (fun scheme ->
      List.iter
        (fun ((left_label, left), (right_label, right)) ->
          let separation =
            oklab_distance
              (ansi scheme (Masc_tui_theme.For_testing.ansi_color_index left))
              (ansi scheme (Masc_tui_theme.For_testing.ansi_color_index right))
          in
          check bool
            (* Six places, so a failure cannot print the same number it is
               being compared against. *)
            (Printf.sprintf "%s: %s and %s stay %.6f apart" scheme.name
               left_label right_label separation)
            true
            (separation >= categorical_separation_floor))
        (pairs categorical_slot_colours))
    schemes
;;

(* [tui] lift_colours off. The lift exists for schemes whose colours fall
   under the floor; a reader who picked a high-contrast scheme already solved
   that, and for them the lift is not a rescue but a change to colours they
   chose. Off has to mean the scheme's own code goes out -- including for the
   entries that fail the floor, which are the only ones the lift ever touched
   and so the only ones where off and on differ.

   The setting is restored whatever the checks do: it is a ref every later
   test in this file reads. *)
let with_lift enabled f =
  let restore = Masc_tui_theme.lift_is_enabled () in
  Masc_tui_theme.set_lift_enabled enabled;
  Fun.protect ~finally:(fun () -> Masc_tui_theme.set_lift_enabled restore) f
;;

let test_lift_off_draws_the_schemes_own_colour () =
  with_lift false (fun () ->
      List.iter
        (fun scheme ->
          let bg = background scheme in
          List.iter
            (fun (label, colour) ->
              let entry =
                ansi scheme (Masc_tui_theme.For_testing.ansi_color_index colour)
              in
              let ratio = Color.contrast_ratio entry bg in
              check bool
                (Printf.sprintf
                   "%s: %s reads at %.2f and still goes out as the scheme's own"
                   scheme.name label ratio)
                true
                (String.equal (readable scheme colour)
                   (Masc_tui_theme.For_testing.ansi_color_code colour)))
            named_colours)
        schemes)
;;

(* The same schemes with the lift on must not all agree with the off run, or
   the check above would pass on a lift that never did anything. At least one
   entry somewhere is under the floor -- the bundled set includes schemes the
   catalog notes as needing several. *)
let test_lift_on_still_replaces_a_failing_entry () =
  with_lift true (fun () ->
      let replaced =
        List.exists
          (fun scheme ->
            List.exists
              (fun (_, colour) ->
                String.starts_with ~prefix:truecolor_prefix
                  (readable scheme colour))
              named_colours)
          schemes
      in
      check bool "some entry is lifted when the lift is on" true replaced)
;;

(* What the theme screen reads to label its last column. The count beside a
   scheme means "lifted" under one setting and "left under the floor" under
   the other, so the screen has to be able to ask. *)
let test_the_setting_reads_back () =
  with_lift false (fun () ->
      check bool "off reads back as off" false (Masc_tui_theme.lift_is_enabled ()));
  with_lift true (fun () ->
      check bool "on reads back as on" true (Masc_tui_theme.lift_is_enabled ()))
;;

let contrast_entry ~measured ~lifted : Masc_tui_theme_choice.entry =
  { name = "test"; light = false; measured; lifted; swatch = [] }
;;

let test_contrast_status_names_native_assisted_and_unassisted () =
  let native = contrast_entry ~measured:7 ~lifted:0 in
  let assisted = contrast_entry ~measured:7 ~lifted:3 in
  check string "native is a positive result" "native 7/7"
    (Masc_tui_theme_choice.contrast_status ~lift_on:true native);
  check string "lift on names the assisted colours" "lift 3/7"
    (Masc_tui_theme_choice.contrast_status ~lift_on:true assisted);
  check string "lift off names the colours still below the floor" "3/7 low"
    (Masc_tui_theme_choice.contrast_status ~lift_on:false assisted)
;;

let test_picker_orders_native_first_then_by_cost_and_name () =
  let entries = Masc_tui_theme_choice.entries () in
  let expected =
    List.sort
      (fun (left : Masc_tui_theme_choice.entry) right ->
        match Int.compare left.lifted right.lifted with
        | 0 -> String.compare left.name right.name
        | order -> order)
      entries
  in
  check (list string) "picker order"
    (List.map (fun (entry : Masc_tui_theme_choice.entry) -> entry.name) expected)
    (List.map (fun (entry : Masc_tui_theme_choice.entry) -> entry.name) entries);
  match entries with
  | [] -> fail "bundled theme picker is empty"
  | first :: rest ->
    (* No bundled scheme passes natively today (the best one still lifts a
       colour), so asserting [lifted = 0] pins the catalog's contents, not
       the feature. The ordering's own guarantee is what holds regardless
       of the data: the first entry lifts no more than any other, so a
       native scheme — once one exists — lands first. *)
    List.iter
      (fun (entry : Masc_tui_theme_choice.entry) ->
        check bool "first scheme lifts the least" true
          (first.lifted <= entry.lifted))
      rest
;;

let test_of_toml_content_parses_valid_theme () =
  let content =
    {|
name = "custom-test"
light = true

[palette]
base00 = "000000"
base01 = "111111"
base02 = "222222"
base03 = "333333"
base04 = "444444"
base05 = "555555"
base06 = "666666"
base07 = "777777"
base08 = "888888"
base09 = "999999"
base0a = "aaaaaa"
base0b = "bbbbbb"
base0c = "cccccc"
base0d = "dddddd"
base0e = "eeeeee"
base0f = "ffffff"
|}
  in
  match Catalog.of_toml_content content with
  | Error msg -> Alcotest.fail ("Failed to parse valid TOML theme: " ^ msg)
  | Ok scheme ->
    check string "name matches" "custom-test" (Catalog.name scheme);
    check bool "light matches" true (Catalog.light scheme);
    check bool "to_palette produces palette" true (Option.is_some (Catalog.to_palette scheme))
;;

let test_of_toml_content_rejects_missing_slot () =
  let content = {|
name = "broken"
[palette]
base00 = "000000"
|} in
  match Catalog.of_toml_content content with
  | Ok _ -> Alcotest.fail "Expected error for missing slots"
  | Error _ -> ()
;;

let test_load_retro_themes_toml () =
  List.iter
    (fun name ->
      let scheme_opt = Catalog.find ~base_path:(themes_base_path ()) name in
      check bool (name ^ " is discovered from config/themes") true (Option.is_some scheme_opt);
      match scheme_opt with
      | None -> ()
      | Some scheme ->
        check string ("name matches " ^ name) name (Catalog.name scheme);
        check bool "is dark theme" false (Catalog.light scheme);
        check bool "to_palette produces palette" true (Option.is_some (Catalog.to_palette scheme)))
    [ "dungeon-gold"; "norton"; "msx"; "pc-tools"; "msc"; "cyber"
    ; "vaporwave"; "toxic"; "abyss"; "solar-flare"; "blade" ]
;;

(* The schemes above are found by name; this says they are also *measured*.
   [schemes] is the list every contract in this file iterates, so a theme
   missing here is a theme masc draws and never checks. *)
let test_contracts_cover_the_toml_themes () =
  let measured = List.map (fun s -> s.name) schemes in
  List.iter
    (fun name ->
      check bool (name ^ " is under the readability contracts") true
        (List.mem name measured))
    [ "dungeon-gold"; "norton"; "msx"; "pc-tools"; "msc"; "cyber"
    ; "vaporwave"; "toxic"; "abyss"; "solar-flare"; "blade" ]
;;

let test_clean_hex_rejects_underscores () =
  let content = {|
name = "bad-hex"
[palette]
base00 = "1_2_3_"
base01 = "010101"
base02 = "020202"
base03 = "030303"
base04 = "040404"
base05 = "050505"
base06 = "060606"
base07 = "070707"
base08 = "080808"
base09 = "090909"
base0a = "0a0a0a"
base0b = "0b0b0b"
base0c = "0c0c0c"
base0d = "0d0d0d"
base0e = "0e0e0e"
base0f = "0f0f0f"
|} in
  match Catalog.of_toml_content content with
  | Ok _ -> Alcotest.fail "Expected clean_hex to reject underscores"
  | Error _ -> ()
;;

(* The four presets the task names are bundled under exactly those names.
   [schemes] comes from [Catalog.all], so the contracts above measure every
   bundled scheme including these four; a name missing from [bundled] fails
   here instead of quietly shipping. *)
let retro_preset_names =
  [ "norton-commander"; "msx-retro"; "pc-tools-vintage"; "cga-classic" ]
;;

let test_bundled_retro_presets_carry_the_task_names () =
  List.iter
    (fun name ->
      match Catalog.find name with
      | None -> Alcotest.fail (name ^ " is not bundled")
      | Some scheme ->
        check bool (name ^ " is dark") false (Catalog.light scheme);
        check bool (name ^ " builds a palette") true
          (Option.is_some (Catalog.to_palette scheme)))
    retro_preset_names
;;

let test_contracts_cover_the_bundled_retro_presets () =
  let measured = List.map (fun s -> s.name) schemes in
  List.iter
    (fun name ->
      check bool (name ^ " is under the readability contracts") true
        (List.mem name measured))
    retro_preset_names
;;

(* AC: :theme <name> switches immediately. [apply] is the same entry the TUI
   command goes through, so accepting a bundled name and rejecting one no
   scheme carries is the whole contract of the switch. *)
let test_theme_command_applies_a_retro_preset_by_name () =
  check bool "apply accepts a bundled preset" true
    (Masc_tui_theme_choice.apply "norton-commander");
  check bool "apply rejects a name no scheme carries" false
    (Masc_tui_theme_choice.apply "no-such-retro-preset")
;;

let () =
  Alcotest.run "masc-tui-theme-contrast"
    [ ( "lift_colours"
      , [ Alcotest.test_case "off draws the scheme's own colour" `Quick
            test_lift_off_draws_the_schemes_own_colour
        ; Alcotest.test_case "on still replaces a failing entry" `Quick
            test_lift_on_still_replaces_a_failing_entry
        ; Alcotest.test_case "the setting reads back" `Quick
            test_the_setting_reads_back
        ; Alcotest.test_case "status names native, assisted, and low" `Quick
            test_contrast_status_names_native_assisted_and_unassisted
        ; Alcotest.test_case "picker orders native first, then cost and name"
            `Quick test_picker_orders_native_first_then_by_cost_and_name
        ] )
    ; ( "readability across themes"
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
        ; Alcotest.test_case "no categorical slot aliases a drawn status token"
            `Quick test_no_categorical_slot_aliases_a_drawn_status_token
        ; Alcotest.test_case "categorical slots hold their measured floor"
            `Quick test_categorical_slots_hold_their_measured_floor

        ] )
    ; ( "toml theme loading"
      , [ Alcotest.test_case "of_toml_content parses valid theme" `Quick
            test_of_toml_content_parses_valid_theme
        ; Alcotest.test_case "of_toml_content rejects missing slot" `Quick
            test_of_toml_content_rejects_missing_slot
        ; Alcotest.test_case "clean_hex rejects underscores" `Quick
            test_clean_hex_rejects_underscores
        ; Alcotest.test_case "official toml themes discovered from config/themes" `Quick
            test_load_retro_themes_toml
        ; Alcotest.test_case "readability contracts cover the toml themes" `Quick
            test_contracts_cover_the_toml_themes
        ; Alcotest.test_case "bundled retro presets carry the task's names" `Quick
            test_bundled_retro_presets_carry_the_task_names
        ; Alcotest.test_case "contracts cover the bundled retro presets" `Quick
            test_contracts_cover_the_bundled_retro_presets
        ; Alcotest.test_case "the theme command applies a preset by name" `Quick
            test_theme_command_applies_a_retro_preset_by_name
        ] )
    ]
;;
