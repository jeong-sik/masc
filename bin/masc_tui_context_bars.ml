
module Sgr = Masc_tui_theme.Sgr
module Box = Masc_tui_theme.Box

(* One terminal cell each, written as bytes for the same reason {!Box} is: the
   file stays readable under an editor that guesses the encoding wrong. *)
let bar_full = "\xe2\x96\x88" (* U+2588 FULL BLOCK *)
let bar_dark = "\xe2\x96\x93" (* U+2593 DARK SHADE *)
let bar_medium = "\xe2\x96\x92" (* U+2592 MEDIUM SHADE *)
let bar_light = "\xe2\x96\x91" (* U+2591 LIGHT SHADE *)

let repeat glyph count =
  if count <= 0 then "" else String.concat "" (List.init count (fun _ -> glyph))

let fill_cells ~width ~numerator ~denominator =
  if width <= 0 || numerator <= 0 || denominator <= 0 then 0
  else if numerator >= denominator then width
  else
    let cells = numerator * width / denominator in
    (* Floor, except that a real share never floors away to nothing: an empty
       bar reads as "none was sent", which is a stronger claim than the
       measurement makes. *)
    if cells = 0 then 1 else cells

let apportion ~width ~weights =
  let weights = Array.of_list (List.map (fun weight -> max 0 weight) weights) in
  let count = Array.length weights in
  let total = Array.fold_left ( + ) 0 weights in
  if width <= 0 || total = 0 then List.init count (fun _ -> 0)
  else begin
    let cells = Array.make count 0 in
    let remainders = Array.make count 0 in
    let floored = ref 0 in
    Array.iteri
      (fun index weight ->
        let scaled = weight * width in
        cells.(index) <- scaled / total;
        remainders.(index) <- scaled mod total;
        floored := !floored + cells.(index))
      weights;
    (* Each floor discards under one cell, so the shortfall is smaller than the
       number of segments and one extra cell per segment always covers it. Ties
       go to the earlier segment, which keeps the split a function of the
       weights alone rather than of the sort's behaviour on equal keys. *)
    let order = Array.init count (fun index -> index) in
    Array.sort
      (fun left right ->
        if remainders.(left) <> remainders.(right) then
          compare remainders.(right) remainders.(left)
        else compare left right)
      order;
    let shortfall = ref (width - !floored) in
    Array.iter
      (fun index ->
        if !shortfall > 0 then begin
          cells.(index) <- cells.(index) + 1;
          decr shortfall
        end)
      order;
    Array.to_list cells
  end

let segment_glyph index =
  match index mod 4 with
  | 0 -> bar_full
  | 1 -> bar_dark
  | 2 -> bar_medium
  | _ -> bar_light

(* Three tiers, so the row is exactly [width] cells at every width the pane
   hands down. An overrun is not silent -- the frame truncates it and marks the
   cut with a tilde -- but a header ending in a tilde reads as a broken row, and
   the operator loses the caption either way. Dropping it deliberately at least
   leaves a clean rule, and the screen's closing lines still carry the same
   sentence. *)
let band ~width ~title ~caption =
  let title_cells = String.length title in
  let caption_cells = String.length caption in
  if width >= 9 + title_cells + caption_cells then
    let fill = width - 8 - title_cells - caption_cells in
    Sgr.dim ^ repeat Box.h 2 ^ Sgr.reset ^ " " ^ Sgr.bold ^ title ^ Sgr.reset
    ^ " " ^ Sgr.dim ^ repeat Box.h fill ^ " " ^ caption ^ " " ^ repeat Box.h 2
    ^ Sgr.reset
  else if width >= 5 + title_cells then
    Sgr.dim ^ repeat Box.h 2 ^ Sgr.reset ^ " " ^ Sgr.bold ^ title ^ Sgr.reset
    ^ " " ^ Sgr.dim
    ^ repeat Box.h (width - 4 - title_cells)
    ^ Sgr.reset
  else Sgr.dim ^ repeat Box.h (max 0 width) ^ Sgr.reset

(* Word wrap for the rows under a bar. The pane can be narrower than a
   sentence, and a sentence the frame cuts with a tilde loses the half that
   said what the number means.

   Runs of spaces are carried across the fold rather than collapsed: the
   screen's unfolded rows separate figures with a wide "  " dot, and a folded
   row that narrowed it to one space would read as a different kind of row.
   Splits on spaces only; a word longer than [width] takes its own line and
   overruns. *)
let wrap ~width text =
  if width <= 0 then [ text ]
  else begin
    let length = String.length text in
    let lines = ref [] in
    let current = Buffer.create (width + 8) in
    let index = ref 0 in
    while !index < length do
      let gap_start = !index in
      while !index < length && Char.equal text.[!index] ' ' do
        incr index
      done;
      let gap = !index - gap_start in
      let word_start = !index in
      while !index < length && not (Char.equal text.[!index] ' ') do
        incr index
      done;
      let word = String.sub text word_start (!index - word_start) in
      if not (String.equal word "") then
        if Buffer.length current = 0 then Buffer.add_string current word
        else if Buffer.length current + gap + String.length word <= width then begin
          Buffer.add_string current (String.make gap ' ');
          Buffer.add_string current word
        end
        else begin
          lines := Buffer.contents current :: !lines;
          Buffer.clear current;
          Buffer.add_string current word
        end
    done;
    if Buffer.length current > 0 then lines := Buffer.contents current :: !lines;
    match List.rev !lines with [] -> [ "" ] | wrapped -> wrapped
  end

let ratio_bar ~width ~numerator ~denominator =
  let filled = fill_cells ~width ~numerator ~denominator in
  Sgr.cyan ^ repeat bar_full filled ^ Sgr.reset ^ Sgr.dim
  ^ repeat bar_light (max 0 (width - filled))
  ^ Sgr.reset

let reach_bar ~width ~transmitted ~total ~sent_style =
  let sent = fill_cells ~width ~numerator:transmitted ~denominator:total in
  Sgr.dim
  ^ repeat bar_light (max 0 (width - sent))
  ^ Sgr.reset ^ Sgr.bold ^ sent_style ^ repeat bar_full sent ^ Sgr.reset

let pointer_label = "sent this turn"

let reach_pointer ~width ~transmitted ~total =
  let sent = fill_cells ~width ~numerator:transmitted ~denominator:total in
  let cut = max 0 (width - sent) in
  (* The corner has to sit on the first sent cell, not on the last omitted one:
     one cell to its left it labels the history it is telling the reader was
     left behind. *)
  Sgr.dim
  ^ (if cut >= String.length pointer_label + 2 then
       String.make (cut - String.length pointer_label - 2) ' '
       ^ pointer_label ^ " " ^ Box.h ^ Box.br
     else String.make cut ' ' ^ Box.bl ^ " " ^ pointer_label)
  ^ Sgr.reset

let stacked_bar ~width ~segments =
  let cells = apportion ~width ~weights:(List.map snd segments) in
  (* [apportion] returns one count per weight, so the zip is total. *)
  String.concat ""
    (List.mapi
       (fun index ((style, _), count) ->
         style ^ repeat (segment_glyph index) count ^ Sgr.reset)
       (List.combine segments cells))
