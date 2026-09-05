(* The token contracts, asserted where they are declared.

   Colours are conditional on the environment, so the tests assert relations
   rather than absolutes: whatever [colors_enabled] read at start-up, the
   unconditional tokens must hold their bytes and the conditional ones must
   all agree with the flag. The semantic layer is asserted against the exact
   Sgr values so a remap is a deliberate edit here, not an accident there. *)

let check = Alcotest.check
let str = Alcotest.string
let bool = Alcotest.bool

let test_reset_and_reverse_survive_no_color () =
  check str "reset closes reverse even under NO_COLOR" "\027[0m"
    Masc_tui_theme.Sgr.reset;
  check str "reverse is the NO_COLOR-safe selection signal" "\027[7m"
    Masc_tui_theme.Sgr.reverse;
  check str "selection is reverse" Masc_tui_theme.Sgr.reverse
    Masc_tui_theme.selection

let conditional_tokens =
  Masc_tui_theme.Sgr.
    [ ("bold", bold, "\027[1m")
    ; ("dim", dim, "\027[2m")
    ; ("underline", underline, "\027[4m")
    ; ("no_underline", no_underline, "\027[24m")
    ; ("red", red, "\027[31m")
    ; ("green", green, "\027[32m")
    ; ("yellow", yellow, "\027[33m")
    ; ("blue", blue, "\027[34m")
    ; ("magenta", magenta, "\027[35m")
    ; ("cyan", cyan, "\027[36m")
    ; ("white", white, "\027[37m")
    ; ("default_fg", default_fg, "\027[39m")
    ; ("gray", gray, "\027[90m")
    ; ("bright_red", bright_red, "\027[91m")
    ; ("bright_green", bright_green, "\027[92m")
    ; ("bright_yellow", bright_yellow, "\027[93m")
    ; ("bright_blue", bright_blue, "\027[94m")
    ; ("bright_magenta", bright_magenta, "\027[95m")
    ; ("bright_cyan", bright_cyan, "\027[96m")
    ; ("bg_removed", bg_removed, "\027[48;5;52m")
    ; ("bg_added", bg_added, "\027[48;5;22m")
    ]

let test_conditional_tokens_agree_with_the_flag () =
  List.iter
    (fun (name, value, code) ->
      let expected = if Masc_tui_theme.colors_enabled then code else "" in
      check str name expected value)
    conditional_tokens;
  check str "style applies the same rule"
    (if Masc_tui_theme.colors_enabled then "x" else "")
    (Masc_tui_theme.style "x")

let test_projected_background_bytes () =
  let expected bytes = if Masc_tui_theme.colors_enabled then bytes else "" in
  let rgb = Masc_tui_terminal_palette.make_rgb ~red:12 ~green:34 ~blue:56 in
  let truecolor =
    Masc_tui_terminal_palette.For_testing.best_color_for_level
      ~level:Masc_tui_terminal_palette.True_color rgb
  in
  let indexed =
    Masc_tui_terminal_palette.For_testing.best_color_for_level
      ~level:Masc_tui_terminal_palette.Ansi256
      (Masc_tui_terminal_palette.make_rgb ~red:95 ~green:0 ~blue:0)
  in
  check str "truecolor background"
    (expected "\027[48;2;12;34;56m")
    (Masc_tui_theme.Sgr.background truecolor);
  check str "indexed background"
    (expected "\027[48;5;52m")
    (Masc_tui_theme.Sgr.background indexed);
  check str "unsupported level keeps the default background" ""
    (Masc_tui_theme.Sgr.background None)

let rgb red green blue =
  Masc_tui_terminal_palette.make_rgb ~red ~green ~blue
;;

let check_rgb label (red, green, blue) color =
  check Alcotest.(triple int int int) label (red, green, blue)
    ( Masc_tui_terminal_palette.red color
    , Masc_tui_terminal_palette.green color
    , Masc_tui_terminal_palette.blue color )
;;

let no_ansi () =
  Array.make Masc_tui_terminal_palette.ansi_slot_count None
;;

let palette background =
  Masc_tui_terminal_palette.of_responses
    ~foreground:(Some (rgb 255 255 255)) ~background:(Some background)
    ~ansi:(no_ansi ())
;;

