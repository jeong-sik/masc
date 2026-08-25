(* Colour and glyph tokens — see the interface for the contracts. The escape
   strings here moved verbatim from masc_tui_ansi.ml; that module now aliases
   these values, and byte-identical frames are the acceptance test for the
   move. *)

module Terminal_palette = Masc_tui_terminal_palette

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

let blend_component ~toward ~ratio component =
  let source_weight = 1. -. ratio in
  ((float_of_int toward *. ratio)
   +. (float_of_int component *. source_weight))
  |> int_of_float
;;

let user_message_background_rgb background =
  let red = Terminal_palette.red background in
  let green = Terminal_palette.green background in
  let blue = Terminal_palette.blue background in
  let luminance =
    (0.299 *. float_of_int red)
    +. (0.587 *. float_of_int green)
    +. (0.114 *. float_of_int blue)
  in
  let toward, ratio = if luminance > 128. then 0, 0.04 else 255, 0.12 in
  Terminal_palette.make_rgb
    ~red:(blend_component ~toward ~ratio red)
    ~green:(blend_component ~toward ~ratio green)
    ~blue:(blend_component ~toward ~ratio blue)
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

module For_testing = struct
  let colors_enabled = colors_enabled_for_environment
  let user_message_background_rgb = user_message_background_rgb
  let user_message_background = user_message_background_for
end

module Sgr = struct
  let reset = "\027[0m"
  let bold = style "\027[1m"
  let dim = style "\027[2m"
  let underline = style "\027[4m"

  let red = style "\027[31m"
  let green = style "\027[32m"
  let yellow = style "\027[33m"
  let blue = style "\027[34m"
  let magenta = style "\027[35m"
  let cyan = style "\027[36m"
  let white = style "\027[37m"

  let default_fg = style "\027[39m"
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

  let background = projected_background ~colors_enabled

  let bg_removed = style "\027[48;5;52m"
  let bg_added = style "\027[48;5;22m"

  let reverse = "\027[7m"
end

let user_message_background palette =
  user_message_background_for ~colors_enabled
    ~project:Terminal_palette.best_color palette
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
  let l = "\xe2\x94\x9c"
  let r = "\xe2\x94\xa4"
end

type tone = Normal | Dim | Accent

let tone = function
  | Normal -> ""
  | Dim -> Sgr.dim
  | Accent -> Sgr.bright_cyan

type status = Ok | Warn | Bad | Info | Muted

let status = function
  | Ok -> Sgr.bright_green
  | Warn -> Sgr.bright_yellow
  | Bad -> Sgr.bright_red
  | Info -> Sgr.bright_cyan
  | Muted -> Sgr.gray

let selection = Sgr.reverse
let border_focus = Sgr.bright_cyan

module Syntax = struct
  let keyword = Sgr.bright_magenta
  let string_ = Sgr.bright_green

  (* Diff rows are content, like a keyword or a literal: "this line is green"
     says the file gained it, not that anything is healthy. Named here so the
     renderer asks for the reading rather than picking a colour, which is what
     every other content colour already does. *)
  let diff_added_bg = Sgr.bg_added
  let diff_removed_bg = Sgr.bg_removed

  (* The same two answers in the foreground, for a diff drawn inside running
     prose. A background paints the row to its full width, which inside a
     chat fence draws a band across the pane for every changed line. *)
  let diff_added = Sgr.green
  let diff_removed = Sgr.red
end

let strip_sgr text =
  (* Rows carry only SGR sequences (ESC '[' … 'm'); a scanner is enough. *)
  let buf = Buffer.create (String.length text) in
  let length = String.length text in
  let rec go i =
    if i >= length then ()
    else if Char.equal text.[i] '\027' && i + 1 < length
            && Char.equal text.[i + 1] '[' then (
      let j = ref (i + 2) in
      while !j < length && not (Char.equal text.[!j] 'm') do incr j done;
      go (min length (!j + 1)))
    else (
      Buffer.add_char buf text.[i];
      go (i + 1))
  in
  go 0;
  Buffer.contents buf

module Glyph = struct
  let task_done = "\xe2\x97\x8f"
  let task_active = "\xe2\x97\x90"
  let task_todo = "\xe2\x97\x8b"
  let task_cancelled = "\xc3\x97"

  let breadcrumb_sep = "\xe2\x96\xb8"

  let priority p =
    if p <= 1 then "!!!"
    else if p <= 2 then "!!"
    else if p <= 3 then "!"
    else ""
end
