(** Braille cells and Braille graphs for the MASC TUI. *)

module Layout = Masc_tui_message_layout

let braille_cell ~mask =
  let m = mask land 0xff in
  let b1 = Char.chr 0xe2 in
  let b2 = Char.chr (0xa0 lor ((m lsr 6) land 0x03)) in
  let b3 = Char.chr (0x80 lor (m land 0x3f)) in
  let s = Bytes.create 3 in
  Bytes.set s 0 b1;
  Bytes.set s 1 b2;
  Bytes.set s 2 b3;
  Bytes.to_string s
;;

(* Bottom-up 0..4 dot subcolumns in the Unicode Braille block:
   left column uses dots 7, 3, 2, 1; right column uses dots 8, 6, 5, 4. *)
let braille_left_dots = [| 0x00; 0x40; 0x44; 0x46; 0x47 |]
let braille_right_dots = [| 0x00; 0x80; 0xa0; 0xb0; 0xb8 |]
let braille_top = 4

let clamp_braille_level level = Stdlib.max 0 (Stdlib.min braille_top level)

let braille_pair ~left ~right =
  let l = clamp_braille_level left and r = clamp_braille_level right in
  braille_cell ~mask:(braille_left_dots.(l) lor braille_right_dots.(r))
;;

let braille_bar_mark ~level = braille_pair ~left:level ~right:level

(* Top-down 0..4 dot subcolumns. The lower half of a mirror grows down from
   the axis, so it fills its column from the top: the left column uses dots
   1, 2, 3, 7 and the right column dots 4, 5, 6, 8. *)
let braille_left_dots_down = [| 0x00; 0x01; 0x03; 0x07; 0x47 |]
let braille_right_dots_down = [| 0x00; 0x08; 0x18; 0x38; 0xb8 |]

type positive = int

let positive count = if count > 0 then Some count else None

type sample =
  | Unread
  | Absent
  | Zero
  | Value of positive

let of_count count =
  match positive count with
  | Some value -> Value value
  | None -> if count = 0 then Zero else Absent

type graph =
  | Never_read
  | Too_narrow
  | Drawn of string list

let graph_min_cells = 4

let graph_maximum samples =
  List.fold_left
    (fun largest sample ->
      match sample with
      | Value value -> Stdlib.max largest value
      | Unread | Absent | Zero -> largest)
    0 samples
;;

(* Level 0 is a blank, level 1 the baseline a zero draws, and every value
   above zero starts at level 2, so a small value never reads as zero. The
   largest value fills the column. A value past the axis, or any value on an
   axis with no height, fills it too. *)
let braille_level ~dots ~maximum sample =
  let dots = Stdlib.max 2 dots in
  match sample with
  | Unread | Absent -> 0
  | Zero -> 1
  | Value _ when maximum <= 0 -> dots
  | Value value ->
    let above = dots - 1 in
    let scaled =
      Z.to_int
        (Z.div
           (Z.mul (Z.of_int (Stdlib.min value maximum)) (Z.of_int above))
           (Z.of_int maximum))
    in
    1 + Stdlib.max 1 (Stdlib.min above scaled)
;;

let never_read samples =
  List.for_all
    (function
      | Unread -> true
      | Absent | Zero | Value _ -> false)
    samples
;;

(* The newest [count] samples, oldest first; a time before the first sample
   is blank. *)
let newest count samples =
  let held = List.length samples in
  if held >= count then List.filteri (fun index _ -> index >= held - count) samples
  else List.init (count - held) (fun _ -> Absent) @ samples
;;

let rec pairs = function
  | left :: right :: rest -> (left, right) :: pairs rest
  | [ only ] -> [ (Absent, only) ]
  | [] -> []
;;

(* The dots one text row of a column holds: [row] counts rows away from where
   the column starts growing. *)
let row_dots ~row level =
  Stdlib.max 0 (Stdlib.min braille_top (level - (row * braille_top)))
;;

(* The axis text sits in its own column at the graph's top-left, so it hides
   no time; the rows under it leave that column blank. *)
let graph_layout ~width ~axis =
  let axis_cells = Layout.display_width axis + 1 in
  (axis_cells, width - axis_cells)
;;

