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

(* A column [rows] cells tall, top cell first: each cell holds the four
   levels of its own band, the base cell levels 1 to 4. *)
let braille_bar_rows ~rows ~level =
  let rows = Stdlib.max 1 rows in
  List.init rows (fun index ->
    let from_base = rows - 1 - index in
    braille_bar_mark ~level:(level - (braille_top * from_base)))

(* Top-down 0..4 dot subcolumns. The lower half of a mirror grows down from
   the axis, so it fills its column from the top: the left column uses dots
   1, 2, 3, 7 and the right column dots 4, 5, 6, 8. *)
let braille_left_dots_down = [| 0x00; 0x01; 0x03; 0x07; 0x47 |]
let braille_right_dots_down = [| 0x00; 0x08; 0x18; 0x38; 0xb8 |]

let braille_pair_down ~left ~right =
  let l = clamp_braille_level left and r = clamp_braille_level right in
  braille_cell ~mask:(braille_left_dots_down.(l) lor braille_right_dots_down.(r))
;;

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

let microseconds_per_ms = 1000.0

let of_milliseconds ms =
  if not (Float.is_finite ms) then Absent
  else
    let microseconds = Float.ceil (ms *. microseconds_per_ms) in
    if microseconds >= Float.of_int max_int then of_count max_int
    else of_count (Float.to_int microseconds)

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
   no time; the rows under it leave that column blank. One cell of gap
   separates the text from the dots. *)
let dot_cells ~width ~axis_cells = width - (axis_cells + 1)

let graph_layout ~width ~axis =
  let axis_cells = Layout.display_width axis in
  (axis_cells + 1, dot_cells ~width ~axis_cells)
;;

let graph_times ~width ~axis_cells = 2 * Stdlib.max 0 (dot_cells ~width ~axis_cells)

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
            (* An empty style is the foreground, which only a reset gives
               back. *)
            Buffer.add_string buffer
              (if String.equal style "" then Masc_tui_theme.Sgr.reset else style);
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

let value_share ~dots level =
  let span = Stdlib.max 1 (dots - 2) in
  Float.max 0.0 (Float.min 1.0 (float_of_int (level - 2) /. float_of_int span))
;;

(* A cell's height share: the taller of its two times. *)
let cell_share ~dots (left, right) = value_share ~dots (Stdlib.max left right)

(* btop's rule: a graph more than one row tall takes its colour from the row,
   so the colour says how high the row sits; a one-row graph takes it from
   each cell's own height. [distance] counts rows from where the columns
   start growing. *)
let draw_rows ~tint ~rows ~dots ~distance ~mask cell_pairs =
  List.init rows (fun row ->
    let from_base = distance row in
    let row_style =
      if rows > 1 then tint (float_of_int from_base /. float_of_int (rows - 1)) else ""
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

let interpolate_pairs ~cells samples =
  if cells <= 0 then []
  else if samples = [] then List.init cells (fun _ -> (0, 0))
  else
    let total_cols = 2 * cells in
    let arr = Array.of_list samples in
    let n = Array.length arr in
    let cols = Array.make total_cols 0 in
    let span_of i =
      let lo = Stdlib.min (total_cols - 1) ((i * total_cols) / n) in
      let raw_hi = (((i + 1) * total_cols) / n) - 1 in
      let hi = Stdlib.max lo (Stdlib.min (total_cols - 1) raw_hi) in
      (lo, hi, (lo + hi) / 2)
    in
    let paint_linear ~x0 ~h0 ~x1 ~h1 =
      if h0 > 0 || h1 > 0 then begin
        let lo_x = Stdlib.min x0 x1 and hi_x = Stdlib.max x0 x1 in
        let span = hi_x - lo_x in
        for x = lo_x to hi_x do
          let t =
            if span <= 0 then 0.0
            else float_of_int (x - x0) /. float_of_int (x1 - x0)
          in
          let raw =
            int_of_float
              (Float.round (float_of_int h0 +. (t *. float_of_int (h1 - h0))))
          in
          let h = Stdlib.max 1 raw in
          if h > cols.(x) then cols.(x) <- h
        done
      end
    in
    for i = 0 to n - 1 do
      match arr.(i) with
      | None -> ()
      | Some raw_h ->
          let h = Stdlib.max 0 raw_h in
          let lo, hi, cx = span_of i in
          let has_left = i > 0 && Option.is_some arr.(i - 1) in
          let has_right = i + 1 < n && Option.is_some arr.(i + 1) in
          if not has_left then begin
            let shoulder = if h > 0 then Stdlib.max 1 (h / 2) else 0 in
            paint_linear ~x0:lo ~h0:shoulder ~x1:cx ~h1:h
          end;
          if has_right then begin
            let h_next =
              match arr.(i + 1) with Some v -> Stdlib.max 0 v | None -> 0
            in
            let _, _, next_cx = span_of (i + 1) in
            paint_linear ~x0:cx ~h0:h ~x1:next_cx ~h1:h_next
          end else begin
            let shoulder = if h > 0 then Stdlib.max 1 (h / 2) else 0 in
            paint_linear ~x0:cx ~h0:h ~x1:hi ~h1:shoulder
          end
    done;
    List.init cells (fun c -> (cols.(2 * c), cols.(2 * c + 1)))
;;

let braille_curve_rows ?(down = false) ~tint ~rows cell_pairs =
  let rows = Stdlib.max 1 rows in
  let dots = rows * braille_top in
  let clamped =
    List.map
      (fun (l, r) ->
        (Stdlib.max 0 (Stdlib.min dots l), Stdlib.max 0 (Stdlib.min dots r)))
      cell_pairs
  in
  if down then falling_rows ~tint ~rows ~dots clamped
  else rising_rows ~tint ~rows ~dots clamped
;;
