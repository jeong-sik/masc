(** TOML palette files for masc-tui themes.

    One file per preset named [<preset_name>.toml] in a themes directory.
    The default directory is [<base-path>/.masc/config/themes/]; [--themes-dir]
    replaces it. A present file overrides the built-in colors key by key
    (a missing key keeps the built-in value); a file that does not parse or
    validates fails as a whole and keeps the built-in palette, with a warning.
    Files are loaded once at startup; editing them needs a restart. *)

val default_dir : base_path:string -> string
(** [\Filename.concat (Filename.concat (masc_dir_from_base_path ~base_path)
    "config") "themes"]. *)

val parse_palette_text :
  preset:Masc_tui_core.Theme.preset -> text:string -> (Masc_tui_core.Theme.Palette.t, string) result
(** Parse one palette file's text and merge it onto [Theme.builtin_palette
    preset]. [Error] names the offending key or the parse failure; unknown
    keys are [Error], never silently ignored. *)

val load_overrides :
  base_path:string -> themes_dir:string option -> string list
(** Read every present preset file in the effective directory and install the
    valid ones with [Theme.set_palette_overrides]. Returns per-file warnings
    (empty when every file is valid or absent). A missing directory or file is
    not a warning. *)

val themes_dir_of_cli : base_path:string -> string option -> string
(** [Option.value ~default:(default_dir ~base_path) themes_dir]. *)
