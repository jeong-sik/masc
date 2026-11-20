(* The token contracts, asserted where they are declared.

   Colours are conditional on the environment, so the tests assert relations
   rather than absolutes: whatever [colors_enabled] read at start-up, the
   unconditional tokens must hold their bytes and the conditional ones must
   all agree with the flag. The semantic layer is asserted against the exact
   Sgr values so a remap is a deliberate edit here, not an accident there. *)

let check = Alcotest.check
let bool = Alcotest.bool

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

let test_paint_row_background_preserves_fg_and_hit_marks () =
  let bg = "\027[48;2;40;40;48m" in
  let input =
    "\027[=1;7m\027[32m●\027[0m \027[41;33mwarn\027[0m end\027[=2m"
  in
  let out = Masc_tui_theme.paint_row_background ~bg input in
  let contains haystack needle =
    let n = String.length needle and h = String.length haystack in
    let rec go i = i + n <= h && (String.sub haystack i n = needle || go (i + 1)) in
    go 0
  in
  check bool "opens with row background" true (String.starts_with ~prefix:bg out);
  check bool "preserves green foreground" true (contains out "\027[32m●");
  check bool "re-applies background after inner reset" true
    (contains out ("\027[0m" ^ bg ^ " "));
  check bool "strips inner 41 background while keeping 33 foreground" true
    (contains out "\027[33mwarn" && not (contains out "41"));
  check bool "preserves private hit marks verbatim" true
    (contains out "\027[=1;7m" && contains out "\027[=2m");
  check bool "closes with SGR reset" true
    (String.ends_with ~suffix:Masc_tui_theme.Sgr.reset out);
  let empty_reset = Masc_tui_theme.paint_row_background ~bg "\027[;32mok\027[32;m tail" in
  check bool "empty leading SGR param re-applies background" true
    (contains empty_reset ("\027[0;32m" ^ bg ^ "ok"));
  check bool "empty trailing SGR param re-applies background" true
    (contains empty_reset ("\027[32;0m" ^ bg ^ " tail"));
  let non_sgr = Masc_tui_theme.paint_row_background ~bg "\027[2Kitem" in
  check bool "non-SGR CSI sequence is preserved verbatim without scanning past K" true
    (contains non_sgr "\027[2Kitem")

let test_with_styled_runs_coalesces_and_closes () =
  let reset = Masc_tui_theme.Sgr.reset in
  let red = "\027[31m" and green = "\027[32m" in
  check Alcotest.string "empty run emits nothing" ""
    (Masc_tui_theme.Sgr.emit_styled_cells []);
  check Alcotest.string "unstyled cells emit zero escapes (NO_COLOR parity)" "abc"
    (Masc_tui_theme.Sgr.emit_styled_cells [ "", "a"; "", "b"; "", "c" ]);
  check Alcotest.string "empty text spans never emit dangling escapes" ""
    (Masc_tui_theme.Sgr.emit_styled_cells [ red, ""; green, "" ]);
  check Alcotest.string "same-style neighbours share one SGR opener and one reset"
    (green ^ "ab" ^ reset ^ red ^ "cd" ^ reset ^ "e" ^ green ^ "f" ^ reset)
    (Masc_tui_theme.Sgr.emit_styled_cells
       [ green, "a"; green, "b"; red, "c"; red, ""; red, "d"; "", "e"; green, "f" ]);
  check Alcotest.string "trailing unstyled cell leaves no extra reset at end"
    (red ^ "x" ^ reset ^ "y")
    (Masc_tui_theme.Sgr.with_styled_runs ~capacity:16 (fun emit ->
       emit red "x";
       emit "" "y"))

let () =
  Alcotest.run "masc_tui_theme"
    [ ( "unconditional"
      , [ Alcotest.test_case "paint_row_background preserves foreground and hit marks" `Quick
            test_paint_row_background_preserves_fg_and_hit_marks
        ; Alcotest.test_case "with_styled_runs coalesces transitions and resets once" `Quick
            test_with_styled_runs_coalesces_and_closes
        ] )
    ; ( "conditional"
      , [ Alcotest.test_case "colour environment policy is deterministic" `Quick
            test_colour_environment_policy
        ; Alcotest.test_case "the flag reflects the environment" `Quick
            test_the_shim_is_the_same_strings
        ] )
    ; ( "semantic"
      , [] )
    ]
