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

(* How far a receded row travels from the terminal's text toward its
   background, and how legible it must stay when it gets there.

   Receded text is still text: blended all the way to the background it is
   gone, not quiet. WCAG asks 3:1 of text that is not the main reading, and
   low-contrast themes have little room to spend -- Solarized Dark starts at
   4.4:1, so a flat two-fifths step lands it at 2.58:1 and turns a quiet row
   into an unreadable one. So two fifths is a ceiling rather than the step,
   and the floor decides what is actually taken. *)
let recede_max_ratio = 0.4
let recede_contrast_floor = 3.0

(* Bisection depth. Eight halvings of the ratio range settle it inside
   0.4/256, finer than one step of an 8-bit channel. *)
let recede_search_steps = 8

let relative_luminance color =
  let channel value =
    let v = float_of_int value /. 255. in
    if v <= 0.03928 then v /. 12.92 else ((v +. 0.055) /. 1.055) ** 2.4
  in
  (0.2126 *. channel (Terminal_palette.red color))
  +. (0.7152 *. channel (Terminal_palette.green color))
  +. (0.0722 *. channel (Terminal_palette.blue color))
;;

let contrast_ratio a b =
  let x = relative_luminance a and y = relative_luminance b in
  (Float.max x y +. 0.05) /. (Float.min x y +. 0.05)
;;

(* The terminal's own text, stepped toward the terminal's own background.

   SGR 2 is what every row used before this, and it blends toward black. On a
   dark terminal that is a step toward the background and the text recedes,
   which is the point of it. On a light terminal it is a step away: the faint
   row comes out darker than the ordinary rows beside it and the page reads
   upside down (microsoft/terminal#16493). SGR 90 does not rescue it either --
   Solarized and its relatives remap the bright colours onto a grey ramp, so
   what it draws answers to the theme rather than to the background.

   Computing the colour answers to neither. The direction comes from the two
   colours the terminal reported, so it recedes on a light terminal and on a
   dark one without either being a special case, and the distance is the
   largest one that still clears the contrast floor. [None] where even the
   smallest step does not: a theme whose text is already below the floor has
   no room to give away, and saying so is better than returning a colour that
   cannot be read. *)
let recede_rgb ~foreground ~background =
  let blend ratio =
    let channel select =
      blend_component ~toward:(select background) ~ratio (select foreground)
    in
    Terminal_palette.make_rgb
      ~red:(channel Terminal_palette.red)
      ~green:(channel Terminal_palette.green)
      ~blue:(channel Terminal_palette.blue)
  in
  let clears ratio =
    contrast_ratio (blend ratio) background >= recede_contrast_floor
  in
  if clears recede_max_ratio then Some (blend recede_max_ratio)
  else if not (clears 0.) then None
  else
    (* Contrast falls as the step grows, so the largest step that clears the
       floor is where bisection lands. [low] always clears and [high] never
       does, so the answer is [low] whenever the search runs out. *)
    let rec search ~low ~high steps =
      if steps = 0 then blend low
      else
        let mid = (low +. high) /. 2. in
        if clears mid then search ~low:mid ~high (steps - 1)
        else search ~low ~high:mid (steps - 1)
    in
    Some (search ~low:0. ~high:recede_max_ratio recede_search_steps)
;;

let recede_for ~colors_enabled ~dim ~project palette =
  if not colors_enabled then ""
  else
    match palette with
    | None ->
      (* The terminal never answered the palette query -- a multiplexer, or an
         emulator without the reply. SGR 2 is what this drew before, and
         guessing a colour against an unknown background is worse than the
         attribute that at least half the time is right. *)
      dim
    | Some palette ->
      (match
         recede_rgb
           ~foreground:(Terminal_palette.foreground palette)
           ~background:(Terminal_palette.background palette)
       with
       (* No room to recede without dropping under the floor, or a capability
          that cannot carry the colour. Either way SGR 2 is what this drew
          before, so that is what it keeps drawing. *)
       | None -> dim
       | Some blended ->
         (match project blended with
          | None -> dim
          | Some _ as projected ->
            projected_foreground ~colors_enabled projected))
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
  let recede_rgb = recede_rgb
  let recede = recede_for
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

  let background = projected_background ~colors_enabled

  let bg_removed = style "\027[48;5;52m"
  let bg_added = style "\027[48;5;22m"

  let reverse = "\027[7m"
end

let user_message_background palette =
  user_message_background_for ~colors_enabled
    ~project:Terminal_palette.best_color palette
;;

let recede palette =
  recede_for ~colors_enabled ~dim:Sgr.dim ~project:Terminal_palette.best_color
    palette
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
  | Accent -> Sgr.cyan

type status = Ok | Warn | Bad | Info | Muted

let status = function
  | Ok -> Sgr.green
  | Warn -> Sgr.yellow
  | Bad -> Sgr.red
  | Info -> Sgr.cyan
  | Muted -> Sgr.dim

let selection = Sgr.reverse
let border_focus = Sgr.cyan

module Syntax = struct
  let keyword = Sgr.yellow
  let string_ = Sgr.green

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
