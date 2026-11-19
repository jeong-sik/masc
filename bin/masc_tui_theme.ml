(* Colour and glyph tokens — see the interface for the contracts. The escape
   strings here moved verbatim from masc_tui_ansi.ml; that module now aliases
   these values, and byte-identical frames are the acceptance test for the
   move. *)

module Terminal_palette = Masc_tui_terminal_palette
module Color = Masc_tui_color

let colors_enabled_for_environment ~force_color ~no_color =
  match force_color with
  | Some "1" -> true
  | Some _ | None ->
    (match no_color with
     | Some value when String.length value > 0 -> false
     | Some _ | None -> true)

let colors_enabled =
  colors_enabled_for_environment
    ~force_color:(Sys.getenv_opt "MASC_TUI_FORCE_COLOR")
    ~no_color:(Sys.getenv_opt "NO_COLOR")

let style_for ~colors_enabled code = if colors_enabled then code else ""
let style code = style_for ~colors_enabled code

let projected_background ~colors_enabled = function
  | Some projected ->
    Terminal_palette.fold_projected_color
      ~rgb:(fun color ->
        style_for ~colors_enabled
          (Printf.sprintf "\027[48;2;%d;%d;%dm"
             (Terminal_palette.red color)
             (Terminal_palette.green color)
             (Terminal_palette.blue color)))
      ~indexed:(fun index ->
        style_for ~colors_enabled (Printf.sprintf "\027[48;5;%dm" index))
      projected
  | None -> ""
;;

let projected_foreground ~colors_enabled = function
  | Some projected ->
    Terminal_palette.fold_projected_color
      ~rgb:(fun color ->
        style_for ~colors_enabled
          (Printf.sprintf "\027[38;2;%d;%d;%dm"
             (Terminal_palette.red color)
             (Terminal_palette.green color)
             (Terminal_palette.blue color)))
      ~indexed:(fun index ->
        style_for ~colors_enabled (Printf.sprintf "\027[38;5;%dm" index))
      projected
  | None -> ""
;;

let blend_component ~toward ~ratio component =
  let source_weight = 1. -. ratio in
  ((float_of_int toward *. ratio)
   +. (float_of_int component *. source_weight))
  |> int_of_float
;;

(* Secondary information is still normal-size text. WCAG 2.2 SC 1.4.3
   uses 4.5:1; the 3:1 exception is for large text, not secondary text.
   Blend only as far as this floor allows, then check the projection estimate
   because quantization can lower contrast. Indexed RGB is not observed. *)
let recede_max_ratio = 0.4
let recede_contrast_floor = 4.5

let recede_rgb ~foreground ~background =
  Color.recede_toward ~background ~floor:recede_contrast_floor
    ~max_ratio:recede_max_ratio foreground
;;

(* Non-text structural hairlines (unfocused card borders, overlay frames,
   horizontal rules) sit behind secondary text so content leads the eye. *)
let border_muted_max_ratio = 0.72
let border_muted_contrast_floor = 2.2

let border_muted_rgb ~foreground ~background =
  Color.recede_toward ~background ~floor:border_muted_contrast_floor
    ~max_ratio:border_muted_max_ratio foreground
;;

(* How far the reader's own row is set apart from the page behind it. A light
   page darkens by a little and a dark page lightens by more, because the same
   step reads as less against a dark ground. *)
let user_row_light_ratio = 0.04
let user_row_dark_ratio = 0.12

let user_message_background_rgb background =
  let toward, ratio =
    if Color.is_light background then 0, user_row_light_ratio
    else 255, user_row_dark_ratio
  in
  let component select =
    blend_component ~toward ~ratio (select background)
  in
  Terminal_palette.make_rgb
    ~red:(component Terminal_palette.red)
    ~green:(component Terminal_palette.green)
    ~blue:(component Terminal_palette.blue)
;;

type surface = Page | Side_pane

(* The ground a colour is measured against is the ground it is drawn on. A
   side pane sits one step off the page -- the step [side_pane_background]
   paints -- and a colour lifted to clear the page by a hair falls under the
   floor on that ground. *)
let surface_background surface palette =
  let page = Terminal_palette.background palette in
  match surface with
  | Page -> page
  | Side_pane -> user_message_background_rgb page
;;

let recede_for ~colors_enabled ~default_foreground ~project ~surface palette =
  if not colors_enabled then ""
  else
    match palette with
    | None -> default_foreground
    | Some palette ->
      let background = surface_background surface palette in
      match recede_rgb ~foreground:(Terminal_palette.foreground palette)
              ~background with
      | None -> default_foreground
      | Some blended ->
        match project blended with
        | None -> default_foreground
        | Some projected ->
          if Color.contrast_ratio
               (Terminal_palette.estimated_rgb projected) background
             >= recede_contrast_floor
          then projected_foreground ~colors_enabled (Some projected)
          else default_foreground
