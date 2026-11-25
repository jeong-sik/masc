open Masc_tui_core

let ( let* ) = Result.bind

let default_dir ~base_path =
  Filename.concat
    (Filename.concat (Common.masc_dir_from_base_path ~base_path) "config")
    "themes"

let themes_dir_of_cli ~base_path themes_dir =
  match themes_dir with Some dir -> dir | None -> default_dir ~base_path

let string_value key = function
  | Otoml.TomlString value -> Ok value
  | Otoml.TomlInteger _ | Otoml.TomlFloat _ | Otoml.TomlBoolean _
  | Otoml.TomlOffsetDateTime _ | Otoml.TomlLocalDateTime _ | Otoml.TomlLocalDate _
  | Otoml.TomlLocalTime _ | Otoml.TomlArray _ | Otoml.TomlTable _
  | Otoml.TomlInlineTable _ | Otoml.TomlTableArray _ ->
      Error (Printf.sprintf "%s must be a \"#RRGGBB\" string" key)

let rgb_value key value =
  let* text = string_value key value in
  Result.map_error
    (fun reason -> Printf.sprintf "%s: %s" key reason)
    (Theme.rgb_of_hex text)

let stops_value key = function
  | Otoml.TomlArray [ Otoml.TomlString first; Otoml.TomlString second; Otoml.TomlString third ] ->
      let* c0 = Theme.rgb_of_hex first in
      let* c1 = Theme.rgb_of_hex second in
      let* c2 = Theme.rgb_of_hex third in
      Ok (c0, c1, c2)
  | Otoml.TomlArray _ ->
      Error (Printf.sprintf "%s must hold exactly 3 \"#RRGGBB\" strings" key)
  | Otoml.TomlString _ | Otoml.TomlInteger _ | Otoml.TomlFloat _
  | Otoml.TomlBoolean _ | Otoml.TomlOffsetDateTime _ | Otoml.TomlLocalDateTime _
  | Otoml.TomlLocalDate _ | Otoml.TomlLocalTime _ | Otoml.TomlTable _
  | Otoml.TomlInlineTable _ | Otoml.TomlTableArray _ ->
      Error (Printf.sprintf "%s must hold exactly 3 \"#RRGGBB\" strings" key)

let apply_key palette key value =
  match key with
  | "surface_0" -> Result.map (fun c -> { palette with surface_0 = c }) (rgb_value key value)
  | "surface_1" -> Result.map (fun c -> { palette with surface_1 = c }) (rgb_value key value)
  | "surface_2" -> Result.map (fun c -> { palette with surface_2 = c }) (rgb_value key value)
  | "border_subtle" -> Result.map (fun c -> { palette with border_subtle = c }) (rgb_value key value)
  | "border_inactive" -> Result.map (fun c -> { palette with border_inactive = c }) (rgb_value key value)
  | "border_focused" -> Result.map (fun c -> { palette with border_focused = c }) (rgb_value key value)
  | "text_bright" -> Result.map (fun c -> { palette with text_bright = c }) (rgb_value key value)
  | "text_primary" -> Result.map (fun c -> { palette with text_primary = c }) (rgb_value key value)
  | "text_secondary" -> Result.map (fun c -> { palette with text_secondary = c }) (rgb_value key value)
  | "text_muted" -> Result.map (fun c -> { palette with text_muted = c }) (rgb_value key value)
  | "status_ok" -> Result.map (fun c -> { palette with status_ok = c }) (rgb_value key value)
  | "status_active" -> Result.map (fun c -> { palette with status_active = c }) (rgb_value key value)
  | "status_attention" -> Result.map (fun c -> { palette with status_attention = c }) (rgb_value key value)
  | "status_critical" -> Result.map (fun c -> { palette with status_critical = c }) (rgb_value key value)
  | "status_ai" -> Result.map (fun c -> { palette with status_ai = c }) (rgb_value key value)
  | "status_historical" -> Result.map (fun c -> { palette with status_historical = c }) (rgb_value key value)
  | "accent" -> Result.map (fun c -> { palette with accent = c }) (rgb_value key value)
  | "selection_bg" -> Result.map (fun c -> { palette with selection_bg = c }) (rgb_value key value)
  | "selection_fg" -> Result.map (fun c -> { palette with selection_fg = c }) (rgb_value key value)
  | "cool_stops" -> Result.map (fun s -> { palette with cool_stops = s }) (stops_value key value)
  | "warm_stops" -> Result.map (fun s -> { palette with warm_stops = s }) (stops_value key value)
  | "ai_stops" -> Result.map (fun s -> { palette with ai_stops = s }) (stops_value key value)
  | other -> Error (Printf.sprintf "unknown key %S" other)

let palette_of_toml ~preset document =
  match document with
  | Otoml.TomlTable fields | Otoml.TomlInlineTable fields ->
      List.fold_left
        (fun acc (key, value) ->
          let* palette = acc in
          apply_key palette key value)
        (Ok (Theme.builtin_palette preset))
        fields
  | Otoml.TomlString _ | Otoml.TomlInteger _ | Otoml.TomlFloat _ | Otoml.TomlBoolean _
  | Otoml.TomlOffsetDateTime _ | Otoml.TomlLocalDateTime _ | Otoml.TomlLocalDate _
  | Otoml.TomlLocalTime _ | Otoml.TomlArray _ | Otoml.TomlTableArray _ ->
      Error "expected a flat TOML table of colors"

let parse_palette_text ~preset ~text =
  match Otoml.Parser.from_string_result text with
  | Error detail -> Error detail
  | Ok document -> palette_of_toml ~preset document

let load_overrides ~base_path ~themes_dir =
  let dir = themes_dir_of_cli ~base_path themes_dir in
  let overrides = ref [] in
  let warnings = ref [] in
  List.iter
    (fun preset ->
      let path = Filename.concat dir (Theme.preset_name preset ^ ".toml") in
      if Sys.file_exists path then
        (match Otoml.Parser.from_file path with
        | exception (Eio.Cancel.Cancelled _ as ex) -> raise ex
        | exception Otoml.Parse_error (_, msg) ->
            warnings := Printf.sprintf "%s: %s (kept built-in)" path msg :: !warnings
        | exception Sys_error msg ->
            warnings := Printf.sprintf "%s: %s (kept built-in)" path msg :: !warnings
        | document -> (
            match palette_of_toml ~preset document with
            | Ok palette -> overrides := (preset, palette) :: !overrides
            | Error reason ->
                warnings := Printf.sprintf "%s: %s (kept built-in)" path reason :: !warnings)))
    Theme.all_presets;
  Theme.set_palette_overrides (List.rev !overrides);
  List.rev !warnings
