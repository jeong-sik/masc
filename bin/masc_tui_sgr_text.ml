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
  ; background : bool
  ; weight : weight
  ; italic : bool
  ; underline : bool
  }

let plain =
  { foreground = None; background = false; weight = Regular; italic = false; underline = false }

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
   fonts -- leaves the pen as it was: the text still shows, the way a terminal
   without that attribute shows it. A background is the exception: it is
   remembered, because a foreground chosen for it can be unreadable on this
   pane's own background, and the drawing leaves that foreground out. *)
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
  | 49 -> { pen with background = false }
  | value when (value >= 40 && value <= 47) || (value >= 100 && value <= 107) ->
    { pen with background = true }
  | value when value >= 30 && value <= 37 -> slot_colour (fun c -> Palette c) pen (value - 30)
  | value when value >= 90 && value <= 97 -> slot_colour (fun c -> Bright c) pen (value - 90)
  | _ -> pen

(* 38 is the foreground. 48 (background) is remembered as a flag and 58
   (underline colour) is read only so the numbers after them are not taken for
   codes of their own -- a background's 5 and palette index 1 are not "blink,
   then bold". An extended colour whose shape is wrong ends the list: which of
   the numbers after it are codes can no longer be told. A background of a
   wrong shape still counts as one: a terminal may draw it, and leaving the
   foreground out is the error that stays readable. *)
let rec apply pen = function
  | [] -> pen
  | Code 38 :: Code 5 :: Code index :: rest -> apply (with_foreground pen (indexed index)) rest
  | Code 38 :: Code 2 :: Code red :: Code green :: Code blue :: rest ->
    apply (with_foreground pen (rgb red green blue)) rest
  | Code 48 :: Code 5 :: Code _ :: rest -> apply { pen with background = true } rest
  | Code 48 :: Code 2 :: Code _ :: Code _ :: Code _ :: rest ->
    apply { pen with background = true } rest
  | Code 58 :: Code 5 :: Code _ :: rest -> apply pen rest
  | Code 58 :: Code 2 :: Code _ :: Code _ :: Code _ :: rest -> apply pen rest
  | Code (38 | 58) :: _ -> pen
  | Code 48 :: _ -> { pen with background = true }
  | Code value :: rest -> apply (code pen value) rest
  | Sub [ 38; 5; index ] :: rest -> apply (with_foreground pen (indexed index)) rest
  | (Sub [ 38; 2; red; green; blue ] | Sub [ 38; 2; _; red; green; blue ]) :: rest ->
    apply (with_foreground pen (rgb red green blue)) rest
  | Sub (48 :: _) :: rest -> apply { pen with background = true } rest
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
  | Operating_system_command of string * int
      (** An OSC string that ended in BEL or ST: its payload, and the index
          after it. *)
  | Unfinished  (** The text ends inside it, on the line still being written. *)
  | Not_a_sequence  (** A byte no sequence may hold follows; the ESC is text. *)

let esc = '\027'
let bel = '\007'
let cancel = '\024'
let substitute = '\026'
let string_terminator = '\\'
let in_range low high byte = Char.compare byte low >= 0 && Char.compare byte high <= 0
let is_parameter_byte = in_range '\x30' '\x3f'
let is_intermediate_byte = in_range '\x20' '\x2f'
let is_final_byte = in_range '\x40' '\x7e'
let is_escape_final_byte = in_range '\x30' '\x7e'
let is_sgr_parameter byte = in_range '0' '9' byte || Char.equal byte ';' || Char.equal byte ':'

(* CAN and SUB cancel the sequence they arrive in (ECMA-48 §8.3.6, §8.3.148):
   what was read of it is dropped and the text after them shows. *)
let cancels byte = Char.equal byte cancel || Char.equal byte substitute

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
      else if cancels byte then Dropped (index + 1)
      else Not_a_sequence
  in
  scan from ~intermediate:false

(* OSC, DCS, SOS, PM, APC: a string up to ST ([ESC \]), or BEL for OSC. An
   ESC that is not ST abandons the string there and starts what follows. *)
let string_sequence line ~from ~bel_ends =
  let length = String.length line in
  let payload index = String.sub line from (index - from) in
  let ended payload_end next =
    if bel_ends then Operating_system_command (payload payload_end, next) else Dropped next
  in
  let rec scan index =
    if index >= length then Unfinished
    else
      let byte = line.[index] in
      if bel_ends && Char.equal byte bel then ended index (index + 1)
      else if cancels byte then Dropped (index + 1)
      else if Char.equal byte esc then
        if index + 1 >= length then Unfinished
        else if Char.equal line.[index + 1] string_terminator then ended index (index + 2)
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
      else if cancels byte then Dropped (index + 1)
      else Not_a_sequence
  in
  scan from

