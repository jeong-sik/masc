module Terminal_palette = Masc_tui_terminal_palette
module Sgr = Masc_tui_theme.Sgr

type colour =
  | Black
  | Red
  | Green
  | Yellow
  | Blue
  | Magenta
  | Cyan
  | White

type foreground =
  | Palette of colour
  | Bright of colour
  | Rgb of Terminal_palette.rgb

type weight =
  | Regular
  | Bold
  | Dim

type pen =
  { foreground : foreground option
  ; weight : weight
  ; italic : bool
  ; underline : bool
  }

let plain = { foreground = None; weight = Regular; italic = false; underline = false }

type run =
  { pen : pen
  ; text : string
  }

type line = run list

(* ── Colours ──────────────────────────────────────────────────────────── *)

let colour_of_offset = function
  | 0 -> Some Black
  | 1 -> Some Red
  | 2 -> Some Green
  | 3 -> Some Yellow
  | 4 -> Some Blue
  | 5 -> Some Magenta
  | 6 -> Some Cyan
  | 7 -> Some White
  | _ -> None

let channel value = if value >= 0 && value <= 255 then Some value else None

let rgb red green blue =
  match channel red, channel green, channel blue with
  | Some red, Some green, Some blue -> Some (Rgb (Terminal_palette.make_rgb ~red ~green ~blue))
  | _ -> None

(* xterm's 256-colour table (256colres.h). The first sixteen indices are the
   palette slots SGR 30-37 and 90-97 name, so they stay palette-relative.
   Then a 6x6x6 cube on these six levels, then a ramp of 24 greys. *)
let palette_slots = 8
let cube_first = 16
let cube_side = 6
let cube_levels = [| 0; 95; 135; 175; 215; 255 |]
let grey_first = 232
let grey_last = 255
let grey_base = 8
let grey_step = 10

let indexed index =
  let slot constructor offset = Option.map constructor (colour_of_offset offset) in
  if index >= 0 && index < palette_slots then slot (fun c -> Palette c) index
  else if index >= palette_slots && index < cube_first then
    slot (fun c -> Bright c) (index - palette_slots)
  else if index >= cube_first && index < grey_first then
    let cube = index - cube_first in
    let level axis = cube_levels.(axis mod cube_side) in
    rgb (level (cube / (cube_side * cube_side))) (level (cube / cube_side)) (level cube)
  else if index >= grey_first && index <= grey_last then
    let grey = grey_base + (grey_step * (index - grey_first)) in
    rgb grey grey grey
  else None

(* ── SGR parameters ───────────────────────────────────────────────────── *)

