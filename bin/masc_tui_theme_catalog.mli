(** The schemes masc ships with, and the mapping that turns one into a
    palette.

    masc normally draws out of the terminal's own colours and only lifts what
    cannot be read. A reader who wants a different set of colours than their
    terminal's has nowhere to say so, and pointing them at a directory they
    have to fill first means the picker is empty the first time it opens.

    So masc bundles this measured catalog. Its entries are real base16 schemes
    from tinted-theming/schemes (MIT), the same ones the contrast harness
    measures. What ships is therefore what was measured, not palettes masc
    invented. *)

type t

val bundled : t list
(** Everything under [config/themes/], read out of the binary that
    {!Embedded_config} crunched the tree into. Ordered by filename.

    "Bundled" is now about where a scheme travels, not how it is written:
    these are the same TOML files a reader can put beside them, shipped rather
    than found. A scheme that fails to parse is absent rather than raised on,
    which is a shipping mistake and is counted in test_tui_theme_contrast. *)

val of_toml_content : ?default_name:string -> string -> (t, string) result
(** Parse a TOML string defining a base16 theme into a scheme [t].
    Requires [name] (or uses [default_name]) and 16 hex colors for slots [base00]
    through [base0f] under [[palette]] or at the top level. *)

val load_file : string -> (t, string) result
(** Load a theme from a single TOML file. *)

val all : ?base_path:string -> unit -> t list
(** Every scheme a reader can pick: the shipped ones plus any [.toml] found
    under [<base-path>/config/themes/] or [<base-path>/.masc/config/themes/].
    A found scheme wins over a shipped one of the same name, so a reader can
    replace a scheme masc ships without editing it. *)

val names : ?base_path:string -> unit -> string list
val find : ?base_path:string -> string -> t option
val name : t -> string

val light : t -> bool
(** What the scheme says about itself. Not a measurement -- for that, ask
    {!Masc_tui_color.is_light} about the background {!to_palette} produces. *)

val to_palette : t -> Masc_tui_terminal_palette.t option
(** The scheme as a palette, so a chosen theme reaches every colour by the
    same road a terminal's answer does. [None] only where a scheme's own hex
    is malformed, which for a shipped one would be a typo in its TOML. *)

