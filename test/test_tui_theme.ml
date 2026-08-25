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
    ; ("red", red, "\027[31m")
    ; ("green", green, "\027[32m")
    ; ("yellow", yellow, "\027[33m")
    ; ("blue", blue, "\027[34m")
    ; ("magenta", magenta, "\027[35m")
    ; ("cyan", cyan, "\027[36m")
    ; ("white", white, "\027[37m")
    ; ("default_fg", default_fg, "\027[39m")
    ; ("gray", gray, "\027[90m")
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
  check str "truecolor background"
    (expected "\027[48;2;12;34;56m")
    (Masc_tui_theme.Sgr.background
       (Some (Masc_tui_terminal_palette.Rgb rgb)));
  check str "indexed background"
    (expected "\027[48;5;52m")
    (Masc_tui_theme.Sgr.background
       (Some (Masc_tui_terminal_palette.Indexed 52)));
  check str "unsupported level keeps the default background" ""
    (Masc_tui_theme.Sgr.background None);
  List.iter
    (fun index ->
      check str "out-of-range index keeps the default background" ""
        (Masc_tui_theme.Sgr.background
           (Some (Masc_tui_terminal_palette.Indexed index))))
    [ -1; 256 ]

let test_status_names_the_exact_hues () =
  let open Masc_tui_theme in
  check str "ok is green" Sgr.green (status Ok);
  check str "warn is yellow" Sgr.yellow (status Warn);
  check str "bad is red" Sgr.red (status Bad);
  check str "info is cyan" Sgr.cyan (status Info);
  check str "muted is dim" Sgr.dim (status Muted)

let test_tone_is_three_values () =
  let open Masc_tui_theme in
  check str "normal needs no escape" "" (tone Normal);
  check str "dim is the dim weight" Sgr.dim (tone Dim);
  check str "accent is the one accent hue" Sgr.cyan (tone Accent);
  check str "border focus shares the accent" Sgr.cyan border_focus

let test_glyphs_hold_their_bytes () =
  let open Masc_tui_theme.Glyph in
  check str "done" "\xe2\x97\x8f" task_done;
  check str "active" "\xe2\x97\x90" task_active;
  check str "todo" "\xe2\x97\x8b" task_todo;
  check str "cancelled" "\xc3\x97" task_cancelled;
  check str "breadcrumb" "\xe2\x96\xb8" breadcrumb_sep;
  check str "priority 1" "!!!" (priority 1);
  check str "priority 2" "!!" (priority 2);
  check str "priority 3" "!" (priority 3);
  check str "priority 4 and below say nothing" "" (priority 4)

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
    Masc_tui_theme.Syntax.diff_removed_bg

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
        ; Alcotest.test_case "the flag reflects the environment" `Quick
            test_the_shim_is_the_same_strings
        ] )
    ; ( "semantic"
      , [ Alcotest.test_case "diff backgrounds are named as content" `Quick
            test_diff_backgrounds_are_named_as_content
        ; Alcotest.test_case "status names the exact hues" `Quick
            test_status_names_the_exact_hues
        ; Alcotest.test_case "tone has three values" `Quick
            test_tone_is_three_values
        ; Alcotest.test_case "glyphs hold their bytes" `Quick
            test_glyphs_hold_their_bytes
        ; Alcotest.test_case "strip_sgr removes only styles" `Quick
            test_strip_sgr_removes_only_styles
        ] )
    ]