(* The two times of each cell, as levels on a column [dots] dots tall. *)
let levelled ~dots ~maximum ~cells samples =
  let level = braille_level ~dots ~maximum in
  List.map
    (fun (left, right) -> (level left, level right))
    (pairs (newest (2 * cells) samples))
;;

type tint = float -> string

(* One row of cells, each drawn with the tint its height takes. A blank cell
   keeps whatever colour is open, a code goes out only where the colour
   changes, and the row closes with a reset when any code went out. *)
let tinted_row cells =
  let buffer = Buffer.create 64 in
  let open_style =
    List.fold_left
      (fun open_style (mask, style) ->
        let open_style =
          if mask = 0 || String.equal style open_style then open_style
          else begin
            Buffer.add_string buffer style;
            style
          end
        in
        Buffer.add_string buffer (braille_cell ~mask);
        open_style)
      "" cells
  in
  if not (String.equal open_style "") then Buffer.add_string buffer Masc_tui_theme.Sgr.reset;
  Buffer.contents buffer
;;

(* A cell's height share on a [dots]-dot column: the taller of its two
   times. *)
let cell_share ~dots (left, right) =
  float_of_int (Stdlib.max left right) /. float_of_int (Stdlib.max 1 dots)
;;

(* btop's rule: a graph more than one row tall takes its colour from the row,
   so the colour says how high the row sits; a one-row graph takes it from
   each cell's own height. [distance] counts rows from where the columns
   start growing. *)
let draw_rows ~tint ~rows ~dots ~distance ~mask cell_pairs =
  List.init rows (fun row ->
    let from_base = distance row in
    let row_style =
      if rows > 1 then tint (float_of_int (from_base + 1) /. float_of_int rows) else ""
    in
    tinted_row
      (List.map
         (fun ((left, right) as pair) ->
           ( mask ~row left right,
             if rows > 1 then row_style else tint (cell_share ~dots pair) ))
         cell_pairs))
;;

(* Rows, top first, of columns growing up: the top row holds the dots
   [rows - 1] rows above the base. *)
let rising_rows ~tint ~rows ~dots cell_pairs =
  let distance row = rows - 1 - row in
  draw_rows ~tint ~rows ~dots ~distance cell_pairs ~mask:(fun ~row left right ->
    let from_base = distance row in
    braille_left_dots.(row_dots ~row:from_base left)
    lor braille_right_dots.(row_dots ~row:from_base right))
;;

(* Rows, top first, of columns growing down from the row above them. *)
let falling_rows ~tint ~rows ~dots cell_pairs =
  draw_rows ~tint ~rows ~dots ~distance:(fun row -> row) cell_pairs
    ~mask:(fun ~row left right ->
      braille_left_dots_down.(row_dots ~row left)
      lor braille_right_dots_down.(row_dots ~row right))
;;

let with_axis ~axis ~axis_cells rows =
  List.mapi
    (fun row dots ->
      (if row = 0 then axis ^ " " else String.make axis_cells ' ') ^ dots)
    rows
;;

let braille_graph ~tint ~width ~rows ~axis ~maximum samples =
  let rows = Stdlib.max 1 rows in
  let axis_cells, cells = graph_layout ~width ~axis in
  if never_read samples then Never_read
  else if cells < graph_min_cells then Too_narrow
  else
    let dots = rows * braille_top in
    Drawn
      (with_axis ~axis ~axis_cells
         (rising_rows ~tint ~rows ~dots (levelled ~dots ~maximum ~cells samples)))
;;

let braille_mirror ~up_tint ~down_tint ~width ~half_rows ~axis ~maximum ~up ~down =
  let half_rows = Stdlib.max 1 half_rows in
  let axis_cells, cells = graph_layout ~width ~axis in
  if never_read up && never_read down then Never_read
  else if cells < graph_min_cells then Too_narrow
  else
    let dots = half_rows * braille_top in
    Drawn
      (with_axis ~axis ~axis_cells
         (rising_rows ~tint:up_tint ~rows:half_rows ~dots
            (levelled ~dots ~maximum ~cells up)
          @ falling_rows ~tint:down_tint ~rows:half_rows ~dots
              (levelled ~dots ~maximum ~cells down)))
;;
