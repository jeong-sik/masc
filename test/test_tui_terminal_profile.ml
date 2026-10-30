open Alcotest

module Profile = Masc_tui_terminal_profile

let environment entries name = List.assoc_opt name entries

let check_profile description ~sync ~keyboard ~title entries =
  let profile = Profile.detect ~getenv:(environment entries) in
  check bool (description ^ " synchronized output") sync
    (Profile.synchronized_output profile);
  check bool (description ^ " Kitty keyboard") keyboard
    (Profile.kitty_keyboard profile);
  check bool (description ^ " dynamic title") title
    (Profile.dynamic_title profile)
;;

let test_apple_terminal_is_safe_by_default () =
  check_profile "Apple Terminal defaults" ~sync:false ~keyboard:false
    ~title:false [ "TERM_PROGRAM", "Apple_Terminal" ]
;;

let test_other_terminals_keep_extended_defaults () =
  check_profile "iTerm defaults" ~sync:true ~keyboard:true ~title:true
    [ "TERM_PROGRAM", "iTerm.app" ];
  check_profile "unknown defaults" ~sync:true ~keyboard:true ~title:true []
;;

let test_explicit_settings_override_the_profile () =
  check_profile "Apple Terminal opt-in" ~sync:true ~keyboard:true ~title:true
    [ "TERM_PROGRAM", "Apple_Terminal"
    ; "MASC_TUI_SYNC", "on"
    ; "MASC_TUI_KITTY_KEYBOARD", "yes"
    ; "MASC_TUI_TITLE", "1"
    ];
  check_profile "other terminal opt-out" ~sync:false ~keyboard:false
    ~title:false
    [ "TERM_PROGRAM", "iTerm.app"
    ; "MASC_TUI_SYNC", "off"
    ; "MASC_TUI_KITTY_KEYBOARD", "false"
    ; "MASC_TUI_TITLE", "0"
    ]
;;
let () =
  run "tui_terminal_profile"
    [ ( "profile"
      , [ test_case "Apple Terminal safe defaults" `Quick
            test_apple_terminal_is_safe_by_default
        ; test_case "other terminal defaults" `Quick
            test_other_terminals_keep_extended_defaults
        ; test_case "explicit overrides" `Quick
            test_explicit_settings_override_the_profile
        ] )
    ]
;;
