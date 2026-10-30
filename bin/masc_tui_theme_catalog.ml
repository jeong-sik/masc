(* Reading the shipped schemes, and the slot mapping. See the interface.

   {1 Where the colours are}

   In config/themes, one TOML file per scheme, and nowhere else. They were
   here too until 2026-09-06 -- 41 records in this file beside a smaller set
   of TOML files -- and one kind of thing in two stores cost what that always
   costs. Adding a scheme meant copying sixteen ordered bodies into OCaml by
   hand, which is the transposition warned about below. Leaving it in TOML
   meant the contrast harness measured a scheme no reader could pick, because
   the TOML set loaded from the reader's base path and a live workspace is not
   this repo. norton and norton-commander are what that seam left behind: the
   same scheme, entered twice, under two names.

   {1 Where the colours come from}

   Every body is copied from the scheme's own published base16 form, most of
   them by way of tinted-theming/schemes, which is where their authors put
   them. Who wrote which one, and under what licence, is recorded in
   docs/legal/THIRD-PARTY-THEMES.md; that file is the one to edit when a
   scheme is added, because a file in config/themes without an entry there is
   a scheme masc ships and does not credit.

   The values are fetched rather than typed. A palette entered by hand is a
   palette with a transposition in it, and the sixteen slots are ordered, so a
   swapped pair is a theme that is subtly wrong on one colour -- the hardest
   kind to notice and the easiest kind to introduce. The 41 that moved out of
   this file were moved by a script for that reason, and compared body for
   body afterwards rather than read over.

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

(* The schemes masc ships, read out of the binary rather than written into it.

   They were 41 records in this file until 2026-09-06, and the TOML themes
   under config/themes were a second, smaller set beside them. Two stores for
   one kind of thing, and the seam showed: adding a scheme meant copying its
   sixteen bodies into OCaml by hand, which is the transposition this file's
   header warns about, and a scheme that stayed in TOML was one the contracts
   measured and no reader could pick.

   [Embedded_config] already crunches the whole config/ tree into the binary,
   so config/themes travels with it. That is what makes TOML the only store
   rather than the preferred one: a scheme here needs no base path, and the
   reader's own directories stay what they were, an override rather than the
   only way in.

   A scheme that does not parse is dropped rather than raised on. These are
   masc's own files, so a malformed one is a shipping mistake and not a
   reader's typo -- test_tui_theme_contrast counts them, which is where a
   dropped scheme should be caught, not in a TUI that will not start. *)
let bundled =
  Embedded_config.file_list
  |> List.filter (fun key -> String.starts_with ~prefix:"themes/" key)
  |> List.sort String.compare
  |> List.filter_map (fun key ->
       match Embedded_config.read key with
       | None -> None
       | Some content ->
         let default_name =
           Filename.remove_extension (Filename.basename key)
         in
         (match of_toml_content ~default_name content with
          | Ok scheme -> Some scheme
          | Error _ -> None))
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

