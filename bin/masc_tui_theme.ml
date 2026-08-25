(* Colour and glyph tokens — see the interface for the contracts. The escape
   strings here moved verbatim from masc_tui_ansi.ml; that module now aliases
   these values, and byte-identical frames are the acceptance test for the
   move. *)

let colors_enabled =
  match Sys.getenv_opt "MASC_TUI_FORCE_COLOR" with
  | Some "1" -> true
  | Some _ | None ->
    (match Sys.getenv_opt "NO_COLOR" with
     | Some value when String.length value > 0 -> false
     | Some _ | None -> true)

let style code = if colors_enabled then code else ""

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

  let bg_removed = style "\027[48;5;52m"
  let bg_added = style "\027[48;5;22m"

  let reverse = "\027[7m"
end

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