let user_background ~colors_enabled ~level background =
  Masc_tui_theme.For_testing.user_message_background ~colors_enabled
    ~project:
      (Masc_tui_terminal_palette.For_testing.best_color_for_level ~level)
    (palette background)
;;

(* The one property that matters: a receded row must move toward the
   background, whichever background that is. SGR 2 only ever moves toward
   black, so on a light terminal it moves the wrong way. *)
let two_tone_palette ~foreground ~background =
  Masc_tui_terminal_palette.of_responses ~foreground:(Some foreground)
    ~background:(Some background) ~ansi:(no_ansi ())
;;

let recede ?(theme_mode = None) ~colors_enabled ~level palette =
  Masc_tui_theme.For_testing.recede ~colors_enabled ~dim:"DIM" ~gray:"GRAY"
    ~theme_mode
    ~project:
      (Masc_tui_terminal_palette.For_testing.best_color_for_level ~level)
    palette
;;

let blended ~foreground ~background =
  match Masc_tui_theme.For_testing.recede_rgb ~foreground ~background with
  | Some color -> color
  | None -> Alcotest.fail "expected a receded colour, got none"
;;

let test_recede_moves_toward_the_background () =
  (* Dark terminal: white text on black recedes by getting darker, which is
     also the direction SGR 2 moves, so this case was already right. *)
  check_rgb "on a dark terminal receding darkens the text" (153, 153, 153)
    (blended ~foreground:(rgb 255 255 255) ~background:(rgb 0 0 0));
  (* Light terminal: black text on white recedes by getting lighter. SGR 2
     blends toward black, so it would have darkened this row instead --
     the inversion this token exists to remove. *)
  check_rgb "on a light terminal receding lightens the text" (102, 102, 102)
    (blended ~foreground:(rgb 0 0 0) ~background:(rgb 255 255 255))
;;

(* Receded text is still text. Blending it all the way to the background
   would hide it, so the step has to leave it legible. *)
let contrast_ratio a b =
  let channel value =
    let v = float_of_int value /. 255. in
    if v <= 0.03928 then v /. 12.92
    else ((v +. 0.055) /. 1.055) ** 2.4
  in
  let luminance color =
    (0.2126 *. channel (Masc_tui_terminal_palette.red color))
    +. (0.7152 *. channel (Masc_tui_terminal_palette.green color))
    +. (0.0722 *. channel (Masc_tui_terminal_palette.blue color))
  in
  let x = luminance a and y = luminance b in
  let lighter = Float.max x y and darker = Float.min x y in
  (lighter +. 0.05) /. (darker +. 0.05)
;;

let test_receded_text_stays_legible () =
  List.iter
    (fun (name, foreground, background) ->
      let receded = blended ~foreground ~background in
      let ratio = contrast_ratio receded background in
      Alcotest.check bool
        (Printf.sprintf "%s keeps receded text above the 3:1 floor (%.2f)" name
           ratio)
        true (ratio >= 3.0))
    [ ("black on white", rgb 0 0 0, rgb 255 255 255)
    ; ("white on black", rgb 255 255 255, rgb 0 0 0)
    ; ("solarized dark", rgb 131 148 150, rgb 0 43 54)
    ; ("solarized light", rgb 101 123 131, rgb 253 246 227)
    ]
;;

