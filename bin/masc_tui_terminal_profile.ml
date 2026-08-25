type t =
  { synchronized_output : bool
  ; kitty_keyboard : bool
  ; dynamic_title : bool
  }

let configured getenv name ~default =
  match getenv name with
  | None -> default
  | Some value ->
    (match String.lowercase_ascii (String.trim value) with
     | "0" | "false" | "no" | "off" -> false
     | "" | "1" | "true" | "yes" | "on" | _ -> true)
;;

let detect ~getenv =
  let apple_terminal =
    match getenv "TERM_PROGRAM" with
    | Some value -> String.equal (String.trim value) "Apple_Terminal"
    | None -> false
  in
  let extended_default = not apple_terminal in
  { synchronized_output =
      configured getenv "MASC_TUI_SYNC" ~default:extended_default
  ; kitty_keyboard =
      configured getenv "MASC_TUI_KITTY_KEYBOARD" ~default:extended_default
  ; dynamic_title =
      configured getenv "MASC_TUI_TITLE" ~default:extended_default
  }
;;

let synchronized_output profile = profile.synchronized_output
let kitty_keyboard profile = profile.kitty_keyboard
let dynamic_title profile = profile.dynamic_title