(* One field of the list between [ESC [] and [m]. Digits, or digits joined
   by colons (ITU T.416 sub-parameters, [38:2::r:g:b]). An empty field or
   sub-parameter reads as 0, as terminals read it. Digits too long for an
   [int] are [Unreadable] and change nothing. *)
type field =
  | Code of int
  | Sub of int list
  | Unreadable

let number digits = if String.length digits = 0 then Some 0 else int_of_string_opt digits

let field_of_string text =
  match String.split_on_char ':' text with
  | [ single ] -> (match number single with Some value -> Code value | None -> Unreadable)
  | parts ->
    let values = List.filter_map number parts in
    if List.length values = List.length parts then Sub values else Unreadable

let with_foreground pen = function
  | Some foreground -> { pen with foreground = Some foreground }
  | None -> pen

let slot_colour constructor pen offset =
  with_foreground pen (Option.map constructor (colour_of_offset offset))

(* Every SGR code this pane does not draw -- blink, reverse, conceal, strike,
   fonts, backgrounds -- leaves the pen as it was: the text still shows, the
   way a terminal without that attribute shows it. *)
let code pen = function
  | 0 -> plain
  | 1 -> { pen with weight = Bold }
  | 2 -> { pen with weight = Dim }
  | 3 -> { pen with italic = true }
  | 4 -> { pen with underline = true }
  | 22 -> { pen with weight = Regular }
  | 23 -> { pen with italic = false }
  | 24 -> { pen with underline = false }
  | 39 -> { pen with foreground = None }
  | value when value >= 30 && value <= 37 -> slot_colour (fun c -> Palette c) pen (value - 30)
  | value when value >= 90 && value <= 97 -> slot_colour (fun c -> Bright c) pen (value - 90)
  | _ -> pen

(* 38 is the foreground; 48 (background) and 58 (underline colour) are read
   only so the numbers after them are not taken for codes of their own -- a
   background's 5 and palette index 1 are not "blink, then bold". An
   extended colour whose shape is wrong ends the list: which of the numbers
   after it are codes can no longer be told. *)
let rec apply pen = function
  | [] -> pen
  | Code 38 :: Code 5 :: Code index :: rest -> apply (with_foreground pen (indexed index)) rest
  | Code 38 :: Code 2 :: Code red :: Code green :: Code blue :: rest ->
    apply (with_foreground pen (rgb red green blue)) rest
  | Code (48 | 58) :: Code 5 :: Code _ :: rest -> apply pen rest
  | Code (48 | 58) :: Code 2 :: Code _ :: Code _ :: Code _ :: rest -> apply pen rest
  | Code (38 | 48 | 58) :: _ -> pen
  | Code value :: rest -> apply (code pen value) rest
  | Sub [ 38; 5; index ] :: rest -> apply (with_foreground pen (indexed index)) rest
  | (Sub [ 38; 2; red; green; blue ] | Sub [ 38; 2; _; red; green; blue ]) :: rest ->
    apply (with_foreground pen (rgb red green blue)) rest
  | Sub [ 4; 0 ] :: rest -> apply { pen with underline = false } rest
  | Sub [ 4; _ ] :: rest -> apply { pen with underline = true } rest
  | (Sub _ | Unreadable) :: rest -> apply pen rest

(* ── Escape sequences ─────────────────────────────────────────────────── *)

(* What an ESC at some index starts (ECMA-48 §5). *)
type escape =
  | Pen_change of string * int
      (** An SGR sequence: its parameters, and the index after its [m]. *)
  | Dropped of int
      (** A complete sequence this pane does not draw; the index after it. *)
  | Unfinished  (** The line ends inside it. *)
  | Not_a_sequence  (** A byte no sequence may hold follows; the ESC is text. *)

let esc = '\027'
let bel = '\007'
let string_terminator = '\\'
let in_range low high byte = Char.compare byte low >= 0 && Char.compare byte high <= 0
let is_parameter_byte = in_range '\x30' '\x3f'
let is_intermediate_byte = in_range '\x20' '\x2f'
let is_final_byte = in_range '\x40' '\x7e'
let is_escape_final_byte = in_range '\x30' '\x7e'
let is_sgr_parameter byte = in_range '0' '9' byte || Char.equal byte ';' || Char.equal byte ':'

(* CSI: parameter bytes, then intermediate bytes, then one final byte. Only
   [m] with plain numeric parameters is SGR; a private marker ([?25l]) or an
   intermediate makes it something else. *)
let control_sequence line ~from =
  let length = String.length line in
  let rec scan index ~intermediate =
    if index >= length then Unfinished
    else
      let byte = line.[index] in
      if is_parameter_byte byte && not intermediate then scan (index + 1) ~intermediate
      else if is_intermediate_byte byte then scan (index + 1) ~intermediate:true
      else if is_final_byte byte then
        let parameters = String.sub line from (index - from) in
        if Char.equal byte 'm' && (not intermediate) && String.for_all is_sgr_parameter parameters
        then Pen_change (parameters, index + 1)
        else Dropped (index + 1)
      else Not_a_sequence
  in
  scan from ~intermediate:false

(* OSC, DCS, SOS, PM, APC: a string up to ST ([ESC \]), or BEL for OSC. An
   ESC that is not ST abandons the string there and starts what follows. *)
let string_sequence line ~from ~bel_ends =
  let length = String.length line in
  let rec scan index =
    if index >= length then Unfinished
    else
      let byte = line.[index] in
      if bel_ends && Char.equal byte bel then Dropped (index + 1)
      else if Char.equal byte esc then
        if index + 1 >= length then Unfinished
        else if Char.equal line.[index + 1] string_terminator then Dropped (index + 2)
        else Dropped index
      else scan (index + 1)
  in
  scan from

(* nF: intermediates, then a final byte -- [ESC ( B] names a character set. *)
let designation line ~from =
  let length = String.length line in
  let rec scan index =
    if index >= length then Unfinished
    else
      let byte = line.[index] in
      if is_intermediate_byte byte then scan (index + 1)
      else if is_escape_final_byte byte then Dropped (index + 1)
      else Not_a_sequence
  in
  scan from

let escape_at line index =
  let length = String.length line in
  if index + 1 >= length then Unfinished
  else
    let from = index + 2 in
    match line.[index + 1] with
    | '[' -> control_sequence line ~from
    | ']' -> string_sequence line ~from ~bel_ends:true
    | 'P' | 'X' | '^' | '_' -> string_sequence line ~from ~bel_ends:false
    | byte when is_intermediate_byte byte -> designation line ~from
    | byte when is_escape_final_byte byte -> Dropped from
    | _ -> Not_a_sequence

(* ── Lines ────────────────────────────────────────────────────────────── *)

let read_line pen line =
  let length = String.length line in
  let buffer = Buffer.create length in
  let close pen runs =
    if Buffer.length buffer = 0 then runs
    else begin
      let run = { pen; text = Buffer.contents buffer } in
      Buffer.clear buffer;
      run :: runs
    end
  in
  let rec walk index pen runs =
    if index >= length then pen, List.rev (close pen runs)
    else if Char.equal line.[index] esc then begin
      match escape_at line index with
      | Pen_change (parameters, next) ->
        let runs = close pen runs in
        let fields = List.map field_of_string (String.split_on_char ';' parameters) in
        walk next (apply pen fields) runs
      | Dropped next -> walk next pen runs
      | Unfinished -> pen, List.rev (close pen runs)
      | Not_a_sequence ->
        Buffer.add_char buffer esc;
        walk (index + 1) pen runs
    end
    else begin
      Buffer.add_char buffer line.[index];
      walk (index + 1) pen runs
    end
  in
  walk 0 pen []

let parse text =
  let _, lines =
    List.fold_left
      (fun (pen, lines) line ->
        let pen, runs = read_line pen line in
        pen, runs :: lines)
      (plain, [])
      (String.split_on_char '\n' text)
  in
  List.rev lines

let text line = String.concat "" (List.map (fun run -> run.text) line)

(* ── Drawing ──────────────────────────────────────────────────────────── *)

let palette_escape = function
  | Black -> Sgr.black
  | Red -> Sgr.red
  | Green -> Sgr.green
  | Yellow -> Sgr.yellow
  | Blue -> Sgr.blue
  | Magenta -> Sgr.magenta
  | Cyan -> Sgr.cyan
  | White -> Sgr.white

let bright_escape = function
  | Black -> Sgr.gray
  | Red -> Sgr.bright_red
  | Green -> Sgr.bright_green
  | Yellow -> Sgr.bright_yellow
  | Blue -> Sgr.bright_blue
  | Magenta -> Sgr.bright_magenta
  | Cyan -> Sgr.bright_cyan
  | White -> Sgr.bright_white

let foreground_escape = function
  | Palette colour -> palette_escape colour
  | Bright colour -> bright_escape colour
  | Rgb colour -> Sgr.foreground (Terminal_palette.best_color colour)

let weight_escape = function
  | Regular -> ""
  | Bold -> Sgr.bold
  | Dim -> Sgr.dim

let opening pen =
  String.concat ""
    [ (match pen.foreground with Some foreground -> foreground_escape foreground | None -> "")
    ; weight_escape pen.weight
    ; (if pen.italic then Sgr.italic else "")
    ; (if pen.underline then Sgr.underline else "")
    ]

let render ~sanitize line =
  String.concat ""
    (List.map
       (fun run ->
         let body = sanitize run.text in
         let opening = opening run.pen in
         if String.length opening = 0 then body else opening ^ body ^ Sgr.reset)
       line)
