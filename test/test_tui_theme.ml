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

let () =
  Alcotest.run "masc_tui_theme"
    [ ( "unconditional"
      , [ Alcotest.test_case "reset and reverse survive NO_COLOR" `Quick
            test_reset_and_reverse_survive_no_color
        ] )
    ; ( "conditional"
      , [ Alcotest.test_case "every colour agrees with the flag" `Quick
            test_conditional_tokens_agree_with_the_flag
        ; Alcotest.test_case "the flag reflects the environment" `Quick
            test_the_shim_is_the_same_strings
        ] )
    ; ( "semantic"
      , [ Alcotest.test_case "status names the exact hues" `Quick
            test_status_names_the_exact_hues
        ; Alcotest.test_case "tone has three values" `Quick
            test_tone_is_three_values
        ; Alcotest.test_case "glyphs hold their bytes" `Quick
            test_glyphs_hold_their_bytes
        ] )
    ]
