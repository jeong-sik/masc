(* The bundled schemes and the slot mapping. See the interface.

   {1 Where the colours come from}

   Every body below is copied from the scheme's own published base16 form,
   most of them by way of tinted-theming/schemes, which is where their authors
   put them. Nothing here is a masc colour except [default-dark] and
   [default-light]. Who wrote which one, and under what licence, is recorded
   in docs/legal/THIRD-PARTY-THEMES.md; that file is the one to edit when a
   scheme is added, because a name in this list without an entry there is a
   scheme masc ships and does not credit.

   The values are fetched rather than typed. A palette entered by hand is a
   palette with a transposition in it, and the sixteen slots are ordered, so a
   swapped pair is a theme that is subtly wrong on one colour -- the hardest
   kind to notice and the easiest kind to introduce.

   {1 Which schemes are here}

   A scheme is bundled when masc can draw it faithfully, and that is decided
   by running the readability contracts in test_tui_theme_contrast, not by
   judgement. Fifty were measured on 2026-08-28: thirty-eight passed and
   twelve did not, in the three ways below. One of the thirty-eight,
   material-palenight, was then removed for a reason the contracts cannot see
   -- its upstream carries no licence and its author has objected to reuse --
   which leaves thirty-seven. THIRD-PARTY-THEMES.md records that separately,
   because "masc cannot draw it" and "masc should not ship it" are different
   answers and only the first one a test can give.

   - The lift moves the hue too far, past the 8 degrees the contract allows:
     edge-light 8.5, rose-pine-dawn 8.4, primer-light 9.8, catppuccin-latte
     9.2, everforest-light-hard 10.2, everforest-light-medium 11.0, tomorrow
     10.7, material-lighter 12.3. All eight are light schemes and all but one
     fail on the same colour, Warn.

     That is not a coincidence, and the schemes are not at fault. A yellow on
     a light page already sits near the top of the lightness range, so a lift
     that raises lightness runs out of room and the colour slides sideways
     instead. The lift moves Oklab lightness alone, which held to 5.6 degrees
     across the twelve schemes the 8-degree budget was drawn from; fifty is a
     wider population than that.

     Eight rejections with one shape is a finding about the lift, not about
     the eight. Stopping the lift at the hue budget rather than at the
     contrast floor, or clamping chroma so the hue cannot move at all, would
     let all eight in. That is a separate change and a real design question:
     it trades a hard readability floor for a soft one.

   - The scheme's own text does not clear the receding floor: apprentice, at
     under 3.0 between its foreground and its background. masc dims text to
     make it recede, and there is nothing below that to dim to.

   - Two keeper action colours collapse into each other for a reader with
     deuteranopia or protanopia: nord-light and oceanicnext at 0.023 apart,
     kanagawa-dragon at 0.022, where the contract wants separation. Worth
     saying plainly, because it is the least obvious of the three: these
     schemes read fine. masc cannot use them because masc spends colour on
     telling actions apart, and for some readers these schemes do not. *)

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
  ; { name = "everforest-dark"
  ; light = false
  ; palette =
      [| "2d353b"; "343f44"; "475258"; "859289"
       ; "9da9a0"; "d3c6aa"; "e6e2cc"; "fdf6e3"
       ; "e67e80"; "e69875"; "dbbc7f"; "a7c080"
       ; "83c092"; "7fbbb3"; "d699b6"; "9da9a0"
      |]
  }
  ; { name = "kanagawa-wave"
  ; light = false
  ; palette =
      [| "1f1f28"; "16161d"; "223249"; "54546d"
       ; "727169"; "dcd7ba"; "c8c093"; "717c7c"
       ; "c34043"; "ffa066"; "c0a36e"; "76946a"
       ; "6a9589"; "7e9cd8"; "957fb8"; "d27e99"
      |]
  }
  ; { name = "rose-pine"
  ; light = false
  ; palette =
      [| "191724"; "1f1d2e"; "26233a"; "6e6a86"
       ; "908caa"; "e0def4"; "e0def4"; "524f67"
       ; "eb6f92"; "f6c177"; "ebbcba"; "31748f"
       ; "9ccfd8"; "c4a7e7"; "f6c177"; "524f67"
      |]
  }
  ; { name = "catppuccin-macchiato"
  ; light = false
  ; palette =
      [| "24273a"; "1e2030"; "363a4f"; "494d64"
       ; "5b6078"; "cad3f5"; "f4dbd6"; "b7bdf8"
       ; "ed8796"; "f5a97f"; "eed49f"; "a6da95"
       ; "8bd5ca"; "8aadf4"; "c6a0f6"; "f0c6c6"
      |]
  }
  ; { name = "gruvbox-light-hard"
  ; light = true
  ; palette =
      [| "f9f5d7"; "ebdbb2"; "d5c4a1"; "bdae93"
       ; "665c54"; "504945"; "3c3836"; "282828"
       ; "9d0006"; "af3a03"; "b57614"; "79740e"
       ; "427b58"; "076678"; "8f3f71"; "d65d0e"
      |]
  }

  ; { name = "papercolor-light"
  ; light = true
  ; palette =
      [| "eeeeee"; "c4c4c4"; "9e9e9e"; "858585"
       ; "6b6b6b"; "5e5e5e"; "525252"; "444444"
       ; "d70000"; "d75f00"; "d75f00"; "008700"
       ; "0087af"; "005f87"; "8700af"; "af0000"
      |]
  }
  ; { name = "one-light"
  ; light = true
  ; palette =
      [| "fafafa"; "f0f0f1"; "e5e5e6"; "a0a1a7"
       ; "696c77"; "383a42"; "202227"; "090a0b"
       ; "ca1243"; "d75f00"; "c18401"; "50a14f"
       ; "0184bc"; "4078f2"; "a626a4"; "986801"
      |]
  }
  ; { name = "ayu-light"
  ; light = true
  ; palette =
      [| "f8f9fa"; "edeff1"; "d2d4d8"; "a0a6ac"
       ; "8A9199"; "5c6166"; "4e5257"; "404447"
       ; "f07171"; "fa8d3e"; "f2ae49"; "6cbf49"
       ; "4cbf99"; "399ee6"; "a37acc"; "e6ba7e"
      |]
  }
  ; { name = "tokyo-night-light"
  ; light = true
  ; palette =
      [| "D5D6DB"; "CBCCD1"; "DFE0E5"; "9699A3"
       ; "4C505E"; "343B59"; "1A1B26"; "1A1B26"
       ; "343B58"; "965027"; "166775"; "485E30"
       ; "3E6968"; "34548A"; "5A4A78"; "8C4351"
      |]
  }
  ; { name = "gruvbox-material-light-medium"
  ; light = true
  ; palette =
      [| "fbf1c7"; "f2e5bc"; "d5c4a1"; "bdae93"
       ; "665c54"; "654735"; "3c3836"; "282828"
       ; "c14a4a"; "c35e0a"; "b47109"; "6c782e"
       ; "4c7a5d"; "45707a"; "945e80"; "e78a4e"
      |]
  }
  ; { name = "ayu-dark"
  ; light = false
  ; palette =
      [| "0b0e14"; "131721"; "202229"; "3e4b59"
       ; "bfbdb6"; "e6e1cf"; "ece8db"; "f2f0e7"
       ; "f07178"; "ff8f40"; "ffb454"; "aad94c"
       ; "95e6cb"; "59c2ff"; "d2a6ff"; "e6b450"
      |]
  }
  ; { name = "ayu-mirage"
  ; light = false
  ; palette =
      [| "1f2430"; "242936"; "323844"; "4A5059"
       ; "707a8c"; "cccac2"; "d9d7ce"; "f3f4f5"
       ; "f28779"; "ffad66"; "ffd173"; "d5ff80"
       ; "95e6cb"; "73d0ff"; "d4bfff"; "f27983"
      |]
  }
  ; { name = "zenburn"
  ; light = false
  ; palette =
      [| "383838"; "404040"; "606060"; "6f6f6f"
       ; "808080"; "dcdccc"; "c0c0c0"; "ffffff"
       ; "dca3a3"; "dfaf8f"; "e0cf9f"; "5f7f5f"
       ; "93e0e3"; "7cb8bb"; "dc8cc3"; "000000"
      |]
  }
  ; { name = "tokyo-night-storm"
  ; light = false
  ; palette =
      [| "24283B"; "16161E"; "343A52"; "444B6A"
       ; "787C99"; "A9B1D6"; "CBCCD1"; "D5D6DB"
       ; "C0CAF5"; "A9B1D6"; "0DB9D7"; "9ECE6A"
       ; "B4F9F8"; "2AC3DE"; "BB9AF7"; "F7768E"
      |]
  }
  ; { name = "catppuccin-frappe"
  ; light = false
  ; palette =
      [| "303446"; "292c3c"; "414559"; "51576d"
       ; "626880"; "c6d0f5"; "f2d5cf"; "babbf1"
       ; "e78284"; "ef9f76"; "e5c890"; "a6d189"
       ; "81c8be"; "8caaee"; "ca9ee6"; "eebebe"
      |]
  }
  ; { name = "rose-pine-moon"
  ; light = false
  ; palette =
      [| "232136"; "2a273f"; "393552"; "6e6a86"
       ; "908caa"; "e0def4"; "e0def4"; "56526e"
       ; "eb6f92"; "f6c177"; "ea9a97"; "3e8fb0"
       ; "9ccfd8"; "c4a7e7"; "f6c177"; "56526e"
      |]
  }
  ; { name = "tomorrow-night"
  ; light = false
  ; palette =
      [| "1d1f21"; "282a2e"; "373b41"; "969896"
       ; "b4b7b4"; "c5c8c6"; "e0e0e0"; "ffffff"
       ; "cc6666"; "de935f"; "f0c674"; "b5bd68"
       ; "8abeb7"; "81a2be"; "b294bb"; "a3685a"
      |]
  }
  ; { name = "selenized-light"
  ; light = true
  ; palette =
      [| "fbf3db"; "ece3cc"; "d5cdb6"; "909995"
       ; "909995"; "53676d"; "3a4d53"; "3a4d53"
       ; "cc1729"; "bc5819"; "a78300"; "428b00"
       ; "00978a"; "006dce"; "825dc0"; "c44392"
      |]
  }
  ; { name = "selenized-white"
  ; light = true
  ; palette =
      [| "ffffff"; "ebebeb"; "cdcdcd"; "878787"
       ; "878787"; "474747"; "282828"; "282828"
       ; "bf0000"; "ba3700"; "af8500"; "008400"
       ; "009a8a"; "0054cf"; "6b40c3"; "dd0f9d"
      |]
  }
  ; { name = "horizon-light"
  ; light = true
  ; palette =
      [| "FDF0ED"; "FADAD1"; "F9CBBE"; "BDB3B1"
       ; "948C8A"; "403C3D"; "302C2D"; "201C1D"
       ; "F7939B"; "F6661E"; "FBE0D9"; "94E1B0"
       ; "DC3318"; "DA103F"; "1D8991"; "E58C92"
      |]
  }
  ; { name = "edge-dark"
  ; light = false
  ; palette =
      [| "262729"; "313235"; "3d3f42"; "4a4c4f"
       ; "95989d"; "afb2b5"; "caccce"; "e4e5e6"
       ; "e77171"; "eba31a"; "dbb774"; "a1bf78"
       ; "5ebaa5"; "73b3e7"; "d390e7"; "5ebaa5"
      |]
  }
  ; { name = "selenized-dark"
  ; light = false
  ; palette =
      [| "103c48"; "184956"; "2d5b69"; "72898f"
       ; "72898f"; "adbcbc"; "cad8d9"; "cad8d9"
       ; "fa5750"; "ed8649"; "dbb32d"; "75b938"
       ; "41c7b9"; "4695f7"; "af88eb"; "f275be"
      |]
  }
  ; { name = "horizon-dark"
  ; light = false
  ; palette =
      [| "1C1E26"; "232530"; "2E303E"; "6F6F70"
       ; "9DA0A2"; "CBCED0"; "DCDFE4"; "E3E6EE"
       ; "E93C58"; "E58D7D"; "EFB993"; "EFAF8E"
       ; "24A8B4"; "DF5273"; "B072D1"; "E4A382"
      |]
  }
  ; { name = "primer-dark-dimmed"
  ; light = false
  ; palette =
      [| "1c2128"; "373e47"; "444c56"; "545d68"
       ; "768390"; "909dab"; "adbac7"; "cdd9e5"
       ; "f47067"; "e0823d"; "c69026"; "57ab5a"
       ; "96d0ff"; "539bf5"; "e275ad"; "ae5622"
      |]
  }
  ; { name = "norton-commander"
  ; light = false
  ; palette =
      [| "000080"; "1a1a94"; "2d2da8"; "8b8bd0"
       ; "b8b8e8"; "ffffff"; "e6f2ff"; "ffffff"
       ; "ff6060"; "ffb266"; "ffe066"; "66ff66"
       ; "66ffff"; "7a7aff"; "e07aff"; "c08040"
      |]
  }
  ; { name = "msx-retro"
  ; light = false
  ; palette =
      [| "1a1a2e"; "24243e"; "32325d"; "4a4a55"
       ; "b4b4c4"; "ffffff"; "f6ecde"; "ffffff"
       ; "ff6b5e"; "f58124"; "ffd23e"; "4fd06a"
       ; "52e9e0"; "6a79ff"; "ff6bd6"; "b979ff"
      |]
  }
  ; { name = "pc-tools-vintage"
  ; light = false
  ; palette =
      [| "0e2424"; "163838"; "225050"; "4a7070"
       ; "a0bcbc"; "e6e6e6"; "f0f4f4"; "ffffff"
       ; "ff6e60"; "f5b04a"; "e8c34a"; "66c866"
       ; "5bc0de"; "5a94e0"; "c472d0"; "cf9a4a"
      |]
  }
  ; { name = "cga-classic"
  ; light = false
  ; palette =
      [| "000000"; "151515"; "2a2a2a"; "555555"
       ; "aaaaaa"; "ffffff"; "d4d4d4"; "ffffff"
       ; "ff5555"; "aa5500"; "ffff55"; "55ff55"
       ; "55ffff"; "6262ff"; "ff55ff"; "aa0000"
      |]
  }
  ; { name = "atelier-heath-light"
  ; light = true
  ; palette =
      [| "f7f3f7"; "d8cad8"; "ab9bab"; "9e8f9e"
       ; "776977"; "695d69"; "292329"; "1b181b"
       ; "ca402b"; "a65926"; "bb8a35"; "918b3b"
       ; "159393"; "516aec"; "7b59c0"; "cc33cc"
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

let clean_hex raw =
  let trimmed = String.trim raw in
  let hex =
    if String.starts_with ~prefix:"#" trimmed then
      String.sub trimmed 1 (String.length trimmed - 1)
    else trimmed
  in
  let hex = String.lowercase_ascii hex in
  if String.length hex <> 6 then None
  else if not (String.for_all (function '0' .. '9' | 'a' .. 'f' -> true | _ -> false) hex) then None
  else
    match hex_pair hex 0, hex_pair hex 2, hex_pair hex 4 with
    | Some _, Some _, Some _ -> Some hex
    | _ -> None
;;

let slot_names =
  [| "base00"; "base01"; "base02"; "base03"
   ; "base04"; "base05"; "base06"; "base07"
   ; "base08"; "base09"; "base0a"; "base0b"
   ; "base0c"; "base0d"; "base0e"; "base0f"
  |]
;;

let find_slot_string doc slot =
  let upper = String.uppercase_ascii slot in
  match Keeper_toml_loader.toml_string_opt doc ("palette." ^ slot) with
  | Some s -> Some s
  | None ->
    match Keeper_toml_loader.toml_string_opt doc ("palette." ^ upper) with
    | Some s -> Some s
    | None ->
      match Keeper_toml_loader.toml_string_opt doc slot with
      | Some s -> Some s
      | None -> Keeper_toml_loader.toml_string_opt doc upper
;;

let of_toml_content ?default_name content =
  match Keeper_toml_loader.parse_toml content with
  | Error msg -> Error ("TOML parse error: " ^ msg)
  | Ok doc ->
    let name_opt =
      match Keeper_toml_loader.toml_string_opt doc "name" with
      | Some n when String.trim n <> "" -> Some (String.trim n)
      | _ -> default_name
    in
    match name_opt with
    | None -> Error "theme name is required"
    | Some name ->
      let light =
        Option.value (Keeper_toml_loader.toml_bool_opt doc "light") ~default:false
      in
      let palette = Array.make 16 "" in
      let rec fill idx =
        if idx = 16 then Ok { name; light; palette }
        else
          let slot = slot_names.(idx) in
          match find_slot_string doc slot with
          | None -> Error (Printf.sprintf "missing slot %s in theme %s" slot name)
          | Some raw ->
            match clean_hex raw with
            | None ->
              Error
                (Printf.sprintf "invalid hex for slot %s in theme %s: %S" slot name raw)
            | Some h ->
              palette.(idx) <- h;
              fill (idx + 1)
      in
      fill 0
;;

let load_file path =
  match Fs_compat.load_file path with
  | exception Sys_error err -> Error err
  | content ->
    let default_name = Filename.remove_extension (Filename.basename path) in
    of_toml_content ~default_name content
;;

let load_dir dir =
  match Sys.readdir dir with
  | exception Sys_error _ -> []
  | entries ->
    Array.to_list entries
    |> List.filter (fun name -> String.ends_with ~suffix:".toml" name)
    |> List.sort String.compare
    |> List.filter_map (fun filename ->
         let path = Filename.concat dir filename in
         match load_file path with
         | Ok scheme -> Some scheme
         | Error _ -> None)
;;

let theme_dirs_for_base base_path =
  let inputs = Config_dir_resolver.inputs_from_env () in
  let resolution =
    Config_dir_resolver.resolve_with { inputs with env_base_path = Some base_path }
  in
  let root = resolution.Config_dir_resolver.config_root.path in
  (* Local root themes take precedence over project config/themes *)
  [ Filename.concat root "themes"
  ; Filename.concat base_path "config/themes"
  ]
;;

let all ?base_path () =
  let base =
    match base_path with
    | Some b -> b
    | None -> Config_dir_resolver.base_path_or_cwd ()
  in
  let dirs = theme_dirs_for_base base in
  let from_files = List.concat_map load_dir dirs in
  (* Deduplicate from_files by name preserving earlier directory priority *)
  let from_files_dedup =
    List.fold_left
      (fun acc s ->
        if List.exists (fun e -> String.equal e.name s.name) acc then acc
        else acc @ [ s ])
      [] from_files
  in
  let file_names = List.map (fun s -> s.name) from_files_dedup in
  let bundled_filtered =
    List.filter (fun s -> not (List.mem s.name file_names)) bundled
  in
  bundled_filtered @ from_files_dedup
;;

let names ?base_path () =
  List.map (fun scheme -> scheme.name) (all ?base_path ())
;;

let find ?base_path name =
  List.find_opt (fun scheme -> String.equal scheme.name name) (all ?base_path ())
;;

let name scheme = scheme.name
let light scheme = scheme.light

