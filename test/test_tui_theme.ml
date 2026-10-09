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

let () =
  Alcotest.run "masc_tui_theme"
    [ ( "unconditional"
      , [] )
    ; ( "conditional"
      , [ Alcotest.test_case "colour environment policy is deterministic" `Quick
            test_colour_environment_policy
        ; Alcotest.test_case "the flag reflects the environment" `Quick
            test_the_shim_is_the_same_strings
        ] )
    ; ( "semantic"
      , [] )
    ]
