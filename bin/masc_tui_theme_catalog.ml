(* The bundled schemes and the slot mapping. See the interface. *)

module Palette = Masc_tui_terminal_palette

type t =
  { name : string
  ; light : bool
  ; palette : string array (* base00 .. base0F, sixteen hex bodies *)
  }

let bundled =
  [ { name = "default-dark"
  ; light = false
  ; palette =
      [| "181818"; "282828"; "383838"; "585858"
       ; "b8b8b8"; "d8d8d8"; "e8e8e8"; "f8f8f8"
       ; "ab4642"; "dc9656"; "f7ca88"; "a1b56c"
       ; "86c1b9"; "7cafc2"; "ba8baf"; "a16946"
      |]
  }
  ; { name = "default-light"
  ; light = true
  ; palette =
      [| "f8f8f8"; "e8e8e8"; "d8d8d8"; "b8b8b8"
       ; "585858"; "383838"; "282828"; "181818"
       ; "ab4642"; "dc9656"; "f7ca88"; "a1b56c"
       ; "86c1b9"; "7cafc2"; "ba8baf"; "a16946"
      |]
  }
  ; { name = "solarized-dark"
  ; light = false
  ; palette =
      [| "002b36"; "073642"; "586e75"; "657b83"
       ; "839496"; "93a1a1"; "eee8d5"; "fdf6e3"
       ; "dc322f"; "cb4b16"; "b58900"; "859900"
       ; "2aa198"; "268bd2"; "6c71c4"; "d33682"
      |]
  }
  ; { name = "solarized-light"
  ; light = true
  ; palette =
      [| "fdf6e3"; "eee8d5"; "93a1a1"; "839496"
       ; "657b83"; "586e75"; "073642"; "002b36"
       ; "dc322f"; "cb4b16"; "b58900"; "859900"
       ; "2aa198"; "268bd2"; "6c71c4"; "d33682"
      |]
  }
  ; { name = "gruvbox-dark-hard"
  ; light = false
  ; palette =
      [| "1d2021"; "3c3836"; "504945"; "665c54"
       ; "bdae93"; "d5c4a1"; "ebdbb2"; "fbf1c7"
       ; "fb4934"; "fe8019"; "fabd2f"; "b8bb26"
       ; "8ec07c"; "83a598"; "d3869b"; "d65d0e"
      |]
  }
  ; { name = "nord"
  ; light = false
  ; palette =
      [| "2e3440"; "3b4252"; "434c5e"; "4c566a"
       ; "d8dee9"; "e5e9f0"; "eceff4"; "8fbcbb"
       ; "bf616a"; "d08770"; "ebcb8b"; "a3be8c"
       ; "88c0d0"; "81a1c1"; "b48ead"; "5e81ac"
      |]
  }
  ; { name = "dracula"
  ; light = false
  ; palette =
      [| "282a36"; "21222c"; "44475a"; "6272a4"
       ; "9ea8c7"; "f8f8f2"; "f8f8f2"; "ffffff"
       ; "ff5555"; "ffb86c"; "f1fa8c"; "50fa7b"
       ; "8be9fd"; "bd93f9"; "ff79c6"; "993333"
      |]
  }
  ; { name = "onedark"
  ; light = false
  ; palette =
      [| "282c34"; "353b45"; "3e4451"; "545862"
       ; "565c64"; "abb2bf"; "b6bdca"; "c8ccd4"
       ; "e06c75"; "d19a66"; "e5c07b"; "98c379"
       ; "56b6c2"; "61afef"; "c678dd"; "be5046"
      |]
  }
  ; { name = "tokyo-night-dark"
  ; light = false
  ; palette =
      [| "1a1b26"; "16161e"; "2f3549"; "444b6a"
       ; "787c99"; "a9b1d6"; "cbccd1"; "d5d6db"
       ; "c0caf5"; "a9b1d6"; "0db9d7"; "9ece6a"
       ; "b4f9f8"; "2ac3de"; "bb9af7"; "f7768e"
      |]
  }
  ; { name = "catppuccin-mocha"
  ; light = false
  ; palette =
      [| "1e1e2e"; "181825"; "313244"; "45475a"
       ; "585b70"; "cdd6f4"; "f5e0dc"; "b4befe"
       ; "f38ba8"; "fab387"; "f9e2af"; "a6e3a1"
       ; "94e2d5"; "89b4fa"; "cba6f7"; "f2cdcd"
      |]
  }
  ; { name = "github"
  ; light = true
  ; palette =
      [| "ffffff"; "f6f8fa"; "afb8c1"; "8c959f"
       ; "6e7781"; "424a53"; "32383f"; "1f2328"
       ; "953800"; "0550ae"; "bf8700"; "0a3069"
       ; "116329"; "8250df"; "cf222e"; "82071e"
      |]
  }
  ; { name = "monokai"
  ; light = false
  ; palette =
      [| "272822"; "383830"; "49483e"; "75715e"
       ; "a59f85"; "f8f8f2"; "f5f4f1"; "f9f8f5"
       ; "f92672"; "fd971f"; "f4bf75"; "a6e22e"
       ; "a1efe4"; "66d9ef"; "ae81ff"; "cc6633"
      |]
  }
  ]
;;

(* base16's own shell template is what a terminal loads, so it is what decides
   which palette entry an SGR colour code selects. Bright 9 through 14 repeat
   1 through 6 under base16; base24 splits them. *)
let ansi_slot =
  [| 0x0; 0x8; 0xB; 0xA; 0xD; 0xE; 0xC; 0x5
   ; 0x3; 0x8; 0xB; 0xA; 0xD; 0xE; 0xC; 0x7
  |]
;;

let hex_pair text offset = int_of_string_opt ("0x" ^ String.sub text offset 2)

let color_of_hex text =
  if String.length text <> 6 then None
  else
    match hex_pair text 0, hex_pair text 2, hex_pair text 4 with
    | Some red, Some green, Some blue -> Some (Palette.make_rgb ~red ~green ~blue)
    | _ -> None
;;

let entry scheme index =
  if index < 0 || index >= Array.length scheme.palette then None
  else color_of_hex scheme.palette.(index)
;;

let base16_foreground_slot = 0x5
let base16_background_slot = 0x0

let to_palette scheme =
  match
    ( entry scheme base16_foreground_slot
    , entry scheme base16_background_slot )
  with
  | Some foreground, Some background ->
    Palette.of_responses ~foreground:(Some foreground)
      ~background:(Some background)
      ~ansi:
        (Array.init Palette.ansi_slot_count (fun index ->
             entry scheme ansi_slot.(index)))
  | _ -> None
;;

let names () = List.map (fun scheme -> scheme.name) bundled

let find name =
  List.find_opt (fun scheme -> String.equal scheme.name name) bundled
;;

let name scheme = scheme.name
let light scheme = scheme.light