;;

let border_muted_for ~colors_enabled ~default_foreground ~project ~surface
    palette =
  if not colors_enabled then ""
  else
    match palette with
    | None -> default_foreground
    | Some pal ->
      let background = surface_background surface pal in
      let fallback () =
        recede_for ~colors_enabled ~default_foreground ~project ~surface
          palette
      in
      (match
         border_muted_rgb ~foreground:(Terminal_palette.foreground pal)
           ~background
       with
       | None -> fallback ()
       | Some blended ->
         (match project blended with
          | Some projected ->
            (match Terminal_palette.direct_rgb projected with
             | Some rgb
               when Color.contrast_ratio rgb background
                    >= border_muted_contrast_floor ->
               projected_foreground ~colors_enabled (Some projected)
             | Some _ | None -> fallback ())
          | None -> fallback ()))
;;

let user_message_background_for ~colors_enabled ~project palette =
  if not colors_enabled then ""
  else
    match palette with
    | Some palette ->
      palette
      |> Terminal_palette.background
      |> user_message_background_rgb
      |> project
      |> projected_background ~colors_enabled
    | None -> ""
;;

module Sgr = struct
  let reset = "\027[0m"
  let bold = style "\027[1m"
  let dim = style "\027[2m"
  let underline = style "\027[4m"
  let no_underline = style "\027[24m"

  (* Weight is not the only axis a terminal has, and drawing every distinction
     as a colour is what makes a screen loud without making it legible.
     Emphasis slants, a withdrawn reading is struck. Both close to their own
     off-code rather than to a full reset, so a span inside a coloured row
     leaves the row's colour where it was. *)
  let italic = style "\027[3m"
  let no_italic = style "\027[23m"
  let strike = style "\027[9m"
  let no_strike = style "\027[29m"

  let black = style "\027[30m"
  let red = style "\027[31m"
  let green = style "\027[32m"
  let yellow = style "\027[33m"
  let blue = style "\027[34m"
  let magenta = style "\027[35m"
  let cyan = style "\027[36m"
  let white = style "\027[37m"

  let default_fg = style "\027[39m"
  let default_bg = style "\027[49m"
  let gray = style "\027[90m"

  (* Terminal-native bright slots keep the user's own light/dark palette in
     charge. Modern terminal themes such as Catppuccin deliberately map these
     slots to the more saturated semantic variants; fixed RGB here would look
     good only against the background it was designed on. *)
  let bright_red = style "\027[91m"
  let bright_green = style "\027[92m"
  let bright_yellow = style "\027[93m"
  let bright_blue = style "\027[94m"
  let bright_magenta = style "\027[95m"
  let bright_cyan = style "\027[96m"
  let bright_white = style "\027[97m"

  let background = projected_background ~colors_enabled
  let foreground = projected_foreground ~colors_enabled

  (* Pixels, not theme. An image mosaic and a link preview swatch carry colour
     that came from the picture, so there is no palette to project it through
     -- but the escape bytes are still this module's to write, and the colour
     capability still decides whether they are written at all. *)
  let truecolor_foreground ~r ~g ~b =
    style (Printf.sprintf "\027[38;2;%d;%d;%dm" r g b)
  ;;

  let truecolor_background ~r ~g ~b =
    style (Printf.sprintf "\027[48;2;%d;%d;%dm" r g b)
  ;;

  let bg_removed = style "\027[48;5;52m"
  let bg_added = style "\027[48;5;22m"

  let reverse = "\027[7m"
end

let user_message_background palette =
  user_message_background_for ~colors_enabled
    ~project:Terminal_palette.best_color palette
;;

(* One distance off the page for everything that sits apart from it. A pane
   receding by a different amount than the reader's own rows would put three
   greys on one screen and ask the eye to rank them. The ground painted here
   and the ground a side-pane colour is measured against are both
   [surface_background Side_pane], so the two cannot part. *)
let side_pane_background_for ~colors_enabled ~project palette =
  if not colors_enabled then ""
  else
    match palette with
    | Some palette ->
      surface_background Side_pane palette
      |> project
      |> projected_background ~colors_enabled
    | None -> ""
;;

let side_pane_background palette =
  side_pane_background_for ~colors_enabled
    ~project:Terminal_palette.best_color palette
;;

let recede ~surface palette =
  recede_for ~colors_enabled ~default_foreground:Sgr.default_fg
    ~project:Terminal_palette.best_color ~surface palette
;;

let border_muted ~surface palette =
  border_muted_for ~colors_enabled ~default_foreground:Sgr.default_fg
    ~project:Terminal_palette.best_color ~surface palette
;;

module Term = struct
  let clear = "\027[2J\027[H"
  let hide_cursor = "\027[?25l"
  let show_cursor = "\027[?25h"
  let move_to row col = Printf.sprintf "\027[%d;%dH" row col
end

module Box = struct
  let h = "\xe2\x94\x80"
  let v = "\xe2\x94\x82"
  let tl = "\xe2\x94\x8c"
  let tr = "\xe2\x94\x90"
  let bl = "\xe2\x94\x94"
  let br = "\xe2\x94\x98"
  let tl_round = "\xe2\x95\xad"
  let tr_round = "\xe2\x95\xae"
  let bl_round = "\xe2\x95\xb0"
  let br_round = "\xe2\x95\xaf"
  let h_heavy = "\xe2\x94\x81" (* U+2501 HEAVY HORIZONTAL *)
  let v_heavy = "\xe2\x94\x83" (* U+2503 HEAVY VERTICAL *)
  let tl_heavy = "\xe2\x94\x8f" (* U+250F HEAVY DOWN AND RIGHT *)
  let tr_heavy = "\xe2\x94\x93" (* U+2513 HEAVY DOWN AND LEFT *)
  let bl_heavy = "\xe2\x94\x97" (* U+2517 HEAVY UP AND RIGHT *)
  let br_heavy = "\xe2\x94\x9b" (* U+251B HEAVY UP AND LEFT *)
  let scroll_up = "\xe2\x86\x91" (* U+2191 UPWARDS ARROW *)
  let scroll_down = "\xe2\x86\x93" (* U+2193 DOWNWARDS ARROW *)
  let scroll_thumb = "\xe2\x96\x88" (* U+2588 FULL BLOCK *)
  let l = "\xe2\x94\x9c"
  let r = "\xe2\x94\xa4"
end

type status = Ok | Warn | Bad | Info | Muted

type color_depth = No_color | Colors_16 | Colors_256 | Truecolor

type limit_band = Near_zero | Midway | Near_limit

type meter_cell_colour =
  | Cell_plain
  | Cell_band of limit_band
  | Cell_blend of { band : limit_band; position : float }

type paint = {
  depth : color_depth;
  surface : surface;
  palette : Terminal_palette.t option;
}

let status = function
  | Ok -> Sgr.bright_green
  | Warn -> Sgr.bright_yellow
  | Bad -> Sgr.bright_red
  | Info -> Sgr.bright_cyan
  | Muted -> Sgr.gray

(* What a status colour has to clear against the page to be read as text.
   WCAG 2 AA for body text. *)
let status_contrast_floor = 4.5

(* The ANSI colours masc names, and the palette entry each one is. Only the
   ones something actually draws through: a colour with no name here is a
   colour nothing reads a meaning out of. *)
type ansi_color =
  | Bright_red
  | Bright_green
  | Bright_yellow
  | Bright_blue
  | Bright_magenta
  | Bright_cyan
  | Bright_black

let ansi_color_index = function
  | Bright_red -> 9
  | Bright_green -> 10
  | Bright_yellow -> 11
  | Bright_blue -> 12
  | Bright_magenta -> 13
  | Bright_cyan -> 14
  | Bright_black -> 8

let ansi_color_code = function
  | Bright_red -> Sgr.bright_red
  | Bright_green -> Sgr.bright_green
  | Bright_yellow -> Sgr.bright_yellow
  | Bright_blue -> Sgr.bright_blue
  | Bright_magenta -> Sgr.bright_magenta
  | Bright_cyan -> Sgr.bright_cyan
  | Bright_black -> Sgr.gray

(* Which colour each status names. The SGR code and the palette index come
   from the same choice, so a reading of state can be checked against the
   theme it lands on. *)
let status_ansi_color = function
  | Ok -> Bright_green
  | Warn -> Bright_yellow
  | Bad -> Bright_red
  | Info -> Bright_cyan
  | Muted -> Bright_black


(* A semantic colour, adjusted toward readability against the palette.

   The colours were picked against a dark terminal and are drawn out of the
   reader's palette, so what they come out as is the reader's theme's call.
   Measured across twelve base16 schemes, that call fails often: yellow at
   1.44:1 on default-light, bright black at 1.69:1 on Nord. Neither is a
   dimmer shade of a warning -- they are a warning nobody sees.

   An entry above the floor keeps its plain SGR code. Otherwise the colour is
   lifted toward the floor before projection. An indexed projection is only
   estimated from xterm defaults; a selected theme may also be unapplied by
   the terminal. The fallback policies keep the requested ANSI code for
   colour-only distinctions or use the foreground for self-describing text. *)
(* Whether the lift runs at all. Held beside the palette rather than threaded
   through every drawing call, for the same reason the palette is: the answer
   is one reader's setting and every row wants it. *)
let lift_enabled = ref true

let set_lift_enabled value = lift_enabled := value
let lift_is_enabled () = !lift_enabled

type contrast_fallback = Keep_ansi | Default_foreground

let ansi_readable_with_fallback ~fallback ~colors_enabled ~project ~surface
    palette color =
  let code = ansi_color_code color in
  let fallback_code () =
    match fallback with
    | Keep_ansi -> code
    | Default_foreground -> style_for ~colors_enabled "\027[39m"
  in
  let acceptable color background =
    match fallback with
    | Keep_ansi -> true
    | Default_foreground ->
      Color.contrast_ratio color background >= status_contrast_floor
  in
  let acceptable_projection projected background =
    match fallback with
    | Keep_ansi -> true
    | Default_foreground ->
      (match Terminal_palette.direct_rgb projected with
       | Some color -> acceptable color background
       | None -> false)
  in
  (* Off means the scheme's own colour goes out untouched -- what every other
     terminal UI does, and what a reader on a high-contrast scheme asked for
     by picking one. *)
  if not colors_enabled then ""
  else if not !lift_enabled then code
  else
    match palette with
    | None -> fallback_code ()
    | Some palette -> (
      match Terminal_palette.ansi palette (ansi_color_index color) with
      | None -> fallback_code ()
      | Some entry ->
        let background = surface_background surface palette in
        let lifted =
          Color.lift_for_contrast ~background ~floor:status_contrast_floor
            entry
        in
        if lifted = entry then
          if acceptable entry background then code else fallback_code ()
        else
          (match project lifted with
           | None -> fallback_code ()
           | Some projected ->
             if acceptable_projection projected background
             then projected_foreground ~colors_enabled (Some projected)
             else fallback_code ()))
;;

let ansi_readable_for ~colors_enabled ~project ~surface palette color =
  ansi_readable_with_fallback ~fallback:Keep_ansi ~colors_enabled ~project
    ~surface palette color
;;

let status_readable_for ~colors_enabled ~project ~surface palette state =
  ansi_readable_for ~colors_enabled ~project ~surface palette
    (status_ansi_color state)
;;

(* For labels whose words already identify the state, use the terminal's own
   foreground when the colour is unknown or cannot be verified. That
   foreground can itself be low-contrast. Colour-only distinctions continue to
   use [status_readable_for]. *)
let status_text_readable_for ~colors_enabled ~project ~surface palette state =
  ansi_readable_with_fallback ~fallback:Default_foreground ~colors_enabled
    ~project ~surface palette (status_ansi_color state)
;;

let color_depth () =
  if not colors_enabled then No_color
  else
    match Terminal_palette.stdout_color_level () with
    | Terminal_palette.True_color -> Truecolor
    | Terminal_palette.Ansi256 -> Colors_256
    | Terminal_palette.Ansi16 | Terminal_palette.Unknown -> Colors_16
;;

let limit_band_status = function
  | Near_zero -> Ok
  | Midway -> Warn
  | Near_limit -> Bad
;;

(* Whether [part / whole] is under one half, and under four fifths, for
   [0 <= part <= whole]. In integers, so a share exactly on an edge lands on
   the same side at every width, and rearranged so no product overflows:
   2p < w is p < w - p, and 5p < 4w is 4 (w - p) > p, which for integers is
   w - p > p / 4. *)
let under_half ~part ~whole = part < whole - part
let under_four_fifths ~part ~whole = whole - part > part / 4

(* A cell reaches the far edge of its span, (index + 1) / width of the limit,
   unless the value stops short of that edge: a bar rounds a small value up to
   one cell, and a partial glyph draws a cell the value only enters. So the
   cell reaches the smaller of its edge and [value / limit], and the bar's
   last cell takes the band of the value it draws, never a band past it. The
   edges between bands are the sixteen-colour steps of RFC
   tui-one-screen-grammar section 7.3: under one half is near zero, under four
   fifths is midway. A smaller of two shares is under an edge exactly when
   either share is. *)
let limit_cell_colour ~depth ~index ~width ~value ~limit =
  let width = max 1 width in
  let edge = max 1 (min width (index + 1)) in
  let limit = max 1 limit in
  let value = max 0 (min limit value) in
  let under test = test ~part:edge ~whole:width || test ~part:value ~whole:limit in
  let band =
    if under under_half then Near_zero
    else if under under_four_fifths then Midway
    else Near_limit
  in
  match depth with
  | No_color -> Cell_plain
  | Colors_16 -> Cell_band band
  | Colors_256 | Truecolor ->
    let share part whole = float_of_int part /. float_of_int whole in
    Cell_blend
      { band; position = Float.min (share edge width) (share value limit) }
;;

(* A blended cell walks success -> warning over the first half of the limit
   and warning -> danger over the second, in Oklab, lifted to clear the floor
   against the ground it is drawn on. Where the blend cannot be drawn -- no
   palette to read the three colours from, lifting turned off, a projection
   that misses the floor -- the cell draws its band's own colour, which is
   what a sixteen-colour terminal draws for the same cell. *)
let meter_cell_readable_for ~colors_enabled ~project paint cell =
  let band_colour band =
    status_readable_for ~colors_enabled ~project ~surface:paint.surface
      paint.palette (limit_band_status band)
  in
  match cell with
  | Cell_plain -> ""
  | Cell_band band -> band_colour band
  | Cell_blend { band; position } ->
    (match paint.palette with
     | Some palette
       when colors_enabled && !lift_enabled && not (Float.is_nan position) ->
       let position = Float.max 0. (Float.min 1. position) in
       let left, right, segment =
         if position <= 0.5 then Near_zero, Midway, position *. 2.
         else Midway, Near_limit, (position -. 0.5) *. 2.
       in
       let entry band =
         Terminal_palette.ansi palette
           (ansi_color_index (status_ansi_color (limit_band_status band)))
       in
       (match entry left, entry right with
        | Some left_rgb, Some right_rgb ->
          let background = surface_background paint.surface palette in
          let blended =
            Color.lerp_oklab ~background ~floor:status_contrast_floor
              ~t:segment left_rgb right_rgb
          in
          (match project blended with
           | Some projected
             when Color.contrast_ratio
                    (Terminal_palette.estimated_rgb projected)
                    background
                  >= status_contrast_floor ->
             projected_foreground ~colors_enabled (Some projected)
           | Some _ | None -> band_colour band)
        | None, _ | _, None -> band_colour band)
     | Some _ | None -> band_colour band)
;;

(* Picture ramps (RFC tui-one-screen-grammar section 7.3). btop paints every
   box with a gradient: a meter's cells by their place along the bar, a
   graph's rows by their height. A declared limit keeps the status colours of
   [limit_cell_colour]; every other picture walks one hue from deep to bright,
   one hue per quantity, the way btop's memory and network boxes do. *)
type series =
  | Calls
  | Failures
  | Latency
  | Memory
  | Completion
  | Capacity
  | Backlog
  | Usage
  | Wakes

type hue = Green | Yellow | Blue | Magenta

(* One place says which hue a quantity draws in. Red is left to status.danger
   and Cyan is left to status.info (in-progress and focus, RFC §7.3), so no
   picture series collides with active/focus or danger tokens. Latency and
   backlog share yellow because both are waiting. *)
let series_hue = function
  | Calls -> Blue
  | Failures -> Magenta
  | Latency -> Yellow
  | Memory -> Magenta
  | Completion -> Green
  | Capacity -> Blue
  | Backlog -> Yellow
  | Usage -> Blue
  | Wakes -> Green
;;

(* The bright palette entry of each hue, the top of its ramp. *)
let bright_index = function
  | Green -> 10
  | Yellow -> 11
  | Blue -> 12
  | Magenta -> 13
;;

let bright_code = function
  | Green -> Sgr.bright_green
  | Yellow -> Sgr.bright_yellow
  | Blue -> Sgr.bright_blue
  | Magenta -> Sgr.bright_magenta
;;

let ramp_steps = 100

(* A dot or a bar cell is a graphical object, so the deep end of a series
   clears WCAG 2's 3:1 for non-text contrast, and the bright end the 4.5:1 text
   gets. Every hue then spans at least that band: a palette blue at 3.5:1 on a
   dark ground would otherwise leave a ramp too short to see. btop's own deep
   stops go down to about 1.5:1, which a Braille dot does not survive. *)
let picture_contrast_floor = 3.0

(* How far toward the ground the deep end of a series steps before the floor
   stops it. *)
let series_deep_ratio = 0.6

(* The table entry a position reads: the step at or below it, so a cell never
   takes a colour from past the reach it draws. *)
let step_index position =
  let position =
    if Float.is_nan position then 0.0 else Float.max 0.0 (Float.min 1.0 position)
  in
  int_of_float (Float.floor (position *. float_of_int ramp_steps))
;;

(* Every step of one hue's ramp blended in Oklab, or [None] where the ramp
   cannot be drawn whole: no palette, lifting off, a depth without blends, or
   one step whose projection misses the floor. A ramp is blended whole or not
   at all, so a 256-colour terminal never mixes a palette code into a run of
   cube codes. *)
let series_blends ~colors_enabled ~project paint hue =
  match paint.depth, paint.palette with
  | (Colors_256 | Truecolor), Some palette when colors_enabled && !lift_enabled -> (
    match Terminal_palette.ansi palette (bright_index hue) with
    | None -> None
    | Some bright ->
      let background = surface_background paint.surface palette in
      let top = Color.lift_for_contrast ~background ~floor:status_contrast_floor bright in
      let deep =
        match
          Color.recede_toward ~background ~floor:picture_contrast_floor
            ~max_ratio:series_deep_ratio top
        with
        | Some deep -> deep
        | None -> top
      in
      let step index =
        let blended =
          Color.lerp_oklab ~background ~floor:picture_contrast_floor
            ~t:(float_of_int index /. float_of_int ramp_steps)
            deep top
        in
        match project blended with
        | Some projected ->
          let contrast =
            Color.contrast_ratio (Terminal_palette.estimated_rgb projected) background
          in
          if contrast >= picture_contrast_floor then
            Some (projected_foreground ~colors_enabled (Some projected), contrast)
          else None
        | None -> None
      in
      (* Rounding a blend to eight bits a channel can leave a step a hair
         darker than the one before it (cyan 0.10 to 0.11 drops 3.208 to
         3.205 on xterm). A step that would darken keeps the colour before
         it, so the ramp never steps back toward the ground. *)
      let rec collect index (previous_code, previous_contrast) steps =
        if index > ramp_steps then Some (Array.of_list (List.rev steps))
        else
          match step index with
          | None -> None
          | Some (code, contrast) ->
            let kept =
              if contrast < previous_contrast then (previous_code, previous_contrast)
              else (code, contrast)
            in
            collect (index + 1) kept (fst kept :: steps)
      in
      collect 0 ("", 0.0) [])
  | (No_color | Colors_16 | Colors_256 | Truecolor), (Some _ | None) -> None
;;

(* Without a blend the whole ramp is the hue's bright code. base16 schemes
   fill a hue's normal and bright entries with the same colour, so a
   normal-then-bright step would be one colour there anyway, and a normal
   entry is often the unreadable one (xterm's blue is 2.2:1 on black). *)
let series_table ~colors_enabled ~project paint series =
  match paint.depth with
  | No_color -> Array.make (ramp_steps + 1) ""
  | Colors_16 | Colors_256 | Truecolor ->
    let hue = series_hue series in
    (match series_blends ~colors_enabled ~project paint hue with
     | Some table -> table
     | None -> Array.make (ramp_steps + 1) (if colors_enabled then bright_code hue else ""))
;;

let ramp_style_for ~colors_enabled ~project paint series ~position =
  (series_table ~colors_enabled ~project paint series).(step_index position)
;;

(* A ramp's colours for one paint, kept until the palette, depth, ground or
   lift switch changes. A palette is compared by identity: the process palette
   is replaced, never edited, when the terminal answers again. *)
type ramp_key = {
  key_depth : color_depth;
  key_surface : surface;
  key_palette : Terminal_palette.t option;
  key_lift : bool;
  key_series : series;
}

let same_ramp_key left right =
  left.key_depth = right.key_depth
  && left.key_surface = right.key_surface
  && left.key_lift = right.key_lift
  && left.key_series = right.key_series
  && (match left.key_palette, right.key_palette with
      | None, None -> true
      | Some left, Some right -> left == right
      | None, Some _ | Some _, None -> false)
;;

(* Nine series on two grounds is eighteen tables; the rest leaves room for a
   palette change without ever building a table per frame. *)
let ramp_table_capacity = 32

let ramp_tables : (ramp_key * string array) list Atomic.t = Atomic.make []

let ramp_table paint series =
  let key =
    { key_depth = paint.depth;
      key_surface = paint.surface;
      key_palette = paint.palette;
      key_lift = !lift_enabled;
      key_series = series }
  in
  let rec find = function
    | [] -> None
    | (cached, table) :: rest -> if same_ramp_key cached key then Some table else find rest
  in
  match find (Atomic.get ramp_tables) with
  | Some table -> table
  | None ->
    let table =
      series_table ~colors_enabled ~project:Terminal_palette.best_color paint series
    in
    let rec add () =
      let previous = Atomic.get ramp_tables in
      let kept = List.filteri (fun index _ -> index < ramp_table_capacity - 1) previous in
      if not (Atomic.compare_and_set ramp_tables previous ((key, table) :: kept)) then add ()
    in
    add ();
    table
;;

let ramp_reader paint series =
  match paint.depth with
  | No_color -> fun ~position:_ -> ""
  | Colors_16 | Colors_256 | Truecolor ->
    let table = ramp_table paint series in
    fun ~position -> table.(step_index position)
;;

let ramp_style paint series ~position = ramp_reader paint series ~position

type panel_role =
  | Panel_neutral
  | Panel_fleet
  | Panel_usage
  | Panel_memory
  | Panel_attention

let panel_border paint role =
  let border_for series =
    match paint.palette with
    | None -> recede ~surface:paint.surface paint.palette
    | Some _ -> ramp_style paint series ~position:0.0
  in
  match paint.depth, role with
  | No_color, _ -> ""
  | _, Panel_neutral -> recede ~surface:paint.surface paint.palette
  | Colors_16, (Panel_fleet | Panel_usage | Panel_memory | Panel_attention) ->
      recede ~surface:paint.surface paint.palette
  | (Colors_256 | Truecolor), Panel_fleet -> border_for Completion
  | (Colors_256 | Truecolor), Panel_usage -> border_for Usage
  | (Colors_256 | Truecolor), Panel_memory -> border_for Memory
  | (Colors_256 | Truecolor), Panel_attention -> border_for Latency
;;

let selection = Sgr.reverse

(* Accent-tinted Truecolor selection band (lazygit style). Blending the page
   ground toward the scheme's blue/cyan accent produces a calm highlight bar
   instead of a stark reverse-video block, while holding a verified 4.5:1
   foreground over the tinted ground and >= 1.15 separation from the page. *)
let selection_bg_dark_ratio = 0.28
let selection_bg_light_ratio = 0.22
let selection_bg_min_contrast = 1.15
let selection_neutral_max_ratio = 0.24

let blend_rgb ~ratio base target =
  let mix select =
    blend_component ~toward:(select target) ~ratio (select base)
  in
  Terminal_palette.make_rgb
    ~red:(mix Terminal_palette.red)
    ~green:(mix Terminal_palette.green)
    ~blue:(mix Terminal_palette.blue)
;;

let selection_accent_candidates palette =
  List.filter_map
    (fun slot -> Terminal_palette.ansi palette (ansi_color_index slot))
    [ Bright_blue; Bright_cyan ]
;;

let try_selection_pair ~colors_enabled ~project ~foreground bg =
  match project bg with
  | Some bg_proj ->
    (match Terminal_palette.direct_rgb bg_proj with
     | Some bg_rgb ->
       let fg_lifted =
         Color.lift_for_contrast ~background:bg_rgb
           ~floor:status_contrast_floor foreground
       in
       if Color.contrast_ratio fg_lifted bg_rgb >= status_contrast_floor then
         (match project fg_lifted with
          | Some fg_proj ->
            (match Terminal_palette.direct_rgb fg_proj with
             | Some fg_rgb
               when Color.contrast_ratio fg_rgb bg_rgb >= status_contrast_floor ->
               Some
                 (projected_foreground ~colors_enabled (Some fg_proj)
                  ^ projected_background ~colors_enabled (Some bg_proj))
             | Some _ | None -> None)
          | None -> None)
       else None
     | None -> None)
  | None -> None
;;

let selection_style_for ~colors_enabled ~project palette =
  if not colors_enabled then selection
  else
    match palette with
    | None -> selection
    | Some palette ->
      let page = Terminal_palette.background palette in
      let foreground = Terminal_palette.foreground palette in
      let ratio =
        if Color.is_light page then selection_bg_light_ratio
        else selection_bg_dark_ratio
      in
      let try_bg bg =
        if Color.contrast_ratio bg page >= selection_bg_min_contrast then
          try_selection_pair ~colors_enabled ~project ~foreground bg
        else None
      in
      let neutral () =
        match
          Color.recede_toward ~background:foreground
            ~floor:status_contrast_floor ~max_ratio:selection_neutral_max_ratio
            page
        with
        | Some bg -> try_bg bg
        | None -> None
      in
      let accent_attempt =
        List.find_map
          (fun accent -> try_bg (blend_rgb ~ratio page accent))
          (selection_accent_candidates palette)
      in
      (match accent_attempt with
       | Some style -> style
       | None ->
         (match neutral () with
          | Some style -> style
          | None -> selection))
;;
module For_testing = struct
  let colors_enabled = colors_enabled_for_environment
  let user_message_background_rgb = user_message_background_rgb
  let user_message_background = user_message_background_for
  let side_pane_background = side_pane_background_for
  let recede_rgb = recede_rgb
  let recede = recede_for
  let ansi_color_index = ansi_color_index
  let ansi_color_code = ansi_color_code
  let ansi_readable = ansi_readable_for
  let status_text_readable = status_text_readable_for
  let meter_cell_readable = meter_cell_readable_for
  let ramp_style = ramp_style_for
  let selection_style = selection_style_for
  let border_muted_rgb = border_muted_rgb
  let border_muted = border_muted_for
end

let ansi_readable ~surface palette color =
  ansi_readable_for ~colors_enabled ~project:Terminal_palette.best_color
    ~surface palette color
;;

let status_readable ~surface palette state =
  status_readable_for ~colors_enabled ~project:Terminal_palette.best_color
    ~surface palette state
;;

let status_text_readable ~surface palette state =
  status_text_readable_for ~colors_enabled ~project:Terminal_palette.best_color
    ~surface palette state
;;

let meter_cell_readable paint cell =
  meter_cell_readable_for ~colors_enabled ~project:Terminal_palette.best_color
    paint cell
;;

let selection_style palette =
  selection_style_for ~colors_enabled ~project:Terminal_palette.best_color
    palette
;;

let sidebar_selection palette =
  if not colors_enabled then selection
  else match palette with
  | None -> selection
  | Some palette ->
    let foreground = Terminal_palette.foreground palette in
    (* A small neutral step toward the foreground, instead of filling the
       whole selected row with the terminal's bright text colour. *)
    (match Option.bind (Color.recede_toward ~background:foreground
       ~floor:status_contrast_floor ~max_ratio:0.18
       (Terminal_palette.background palette)) Terminal_palette.best_color with
     | None -> selection
     | Some projected -> Sgr.default_fg ^ Sgr.background (Some projected))

module Syntax = struct
  (* What does not take a hue from the palette. The words a reader scans for
     (keyword, string, number, type, link, a JSON key) are hues, and draw
     through [Masc_tui_ansi.Theme.Syntax], which lifts them. Punctuation
     recedes by weight instead, and a diff row pairs a fixed background with
     fixed text. *)
  let json_punctuation = Sgr.dim

  (* Diff rows are content, like a keyword or a literal: "this line is green"
     says the file gained it, not that anything is healthy. Named here so the
     renderer asks for the reading rather than picking a colour, which is what
     every other content colour already does. *)
  let diff_added_bg = Sgr.bg_added
  let diff_removed_bg = Sgr.bg_removed

  (* These indices use dark backgrounds and a light foreground in the default
     xterm palette. The terminal can redefine them; see issue #47482. *)
  let diff_row_foreground = style "\027[38;5;255m"

  (* The same two answers in the foreground, for compact readings that do not
     paint a whole row. Full-row diff surfaces and chat fences use the
     backgrounds above. *)
  let diff_added = Sgr.green
  let diff_removed = Sgr.red
end

let strip_sgr_internal ?on_span text =
  (* Rows carry only SGR sequences (ESC '[' … 'm'). Copy ordinary spans,
     preserving their bytes, and allocate the buffer only after finding an opener. *)
  let length = String.length text in
  let rec next_sgr offset =
    match String.index_from_opt text offset '\027' with
    | Some i when i + 1 < length && Char.equal text.[i + 1] '[' -> Some i
    | Some i -> next_sgr (i + 1)
    | None -> None
  in
  match next_sgr 0 with
  | None -> Option.iter (fun emit -> emit 0 length) on_span; text
  | Some first ->
      let buf = Buffer.create length in
      let rec copy_span start opener =
        Option.iter (fun emit -> emit start (opener-start)) on_span;
        Buffer.add_substring buf text start (opener - start);
        match String.index_from_opt text (opener + 2) 'm' with
        | None -> Buffer.contents buf
        | Some stop ->
            let start = stop + 1 in
            match next_sgr start with
            | Some opener -> copy_span start opener
            | None ->
                Option.iter (fun emit -> emit start (length-start)) on_span;
                Buffer.add_substring buf text start (length - start);
                Buffer.contents buf
      in
      copy_span 0 first

let strip_sgr text = strip_sgr_internal text

let strip_sgr_with_positions text =
  let spans=ref [] in
  let text=strip_sgr_internal ~on_span:(fun start length ->
    spans:=Array.init length (fun i -> start+i) :: !spans) text in
  text, Array.concat (List.rev !spans)

module Glyph = struct
  (* How far a piece of work has got: not started, being worked, finished,
     ended without finishing. A Task row, the Backlog counts and the Goal
     counters above them all read these, so one mark means one stage on the
     Planning screen. The Goal counters spelled their own -- a filled circle
     for Executing over a Backlog row where the filled circle is done. *)
  let progress_waiting = "\xe2\x97\x8b"
  let progress_active = "\xe2\x97\x90"
  let progress_done = "\xe2\x97\x8f"
  let progress_ended = "\xc3\x97"

  (* Which one of a set the reader is on. The surface strip and the keeper
     detail tabs are the two strips a reader walks; the Overview's transport
     tail is the paths the workspace could carry traffic on, with the mark on
     the one that carries it; and a list's marked row is the same question
     asked of rows rather than of tabs.

     Named rather than spelled, because the answer to "which one" is one
     glyph and changing it should be one edit. Sites that draw the mark for
     something else -- a path step in a breadcrumb, a folder in the Code
     tree -- are not this and do not read it. *)
  let current_entry = "\xe2\x96\xb8"

  (* What a field with no value draws, wherever the surface measures in
     display cells. The Keepers roster row and the keeper detail pane read
     the same k_current_task_id, and an absent task drew an em dash in the
     row and a hyphen in the pane one keypress later, so the same nothing
     carried two marks.

     Two kinds of cell keep their own one-byte mark instead. A column padded
     with %-Ns counts bytes, and three bytes in a seven-byte cell end the row
     two columns short -- Masc_tui_model_runtime_table says so where it
     spells its own. And a column whose marks are a one-cell alphabet -- the
     Memory roster's ST column, the fleet row's call figure -- reads its mark
     against + ! s x and ?, not against this. *)
  let no_value = "\xe2\x80\x94"

  (* Only the top priority speaks. The !!!/!!/! ladder made every task list
     shout — on the live Overview five of eight rows carried a red tail —
     and a mark on most rows distinguishes nothing. *)
  let priority p = if p <= 1 then "!" else ""
end