let test_recede_falls_back_where_it_cannot_compute () =
  let light = two_tone_palette ~foreground:(rgb 0 0 0) ~background:(rgb 255 255 255) in
  check str "a truecolor terminal gets the computed colour"
    "\027[38;2;102;102;102m"
    (recede ~colors_enabled:true
       ~level:Masc_tui_terminal_palette.True_color light);
  check str "ANSI256 gets the nearest fixed xterm entry" "\027[38;5;241m"
    (recede ~colors_enabled:true ~level:Masc_tui_terminal_palette.Ansi256 light);
  List.iter
    (fun level ->
      check str "a capability that cannot carry the colour keeps SGR 2" "DIM"
        (recede ~colors_enabled:true ~level light))
    [ Masc_tui_terminal_palette.Ansi16; Masc_tui_terminal_palette.Unknown ];
  check str "a terminal that never answered keeps SGR 2" "DIM"
    (recede ~colors_enabled:true ~level:Masc_tui_terminal_palette.True_color
       None);
  (* No palette but the page was reported on its own -- a multiplexer, which
     passes DECSET 996 and 2031 through and answers no OSC colour query. SGR 2
     blends toward black, so on a light page it walks away from it. *)
  check str "a light page with no palette recedes with bright black" "GRAY"
    (recede ~theme_mode:(Some Masc_tui_terminal_palette.Light)
       ~colors_enabled:true ~level:Masc_tui_terminal_palette.True_color None);
  check str "a dark page with no palette keeps SGR 2" "DIM"
    (recede ~theme_mode:(Some Masc_tui_terminal_palette.Dark)
       ~colors_enabled:true ~level:Masc_tui_terminal_palette.True_color None);
  (* A page the terminal did answer for is measured, not guessed at. *)
  check bool "a known palette outranks the reported page" true
    (String.equal
       (recede ~theme_mode:(Some Masc_tui_terminal_palette.Light)
          ~colors_enabled:true ~level:Masc_tui_terminal_palette.True_color
          light)
       (recede ~colors_enabled:true
          ~level:Masc_tui_terminal_palette.True_color light));
  check str "disabled colours draw nothing at all" ""
    (recede ~colors_enabled:false ~level:Masc_tui_terminal_palette.True_color
       light)
;;

let test_user_message_background_blend () =
  let blend = Masc_tui_theme.For_testing.user_message_background_rgb in
  check_rgb "dark blends twelve percent toward white" (30, 30, 30)
    (blend (rgb 0 0 0));
  check_rgb "light blends four percent toward black" (244, 244, 244)
    (blend (rgb 255 255 255));
  (* A mid orange. Rec.601 luma put it at 0.487 and called the page dark;
     perceived lightness puts it at 0.614 and calls it light, which is the
     answer the page itself gives -- black text on it reads at 5.32 and white
     at 3.94. One measure of lightness now, so this and the direction a colour
     moves to be read cannot disagree about the same terminal. *)
  check_rgb "a saturated mid tone reads as the light page it is" (192, 96, 48)
    (blend (rgb 200 100 50))
;;

(* The pane's ground and the reader's own rows step off the page by the same
   amount, whatever the palette: one grey for everything set apart, not two
   the eye has to rank. *)
let test_side_pane_background_shares_the_user_row_ground () =
  List.iter
    (fun background ->
       let palette = palette background in
       Alcotest.(check string)
         "same ground"
         (Masc_tui_theme.user_message_background palette)
         (Masc_tui_theme.side_pane_background palette))
    [ rgb 0 0 0; rgb 255 255 255; rgb 30 30 46; rgb 253 246 227 ];
  Alcotest.(check string)
    "no palette, no ground"
    "" (Masc_tui_theme.side_pane_background None)
;;

let test_user_message_background_fallbacks () =
  check str "truecolor keeps the blended RGB" "\027[48;2;30;30;30m"
    (user_background ~colors_enabled:true
       ~level:Masc_tui_terminal_palette.True_color (rgb 0 0 0));
  check str "ANSI256 uses the nearest fixed xterm entry" "\027[48;5;234m"
    (user_background ~colors_enabled:true
       ~level:Masc_tui_terminal_palette.Ansi256 (rgb 0 0 0));
  List.iter
    (fun level ->
      check str "unsupported capability keeps the terminal background" ""
        (user_background ~colors_enabled:true ~level (rgb 0 0 0)))
    [ Masc_tui_terminal_palette.Ansi16
    ; Masc_tui_terminal_palette.Unknown
    ];
  check str "an unknown palette stays unstyled" ""
    (Masc_tui_theme.For_testing.user_message_background ~colors_enabled:true
       ~project:
         (Masc_tui_terminal_palette.For_testing.best_color_for_level
            ~level:Masc_tui_terminal_palette.True_color)
       None);
  let projected = ref false in
  check str "NO_COLOR stays unstyled" ""
    (Masc_tui_theme.For_testing.user_message_background ~colors_enabled:false
       ~project:(fun _ ->
         projected := true;
         None)
       (palette (rgb 0 0 0)));
  check bool "NO_COLOR does not project a hidden colour" false !projected
;;

