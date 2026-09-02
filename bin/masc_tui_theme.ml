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

(* How far a receded row travels from the terminal's text toward its
   background, and how legible it must stay when it gets there.

   Receded text is still text: blended all the way to the background it is
   gone, not quiet. WCAG asks 3:1 of text that is not the main reading, and
   low-contrast themes have little room to spend -- Solarized Dark starts at
   4.75:1, so a flat two-fifths step lands it at 2.58:1 and turns a quiet row
   into an unreadable one. So two fifths is a ceiling rather than the step,
   and the floor decides what is actually taken.

   The arithmetic is [Masc_tui_color]'s; the two numbers are this module's
   call about how a row should look. *)
let recede_max_ratio = 0.4
let recede_contrast_floor = 3.0

let recede_rgb ~foreground ~background =
  Color.recede_toward ~background ~floor:recede_contrast_floor
    ~max_ratio:recede_max_ratio foreground
;;

let recede_for ~colors_enabled ~dim ~gray ~theme_mode ~project palette =
  if not colors_enabled then ""
  else
    match palette with
    | None -> (
      (* No palette: a multiplexer, or an emulator without the OSC reply. The
         page may still have been reported on its own, and which way it goes
         is the whole question -- SGR 2 blends toward black, so on a light
         terminal the quiet row comes out darker than its neighbours.

         Where the page is known to be light, bright black is the safer
         recede: base16 and its relatives put it a step above the background
         in the ramp, so on a light theme it sits between the text and the
         page rather than past the text. Where the page is dark or unsaid,
         SGR 2 is what every row drew before this and is right on a dark
         one. *)
      match theme_mode with
      | Some Terminal_palette.Light -> gray
      | Some Terminal_palette.Dark | None -> dim)
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

let recede ~theme_mode palette =
  recede_for ~colors_enabled ~dim:Sgr.dim ~gray:Sgr.gray ~theme_mode
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


(* A semantic colour, made readable where the terminal's own palette is not.

   The colours were picked against a dark terminal and are drawn out of the
   reader's palette, so what they come out as is the reader's theme's call.
   Measured across twelve base16 schemes, that call fails often: yellow at
   1.44:1 on default-light, bright black at 1.69:1 on Nord. Neither is a
   dimmer shade of a warning -- they are a warning nobody sees.

   Where the terminal answered OSC 4 and the entry it named does clear the
   floor, the plain SGR code goes out and the theme keeps its choice. Where it
   does not, the same colour is lifted in lightness alone until it does, so a
   red stays a red. Where the terminal said nothing, the plain code goes out,
   which is what this drew before. *)
(* Whether the lift runs at all. Held beside the palette rather than threaded
   through every drawing call, for the same reason the palette is: the answer
   is one reader's setting and every row wants it. *)
let lift_enabled = ref true

let set_lift_enabled value = lift_enabled := value
let lift_is_enabled () = !lift_enabled

let ansi_readable_for ~colors_enabled ~project palette color =
  let code = ansi_color_code color in
  (* Off means the scheme's own colour goes out untouched -- what every other
     terminal UI does, and what a reader on a high-contrast scheme asked for
     by picking one. *)
  if (not colors_enabled) || not !lift_enabled then code
  else
    match palette with
    | None -> code
    | Some palette -> (
      match Terminal_palette.ansi palette (ansi_color_index color) with
      | None -> code
      | Some entry ->
        let background = Terminal_palette.background palette in
        let lifted =
          Color.lift_for_contrast ~background ~floor:status_contrast_floor
            entry
        in
        if lifted = entry then code
        else
          (match project lifted with
           | None -> code
           | Some _ as projected ->
             projected_foreground ~colors_enabled projected))
;;

let status_readable_for ~colors_enabled ~project palette state =
  ansi_readable_for ~colors_enabled ~project palette (status_ansi_color state)
;;

module For_testing = struct
  let colors_enabled = colors_enabled_for_environment
  let user_message_background_rgb = user_message_background_rgb
  let user_message_background = user_message_background_for
  let recede_rgb = recede_rgb
  let recede = recede_for
  let ansi_color_index = ansi_color_index
  let ansi_color_code = ansi_color_code
  let ansi_readable = ansi_readable_for
end

let ansi_readable palette color =
  ansi_readable_for ~colors_enabled ~project:Terminal_palette.best_color
    palette color
;;

let status_readable palette state =
  status_readable_for ~colors_enabled ~project:Terminal_palette.best_color
    palette state
;;

let selection = Sgr.reverse
let border_focus = Sgr.bright_cyan

module Syntax = struct
  let keyword = Sgr.bright_magenta
  let string_ = Sgr.bright_green

  (* A served JSON payload is content the same way a keyword is: "this word is
     yellow" says it is a number, not that anything is healthy. One role per
     thing a reader distinguishes, because a payload drawn in one colour is
     the wall of text the tool tree was built to stop being.

     Keys lead: a reader scanning a nested result is looking for a name, and
     the name is what the eye should land on. Punctuation recedes -- the
     braces and commas are the structure the indentation already shows, and
     drawing them at full weight is what makes a document look like noise. *)
  let json_key = Sgr.bright_cyan
  let json_number = Sgr.bright_yellow
  let json_literal = Sgr.bright_magenta
  let json_punctuation = Sgr.dim

  (* The rest of what a fenced block and a chat row hold. Content, not state:
     a slanted comment says it is a comment, not that anything is unwell. Named
     here for the same reason the keyword is -- a renderer that picks the code
     itself is one the readability lift cannot reach. *)
  let code_comment = Sgr.italic ^ Sgr.gray
  let code_number = Sgr.bright_magenta
  let code_type = Sgr.bright_blue
  let code_span = Sgr.bright_cyan
  let link = Sgr.bright_blue
  let rule = Sgr.gray

  (* Diff rows are content, like a keyword or a literal: "this line is green"
     says the file gained it, not that anything is healthy. Named here so the
     renderer asks for the reading rather than picking a colour, which is what
     every other content colour already does. *)
  let diff_added_bg = Sgr.bg_added
  let diff_removed_bg = Sgr.bg_removed

  (* Both fixed diff backgrounds are dark xterm cube entries. Their row text
     therefore uses the light end of the same fixed palette instead of the
     terminal's default foreground, which may be black on a light theme. *)
  let diff_row_foreground = style "\027[38;5;255m"

  (* The same two answers in the foreground, for compact readings that do not
     paint a whole row. Full-row diff surfaces and chat fences use the
     backgrounds above. *)
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

  (* Only the top priority speaks. The !!!/!!/! ladder made every task list
     shout — on the live Overview five of eight rows carried a red tail —
     and a mark on most rows distinguishes nothing. *)
  let priority p = if p <= 1 then "!" else ""
end
