module Layout = Masc_tui_message_layout

(* The only escape this module spells. Everything else arrives as a string
   from [Masc_tui_ansi], which is where [NO_COLOR] is decided; a second table
   here would be a second place that decision could live. A reset is not a
   colour, so it is not gated there either. *)
let sgr_reset = "\027[0m"

(* A style is what is still open, not what to write. Held as the escapes
   themselves rather than as colour names so the vocabulary stays
   [Masc_tui_ansi]'s -- it already decides what [NO_COLOR] means, and a second
   table here would be a second place for that decision to live.

   [None] is "inherit". An empty string arrives from those helpers under
   [NO_COLOR] and is normalised to [None] on the way in, so a caller never has
   to ask whether colour is on. *)
type style = {
  fg : string option;
  bg : string option;
  (* Bold and dim are one field: they are the same SGR axis, a row asks for
     one or the other, and holding both would let a caller ask for a weight no
     terminal has. *)
  weight : string option;
}

let plain = { fg = None; bg = None; weight = None }
let nonempty code = if String.length code = 0 then None else Some code
let fg code = { plain with fg = nonempty code }
let bg code = { plain with bg = nonempty code }
let weight code = { plain with weight = nonempty code }

let combine outer inner =
  {
    fg = (match inner.fg with Some _ as set -> set | None -> outer.fg);
    bg = (match inner.bg with Some _ as set -> set | None -> outer.bg);
    weight = (match inner.weight with Some _ as set -> set | None -> outer.weight);
  }

(* Runs, not a string. The escapes are not written until [render], which is
   what lets [truncate] cut without ever landing inside one. *)
type t = { runs : (style * string) list }

let empty = { runs = [] }
let text style body = if String.length body = 0 then empty else { runs = [ (style, body) ] }
let concat parts = { runs = List.concat_map (fun part -> part.runs) parts }

let width value =
  List.fold_left (fun total (_, body) -> total + Layout.display_width body) 0 value.runs

let pad_to target style value =
  let current = width value in
  if current >= target then value
  else concat [ value; text style (String.make (target - current) ' ') ]

(* The longest prefix of [body] that fits [budget] columns.

   Walks scalar by scalar rather than byte by byte, so a character wider than
   what is left is dropped whole -- half a syllable is not a narrower
   syllable, it is a broken byte sequence the terminal reads as something
   else. [Layout.fit_width] is not this: it pads to the width and marks the
   cut with a tilde, which is what a column wants and not what a budget wants. *)
let prefix_within body budget =
  let length = String.length body in
  let rec walk index spent =
    if index >= length then index
    else
      match Layout.utf8_scalar_byte_length body.[index] with
      | None -> index
      | Some scalar_bytes ->
          let stop = min length (index + scalar_bytes) in
          let scalar = String.sub body index (stop - index) in
          let scalar_width = Layout.display_width scalar in
          if spent + scalar_width > budget then index
          else walk stop (spent + scalar_width)
  in
  String.sub body 0 (walk 0 0)

(* Cut run by run, spending the budget as it goes. *)
let truncate target value =
  let rec take remaining acc = function
    | [] -> List.rev acc
    | (style, body) :: rest ->
        let body_width = Layout.display_width body in
        if body_width <= remaining then
          take (remaining - body_width) ((style, body) :: acc) rest
        else if remaining <= 0 then List.rev acc
        else
          let cut = prefix_within body remaining in
          List.rev (if String.length cut = 0 then acc else (style, cut) :: acc)
  in
  if target <= 0 then empty else { runs = take target [] value.runs }

(* Every run opens what it needs and closes with a full reset. Re-opening per
   run is what makes a run's reset harmless to its neighbours: nothing here
   depends on a style that an earlier run left standing, so there is no
   standing style for a reset to knock down.

   A run that carries no style is written bare, so a row with no styling comes
   out byte-identical to the plain string it would have been. *)
let render value =
  let buffer = Buffer.create 128 in
  List.iter
    (fun (style, body) ->
      let opened = Buffer.create 16 in
      Option.iter (Buffer.add_string opened) style.weight;
      Option.iter (Buffer.add_string opened) style.bg;
      Option.iter (Buffer.add_string opened) style.fg;
      if Buffer.length opened = 0 then Buffer.add_string buffer body
      else begin
        Buffer.add_buffer buffer opened;
        Buffer.add_string buffer body;
        Buffer.add_string buffer sgr_reset
      end)
    value.runs;
  Buffer.contents buffer