let escape_sequence line index =
  let length = String.length line in
  if index + 1 >= length then Unfinished
  else
    let from = index + 2 in
    match line.[index + 1] with
    | '[' -> control_sequence line ~from
    | ']' -> string_sequence line ~from ~bel_ends:true
    | 'P' | 'X' | '^' | '_' -> string_sequence line ~from ~bel_ends:false
    | byte when cancels byte -> Dropped from
    | byte when is_intermediate_byte byte -> designation line ~from
    | byte when is_escape_final_byte byte -> Dropped from
    | _ -> Not_a_sequence

(* A sequence that a line already finished by its LF ends inside cannot
   continue on the next line, so its ESC stays in the text for the sanitizer
   and the bytes after it show. On the line still being written the rest may
   arrive with the next read, and the sequence waits for it. *)
let escape_at line index ~complete =
  match escape_sequence line index with
  | Unfinished when complete -> Not_a_sequence
  | (Pen_change _ | Dropped _ | Operating_system_command _ | Unfinished | Not_a_sequence) as found -> found

(* ── Hyperlinks ───────────────────────────────────────────────────────── *)

(* OSC 8 ([8 ; params ; URI]) opens a link over the text up to the OSC 8 with
   an empty URI. [None] for any other OSC. *)
type hyperlink =
  | Link_open of string
  | Link_close

let hyperlink_of_payload payload =
  match String.split_on_char ';' payload with
  | "8" :: _params :: uri_parts ->
    (match String.concat ";" uri_parts with
     | "" -> Some Link_close
     | uri -> Some (Link_open uri))
  | _ -> None

(* ── Lines ────────────────────────────────────────────────────────────── *)

(* The link a line ends inside carries over the line end, as the pen does: its
   text goes on on the next line. [shown] is what the link has shown so far. *)
type open_link =
  { uri : string
  ; shown : Buffer.t
  }

(* Where the link goes follows the line's text, unless the link's text is the
   address: the drawn text can differ from where the link goes, and the
   operator needs the address to read or copy it. Behind the text, so what
   comes after the link on the line stays where the program put it. A link
   still open when the text ends adds nothing yet: while a plain address is
   still arriving its text is not the address, and showing it twice for a
   moment would flicker. *)
let read_line ~complete (pen, link) line =
  let length = String.length line in
  let buffer = Buffer.create length in
  let link = ref link in
  let addresses = ref [] in
  let add_char char =
    Buffer.add_char buffer char;
    Option.iter (fun open_link -> Buffer.add_char open_link.shown char) !link
  in
  let finish_link () =
    (match !link with
     | Some { uri; shown }
       when (not (String.equal (Buffer.contents shown) uri)) && not (List.mem uri !addresses) ->
       addresses := uri :: !addresses
     | Some _ | None -> ());
    link := None
  in
  let close pen runs =
    if Buffer.length buffer = 0 then runs
    else begin
      let run = { pen; text = Buffer.contents buffer } in
      Buffer.clear buffer;
      run :: runs
    end
  in
  let finish pen runs =
    (match !addresses with
     | [] -> ()
     | listed ->
       if Buffer.length buffer > 0 || not (List.is_empty runs) then Buffer.add_char buffer ' ';
       Buffer.add_string buffer
         (String.concat " " (List.rev_map (fun uri -> "(" ^ uri ^ ")") listed)));
    (pen, !link), List.rev (close pen runs)
  in
  let rec walk index pen runs =
    if index >= length then finish pen runs
    else if Char.equal line.[index] esc then begin
      match escape_at line index ~complete with
      | Pen_change (parameters, next) ->
        let runs = close pen runs in
        let fields = List.map field_of_string (String.split_on_char ';' parameters) in
        walk next (apply pen fields) runs
      | Operating_system_command (payload, next) ->
        (match hyperlink_of_payload payload with
         | Some Link_close -> finish_link ()
         | Some (Link_open uri) ->
           finish_link ();
           link := Some { uri; shown = Buffer.create 0 }
         | None -> ());
        walk next pen runs
      | Dropped next -> walk next pen runs
      | Unfinished -> finish pen runs
      | Not_a_sequence ->
        add_char esc;
        walk (index + 1) pen runs
    end
    else begin
      add_char line.[index];
      walk (index + 1) pen runs
    end
  in
  walk 0 pen []

let parse text =
  let pieces = String.split_on_char '\n' text in
  let last = List.length pieces - 1 in
  let _, _, lines =
    List.fold_left
      (fun (index, state, lines) line ->
        let state, runs = read_line ~complete:(index < last) state line in
        index + 1, state, runs :: lines)
      (0, (plain, None), [])
      pieces
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
    [ (match pen.foreground with
       | Some foreground when not pen.background -> foreground_escape foreground
       | Some _ | None -> "")
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