let test_colour_environment_policy () =
  let enabled = Masc_tui_theme.For_testing.colors_enabled in
  check bool "NO_COLOR disables styling" false
    (enabled ~force_color:None ~no_color:(Some "1"));
  check bool "any non-empty NO_COLOR disables styling" false
    (enabled ~force_color:(Some "0") ~no_color:(Some "0"));
  check bool "empty NO_COLOR does not disable styling" true
    (enabled ~force_color:None ~no_color:(Some ""));
  check bool "MASC_TUI_FORCE_COLOR=1 overrides NO_COLOR" true
    (enabled ~force_color:(Some "1") ~no_color:(Some "1"));
  check bool "other force values do not override NO_COLOR" false
    (enabled ~force_color:(Some "true") ~no_color:(Some "1"))

let test_status_names_the_exact_hues () =
  let open Masc_tui_theme in
  check str "ok is vivid green" Sgr.bright_green (status Ok);
  check str "warn is vivid yellow" Sgr.bright_yellow (status Warn);
  check str "bad is vivid red" Sgr.bright_red (status Bad);
  check str "info is vivid cyan" Sgr.bright_cyan (status Info);
  check str "muted remains readable gray" Sgr.gray (status Muted)

let test_tone_is_three_values () =
  let open Masc_tui_theme in
  check str "normal needs no escape" "" (tone Normal);
  check str "dim is the dim weight" Sgr.dim (tone Dim);
  check str "accent is the vivid accent hue" Sgr.bright_cyan (tone Accent);
  check str "border focus shares the accent" Sgr.bright_cyan border_focus

let test_glyphs_hold_their_bytes () =
  let open Masc_tui_theme.Glyph in
  check str "done" "\xe2\x97\x8f" task_done;
  check str "active" "\xe2\x97\x90" task_active;
  check str "todo" "\xe2\x97\x8b" task_todo;
  check str "cancelled" "\xc3\x97" task_cancelled;
  check str "breadcrumb" "\xe2\x96\xb8" breadcrumb_sep;
  (* Only the top priority speaks; the !!!/!!/! ladder put a mark on most
     rows, which distinguishes nothing. *)
  check str "priority 1 speaks once" "!" (priority 1);
  check str "priority 2 says nothing" "" (priority 2);
  check str "priority 3 says nothing" "" (priority 3);
  check str "priority 4 and below say nothing" "" (priority 4);
  check str "braille spinner frame 0" "\xe2\xa3\xbe" (braille_spinner 0);
  check str "braille spinner frame 7" "\xe2\xa3\xb7" (braille_spinner 7);
  check str "braille spinner cycles" "\xe2\xa3\xbe" (braille_spinner 8);
  check str "braille spinner negative step" "\xe2\xa3\xb7" (braille_spinner (-1));
  check str "equalizer min level" " " (equalizer_level 0);
  check str "equalizer max level" "\xe2\x96\x88" (equalizer_level 7);
  check str "equalizer negative level clamped" " " (equalizer_level (-1));
  check str "equalizer overflow clamped" "\xe2\x96\x88" (equalizer_level 99)

let test_the_shim_is_the_same_strings () =
  (* Masc_tui_ansi is not linkable from tests (it lives in the executable),
     so the shim itself is covered by @check plus the PTY suite's
     byte-identical frames. What this test pins is the part a shim cannot
     redefine: the flag both modules read. *)
  check bool "colors_enabled is a start-up fact"
    Masc_tui_theme.colors_enabled
    (match Sys.getenv_opt "MASC_TUI_FORCE_COLOR" with
     | Some "1" -> true
     | Some _ | None ->
       (match Sys.getenv_opt "NO_COLOR" with
        | Some value when String.length value > 0 -> false
        | Some _ | None -> true))

let test_strip_sgr_removes_only_styles () =
  check str "plain text passes through" "abc" (Masc_tui_theme.strip_sgr "abc");
  check str "styles fold, text and glyphs stay"
    ("   " ^ "\xe2\x97\x8f healthy alpha")
    (Masc_tui_theme.strip_sgr
       ("   " ^ "\027[32m\xe2\x97\x8f healthy\027[0m \027[1malpha\027[0m"));
  check str "an unterminated escape drops without eating the row" "tail"
    (Masc_tui_theme.strip_sgr "tail\027[31");
  check str "selection line with prefix strips styles for box_line_selected"
    "> red text"
    (Masc_tui_theme.strip_sgr ("> \027[31mred\027[0m text"));
  check str "empty stays empty" "" (Masc_tui_theme.strip_sgr "")

