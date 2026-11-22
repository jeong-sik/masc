module Glyph = Masc_tui_core.Glyph
module Theme = Masc_tui_core.Theme
module Attr = Masc_tui_term.Attr
module Color = Masc_tui_term.Color
module Style = Masc_tui_term.Style

type surface =
  | Canvas
  | Card
  | Elevated
  | Selection

let surface_bg (theme : Theme.t) = function
  | Canvas -> Color.of_rgb theme.surface_0
  | Card -> Color.of_rgb theme.surface_1
  | Elevated -> Color.of_rgb theme.surface_2
  | Selection -> Color.of_rgb theme.selection_bg

let default_bg (theme : Theme.t) bg =
  match bg with Some c -> c | None -> Color.of_rgb theme.surface_1

let anchor ?bg ?(underline = false) (theme : Theme.t) =
  let attrs = if underline then Attr.(bold lor underline) else Attr.bold in
  Style.make ~fg:(Color.of_rgb theme.text_bright) ~bg:(default_bg theme bg) ~attrs ()

let primary ?bg ?(bold = false) (theme : Theme.t) =
  let attrs = if bold then Attr.bold else Attr.none in
  Style.make ~fg:(Color.of_rgb theme.text_primary) ~bg:(default_bg theme bg) ~attrs ()

let structure ?bg ?(bold = false) (theme : Theme.t) =
  let attrs = if bold then Attr.bold else Attr.none in
  Style.make ~fg:(Color.of_rgb theme.text_secondary) ~bg:(default_bg theme bg) ~attrs ()

let whisper ?bg ?(italic = true) (theme : Theme.t) =
  let attrs = if italic then Attr.italic else Attr.none in
  Style.make ~fg:(Color.of_rgb theme.text_muted) ~bg:(default_bg theme bg) ~attrs ()

let style_of_tier ?bg (theme : Theme.t) = function
  | Theme.Tier_anchor -> anchor ?bg theme
  | Theme.Tier_primary -> primary ?bg theme
  | Theme.Tier_structure -> structure ?bg theme
  | Theme.Tier_whisper -> whisper ?bg theme

let status ?bg ?(bold = false) ?(italic = false) (theme : Theme.t) tok =
  let attrs =
    match (bold, italic) with
    | true, true -> Attr.(bold lor italic)
    | true, false -> Attr.bold
    | false, true -> Attr.italic
    | false, false -> Attr.none
  in
  Style.make
    ~fg:(Color.of_rgb (Theme.status_color theme tok))
    ~bg:(default_bg theme bg) ~attrs ()

let accent ?bg ?(bold = false) ?(underline = false) (theme : Theme.t) =
  let attrs =
    match (bold, underline) with
    | true, true -> Attr.(bold lor underline)
    | true, false -> Attr.bold
    | false, true -> Attr.underline
    | false, false -> Attr.none
  in
  Style.make ~fg:(Color.of_rgb theme.accent) ~bg:(default_bg theme bg) ~attrs ()

let ai ?bg ?(bold = false) ?(italic = false) (theme : Theme.t) =
  status ?bg ~bold ~italic theme Theme.Status_ai

let keycap (theme : Theme.t) =
  Style.make
    ~fg:(Color.of_rgb theme.text_bright)
    ~bg:(Color.of_rgb theme.surface_2)
    ~attrs:Attr.bold ()

let keycap_label ?bg (theme : Theme.t) =
  Style.make ~fg:(Color.of_rgb theme.text_muted) ~bg:(default_bg theme bg) ()

let sep_dot = " " ^ Glyph.to_utf8 Glyph.Separator_dot ^ " "
