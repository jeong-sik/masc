(** ANSI escape codes and terminal helpers — split from masc_tui.ml (#3808) *)

(** ANSI escape codes *)
module Ansi = struct
  let clear = "\027[2J\027[H"
  let hide_cursor = "\027[?25l"
  let show_cursor = "\027[?25h"

  (* no-color.org: a non-empty NO_COLOR suppresses styling. Structure --
     borders, markers, reverse-video selection -- stays, because it carries
     meaning colour only repeats. MASC_TUI_FORCE_COLOR=1 overrides for a
     pipeline that strips the variable it wants. *)
  let colors_enabled =
    match Sys.getenv_opt "MASC_TUI_FORCE_COLOR" with
    | Some "1" -> true
    | Some _ | None ->
      (match Sys.getenv_opt "NO_COLOR" with
       | Some value when String.length value > 0 -> false
       | Some _ | None -> true)

  let style code = if colors_enabled then code else ""

  (* Colors. [reset] stays unconditional: reverse-video survives NO_COLOR,
     and this is what closes it. *)
  let reset = "\027[0m"
  let bold = style "\027[1m"
  let dim = style "\027[2m"
  (* A third weight between bold and dim. The renderer had only two, so a
     heading and the paragraph under it could differ by nothing an eye reads
     as rank. *)
  let underline = style "\027[4m"

  let red = style "\027[31m"
  let green = style "\027[32m"
  let yellow = style "\027[33m"
  let blue = style "\027[34m"
  let magenta = style "\027[35m"
  let cyan = style "\027[36m"
  let white = style "\027[37m"

  (* SGR 39 restores the terminal's own text colour. [white] is a colour like
     any other -- on a light background it is the background -- so a fallback
     that means "nothing special about this value" has to say default, not
     white. Unlike [reset] it leaves bold and dim alone, so it can sit inside
     an emphasised run without flattening it. *)
  let default_fg = style "\027[39m"
  let gray = style "\027[90m"

  (* Backgrounds, which exist for one reader: a diff row's colour has to reach
     the right edge, because a removed line and a shorter removed line are the
     same fact and ragged colour reads as a difference between them. 256-colour
     rather than truecolour -- the terminals this runs in all have the cube,
     and a palette entry degrades to something sensible where they do not. *)
  let bg_removed = style "\027[48;5;52m"
  let bg_added = style "\027[48;5;22m"

  (* Cursor movement *)
  let move_to row col = Printf.sprintf "\027[%d;%dH" row col

  (* Reverse video for selection highlight. Kept under NO_COLOR: it is the
     one selection signal every terminal renders without colour. *)
  let reverse = "\027[7m"

  (* Box drawing characters *)
  let box_h = "\xe2\x94\x80"  (* horizontal line *)
  let box_v = "\xe2\x94\x82"  (* vertical line *)
  let box_tl = "\xe2\x94\x8c" (* top-left corner *)
  let box_tr = "\xe2\x94\x90" (* top-right corner *)
  let box_bl = "\xe2\x94\x94" (* bottom-left corner *)
  let box_br = "\xe2\x94\x98" (* bottom-right corner *)
  let box_l = "\xe2\x94\x9c"  (* left tee *)
  let box_r = "\xe2\x94\xa4"  (* right tee *)
end

(** Semantic styles for state and content syntax.

    A fact about health, phase, or attention draws through these names, so
    one remap -- a theme, a colourblind palette -- moves every reading at
    once. The boundary: state goes through the top-level names; syntax colours
    stay under [Syntax], because "this word is green" is content (a diff or a
    code literal) rather than a reading of state. Renderers do not choose raw
    red, yellow, or green themselves. *)
module Theme = struct
  let ok = Ansi.green
  let warn = Ansi.yellow
  let bad = Ansi.red
  let info = Ansi.cyan
  let muted = Ansi.dim
  let selection = Ansi.reverse
  let border_focus = Ansi.cyan

  module Syntax = struct
    let keyword = Ansi.yellow
    let string = Ansi.green
  end
end

(** One owner for the visual distinction between conversation roles.

    Role and state are different axes: a Keeper message is not a success, and
    a user message is not merely informational. The renderer asks this module
    for its badge/gutter and body styles instead of rebuilding that mapping.
    Both human and Keeper prose deliberately keep the terminal's foreground. *)
module Chat_theme = struct
  let origin : Masc_tui_message_layout.style -> string = function
    | Masc_tui_message_layout.User -> Ansi.cyan
    | Masc_tui_message_layout.Keeper -> Ansi.blue
    | Masc_tui_message_layout.Status -> Theme.warn
    | Masc_tui_message_layout.Error -> Theme.bad
    | Masc_tui_message_layout.Tool -> Ansi.magenta
    | Masc_tui_message_layout.Thinking -> Ansi.gray

  let body : Masc_tui_message_layout.style -> string = function
    | Masc_tui_message_layout.User | Masc_tui_message_layout.Keeper -> Ansi.reset
    | Masc_tui_message_layout.Status -> Theme.warn
    | Masc_tui_message_layout.Error -> Theme.bad
    | Masc_tui_message_layout.Tool | Masc_tui_message_layout.Thinking -> Ansi.dim
end

(** A screen title.

    Emphasis belongs to the words that name the screen, not to the whole header
    line. Headers interpolate coloured badges, and the reset that closes a badge
    also closes any style wrapped around the line, so styling the line bolded a
    different amount of text on every screen -- as far as its first badge, which
    sits in a different place each time. Eight screens wrapped the line and eight
    drew it plain, and the four styles that came out of that were not a
    decision. *)
let screen_title text = Ansi.bold ^ text ^ Ansi.reset

(** Terminal size changes only after SIGWINCH. Cache the process-backed probe so
    an idle TUI does not spawn [tput] twice per frame. *)
let terminal_size_cache =
  Masc_tui_render_schedule.Terminal_size_cache.create ~fallback:(24, 80)

let invalidate_terminal_size () =
  Masc_tui_render_schedule.Terminal_size_cache.invalidate terminal_size_cache

(* Asked of the tty itself, without a child process.

   [tput] reads the size from TIOCGWINSZ on its own stdout, and this probe
   captured that stdout through a pipe, so the ioctl never saw a terminal and
   [tput] answered from the static terminfo entry instead -- 80x24 for most
   terminals, returned as though it were a measurement. #30187 found the other
   half: since #30160 pointed stderr at a file, a child probe can inherit no
   tty fd at all, which is why it reached for /dev/tty by name.

   Both halves are answered by asking the kernel directly. [Terminal_size]
   tries the three standard descriptors and then /dev/tty, and says [None]
   rather than guessing when none of them is a terminal -- the [tput] fallback
   is gone because a fabricated 80x24 is the failure, not the cure. Two
   processes per resize become none. *)
let probe_terminal_size () = Terminal_size.get ()

(** Get terminal size (fallback to 80x24). *)
let get_terminal_size () =
  Masc_tui_render_schedule.Terminal_size_cache.get terminal_size_cache
    ~probe:probe_terminal_size

(** Draw horizontal line *)
let draw_hline width =
  String.concat "" (List.init width (fun _ -> Ansi.box_h))

(** Pad or truncate plain text without counting ANSI style bytes. *)
let fit_width = Masc_tui_message_layout.fit_width

(** External values become one printable logical row before renderer-owned ANSI
    styling or width calculation is applied. *)
module Terminal_text = struct
  let single_line text = Masc.Tui_decode.sanitize_terminal_text text
  let optional_single_line = Option.map single_line

  let single_line_or ~default value =
    Option.value ~default (optional_single_line value)

  let single_lines values = List.map single_line values
  let short_timestamp text = Masc.Tui_decode.short_timestamp_for_terminal text
  (* The screen's clock is the terminal's zone. This is the one place that
     names it, so every row clock and the header clock agree. *)
  let clock_timestamp text =
    Masc.Tui_decode.clock_timestamp_for_terminal ~localtime:Unix.localtime text
end

(** Status color *)
let status_color status =
  match status with
  | "working" | "in_progress" -> Ansi.yellow
  | "idle" | "online" -> Ansi.green
  | "offline" -> Ansi.gray
  | "error" -> Ansi.red
  | _ -> Ansi.default_fg

(** Task status icon *)
let task_status_icon status =
  match status with
  | Masc_domain.Done _ -> "\xe2\x97\x8f"  (* filled circle *)
  | Masc_domain.Claimed _
  | Masc_domain.InProgress _
  | Masc_domain.AwaitingVerification _ -> "\xe2\x97\x90"  (* half circle *)
  | Masc_domain.Todo -> "\xe2\x97\x8b"  (* empty circle *)
  | Masc_domain.Cancelled _ -> "\xc3\x97"

(** Priority indicator *)
let priority_indicator p =
  if p <= 1 then Ansi.red ^ "!!!" ^ Ansi.reset
  else if p <= 2 then Ansi.red ^ "!!" ^ Ansi.reset
  else if p <= 3 then Ansi.yellow ^ "!" ^ Ansi.reset
  else ""

(** Context ratio color: green < 50%, yellow 50-80%, red > 80% *)
let ctx_color ratio =
  if ratio >= 0.8 then Ansi.red
  else if ratio >= 0.5 then Ansi.yellow
  else Ansi.green

(** Format context ratio as a visual bar *)
let ctx_bar ratio width =
  let width = Masc_tui_render_schedule.nonnegative_width width in
  let filled = int_of_float (ratio *. float_of_int width) in
  let filled = max 0 (min width filled) in
  let empty = width - filled in
  let color = ctx_color ratio in
  Printf.sprintf "%s%s%s%s"
    color
    (String.make filled '#')
    (Ansi.gray ^ String.make empty '-' ^ Ansi.reset)
    Ansi.reset

(* The framed family keeps the full border box. Modals (palette, help) and
   side-by-side panes still need it: a border is what separates an overlay
   from the surface under it, and two panes from each other. *)

let framed_top buf cols =
  Buffer.add_string buf (Printf.sprintf "%s%s%s%s%s\n"
    Ansi.gray Ansi.box_tl (draw_hline (cols - 2)) Ansi.box_tr Ansi.reset)

let framed_bottom buf cols =
  Buffer.add_string buf (Printf.sprintf "%s%s%s%s%s\n"
    Ansi.gray Ansi.box_bl (draw_hline (cols - 2)) Ansi.box_br Ansi.reset)

let framed_divider buf cols =
  Buffer.add_string buf (Printf.sprintf "%s%s%s%s%s\n"
    Ansi.gray Ansi.box_l (draw_hline (cols - 2)) Ansi.box_r Ansi.reset)

let framed_line buf cols content =
  let inner = cols - 4 in
  Buffer.add_string buf (Printf.sprintf "%s%s%s %s %s%s%s\n"
    Ansi.gray Ansi.box_v Ansi.reset
    (fit_width content inner)
    Ansi.gray Ansi.box_v Ansi.reset)

let framed_line_styled buf cols ~style content =
  let inner = cols - 4 in
  let content = fit_width content inner in
  Buffer.add_string buf
    (Printf.sprintf "%s%s%s %s%s%s %s%s%s\n" Ansi.gray Ansi.box_v
       Ansi.reset style content Ansi.reset Ansi.gray Ansi.box_v Ansi.reset)

let framed_empty buf cols =
  let inner = cols - 4 in
  Buffer.add_string buf (Printf.sprintf "%s%s%s %s %s%s%s\n"
    Ansi.gray Ansi.box_v Ansi.reset
    (String.make inner ' ')
    Ansi.gray Ansi.box_v Ansi.reset)

(* Full-screen surfaces draw without the outer box: the terminal edge is
   already the frame, and a border around everything separates nothing (the
   clutter audit's first offender). Every helper keeps its old geometry --
   one row per call, content width [cols - 4] -- so no surface's row budget
   or wrap math moves. *)

let box_top buf _cols = Buffer.add_char buf '\n'
let box_bottom buf _cols = Buffer.add_char buf '\n'

let box_divider buf cols =
  Buffer.add_string buf
    (Printf.sprintf " %s%s%s \n" Ansi.gray (draw_hline (cols - 2)) Ansi.reset)

(* Rows keep the framed geometry -- two margin cells each side, content
   width [cols - 4] -- and still span the full [cols], so anything that
   measures a row (the PTY suite does) reads the same width either way. *)
let box_line buf cols content =
  let inner = cols - 4 in
  Buffer.add_string buf (Printf.sprintf "  %s  \n" (fit_width content inner))

let box_line_styled buf cols ~style content =
  let inner = cols - 4 in
  let content = fit_width content inner in
  Buffer.add_string buf
    (Printf.sprintf "  %s%s%s  \n" style content Ansi.reset)

let box_empty buf cols =
  Buffer.add_string buf (String.make cols ' ');
  Buffer.add_char buf '\n' 