(* Diff backgrounds are content, so they carry a reading's name and not a
   colour's. The renderer used to reach into [Sgr] for them, which is what the
   module's own boundary says a renderer does not do.

   The escapes themselves are already pinned in [conditional_tokens], with the
   NO_COLOR fold applied. Repeating them here would state the value twice and
   get the fold wrong the second time -- as the first draft of this test did,
   asserting the raw escape under a flag that empties it. What is left to
   check is that the reading names that entry and does not grow a second
   spelling of the same colour.

   Under NO_COLOR this says nothing: every token folds to the empty string, so
   any wrong entry passes. That is the flag doing its job rather than a hole
   in the check -- with no colour there is no mapping left to get wrong -- and
   it is written down because a green run there is weaker than it looks. *)
let test_diff_backgrounds_are_named_as_content () =
  check str "added names the Sgr entry" Masc_tui_theme.Sgr.bg_added
    Masc_tui_theme.Syntax.diff_added_bg;
  check str "removed names the Sgr entry" Masc_tui_theme.Sgr.bg_removed
    Masc_tui_theme.Syntax.diff_removed_bg;
  check str "row text names the fixed light entry"
    (if Masc_tui_theme.colors_enabled then "\027[38;5;255m" else "")
    Masc_tui_theme.Syntax.diff_row_foreground

(* Xterm 255 is RGB 238,238,238; the two fixed row backgrounds are xterm 22
   (0,95,0) and 52 (95,0,0). The semantic tokens are a pair, so pin the text
   contrast of both rather than accepting either byte in isolation. *)
let test_diff_row_palette_clears_text_contrast () =
  let foreground = rgb 238 238 238 in
  List.iter
    (fun (name, background) ->
       let ratio = contrast_ratio foreground background in
       check bool
         (Printf.sprintf "%s diff row clears 4.5:1 (%.2f)" name ratio)
         true (ratio >= 4.5))
    [ ("added", rgb 0 95 0); ("removed", rgb 95 0 0) ]

let () =
  Alcotest.run "masc_tui_theme"
    [ ( "unconditional"
      , [ Alcotest.test_case "reset and reverse survive NO_COLOR" `Quick
            test_reset_and_reverse_survive_no_color
        ] )
    ; ( "conditional"
      , [ Alcotest.test_case "every colour agrees with the flag" `Quick
            test_conditional_tokens_agree_with_the_flag
        ; Alcotest.test_case "projected backgrounds own their bytes" `Quick
            test_projected_background_bytes
        ; Alcotest.test_case "user background preserves capability fallbacks"
            `Quick test_user_message_background_fallbacks
        ; Alcotest.test_case "colour environment policy is deterministic" `Quick
            test_colour_environment_policy
        ; Alcotest.test_case "the flag reflects the environment" `Quick
            test_the_shim_is_the_same_strings
        ] )
    ; ( "semantic"
      , [ Alcotest.test_case "diff backgrounds are named as content" `Quick
            test_diff_backgrounds_are_named_as_content
        ; Alcotest.test_case "diff row palette clears text contrast" `Quick
            test_diff_row_palette_clears_text_contrast
        ; Alcotest.test_case "status names the exact hues" `Quick
            test_status_names_the_exact_hues
        ; Alcotest.test_case "tone has three values" `Quick
            test_tone_is_three_values
        ; Alcotest.test_case "glyphs hold their bytes" `Quick
            test_glyphs_hold_their_bytes
        ; Alcotest.test_case "user background uses the low-contrast blend"
            `Quick test_user_message_background_blend
        ; Alcotest.test_case "side pane background shares the user row ground"
            `Quick test_side_pane_background_shares_the_user_row_ground
        ; Alcotest.test_case "strip_sgr removes only styles" `Quick
            test_strip_sgr_removes_only_styles
        ; Alcotest.test_case "recede moves toward the background" `Quick
            test_recede_moves_toward_the_background
        ; Alcotest.test_case "receded text stays legible" `Quick
            test_receded_text_stays_legible
        ; Alcotest.test_case "recede falls back where it cannot compute" `Quick
            test_recede_falls_back_where_it_cannot_compute
        ] )
    ]
