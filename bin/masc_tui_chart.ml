(** Visual charting and graphing primitives for the MASC TUI. *)

module Layout = Masc_tui_message_layout

let bar_full = "\xe2\x96\x88" (* U+2588 FULL BLOCK *)
let bar_light = "\xe2\x96\x91" (* U+2591 LIGHT SHADE *)
let meter_fill = "\xe2\x96\xa0" (* U+25A0 BLACK SQUARE *)
let meter_track = "\xc2\xb7" (* U+00B7 MIDDLE DOT *)
let glyph_block_1 = "\xe2\x96\x81" (* U+2581 *)
let glyph_block_2 = "\xe2\x96\x82" (* U+2582 *)
let glyph_block_3 = "\xe2\x96\x83" (* U+2583 *)
let glyph_block_4 = "\xe2\x96\x84" (* U+2584 *)
let glyph_block_5 = "\xe2\x96\x85" (* U+2585 *)
let glyph_block_6 = "\xe2\x96\x86" (* U+2586 *)
let glyph_block_7 = "\xe2\x96\x87" (* U+2587 *)
let glyph_block_8 = "\xe2\x96\x88" (* U+2588 *)

(** 8-level UTF-8 block character array from lowest (U+2581) to highest (U+2588). *)
let sparkline_glyphs =
  [| glyph_block_1
   ; glyph_block_2
   ; glyph_block_3
   ; glyph_block_4
   ; glyph_block_5
   ; glyph_block_6
   ; glyph_block_7
   ; glyph_block_8
  |]
;;

let repeat glyph count =
  if count <= 0 then ""
  else String.concat "" (List.init count (fun _ -> glyph))
;;

let sparkline_levels ?min ?max values =
  match values with
  | [] -> []
  | first :: rest ->
    let v_min =
      match min with
      | Some m -> m
      | None -> List.fold_left Stdlib.min first rest
    in
    let v_max =
      match max with
      | Some m -> m
      | None -> List.fold_left Stdlib.max first rest
    in
    let lower = Z.of_int v_min in
    let range = Z.sub (Z.of_int v_max) lower in
    let top = Array.length sparkline_glyphs - 1 in
    List.map
      (fun v ->
          if Z.sign range <= 0 then
            if v_min <= 0 then 0 else top / 2
          else
            let clamped_v = Stdlib.max v_min (Stdlib.min v_max v) in
            let offset = Z.sub (Z.of_int clamped_v) lower in
            Z.to_int (Z.div (Z.mul offset (Z.of_int top)) range))
      values
;;

let sparkline ?min ?max values =
  let levels = sparkline_levels ?min ?max values in
  let buf = Buffer.create (List.length levels * 3) in
  List.iter (fun level -> Buffer.add_string buf sparkline_glyphs.(level)) levels;
  Buffer.contents buf
;;

let sparkline_marks ?min ?max values =
  List.map (fun level -> sparkline_glyphs.(level))
    (sparkline_levels ?min ?max values)
;;

(* [abs min_int] overflows back to [min_int], a negative number, so the
   sign of the magnitude is what tells that one value apart. It prints as
   its exact integer string rather than a rung its magnitude does not
   reach, and the check holds on any word size. *)
let format_compact_num n =
  let abs_n = abs n in
  if abs_n < 0 then string_of_int n
  else
    if abs_n >= 1_000_000 then
      Printf.sprintf "%.1fM" (float_of_int n /. 1_000_000.0)
    else if abs_n >= 10_000 then
      Printf.sprintf "%dk" (n / 1_000)
    else if abs_n >= 1_000 then
      Printf.sprintf "%.1fk" (float_of_int n /. 1_000.0)
    else
      string_of_int n
;;

let bar_filled_cells ~width ~value ~max_value =
  if width <= 0 || max_value <= 0 || value <= 0 then 0
  else
    let clamped = Stdlib.min value max_value in
    let scaled =
      Z.to_int
        (Z.div
           (Z.mul (Z.of_int clamped) (Z.of_int width))
           (Z.of_int max_value))
    in
    Stdlib.max 1 (Stdlib.min width scaled)
;;

(* A gauge states a proportion and nothing else. It used to colour the bar
   Warn past 70% and Bad past 85%; no caller ever passed other levels and no
   domain the three callers draw from (task completion, fact count, snapshot
   bytes) defines a level of its own, so the colours were a judgement with no
   owner -- and on the task-completion gauge an inverted one, where a fleet
   90% done read as Bad (#33297). Fill and remainder are told apart by glyph
   and by dimming the remainder; a level, when a domain declares one, is the
   caller's to draw beside the bar. *)
let gauge ~width ~value ~max_value ?label () =
  if width <= 0 then ""
  else
    let clamped_val = Stdlib.max 0 (if max_value > 0 then Stdlib.min value max_value else value) in
    let pct =
      if max_value <= 0 then 0
      else Stdlib.min 100 ((clamped_val * 100) / max_value)
    in
    let prefix = match label with Some l -> l ^ " " | None -> "" in
    let prefix_cells = Layout.display_width prefix in
    (* A bar says how big something is only against the bar above it, so the
       axis has to be the same length on every row of a column. It was sized
       from the suffix this value prints, and the suffix is a percentage whose
       width grows with its digits: at sixteen cells a row reading "10%" drew
       a nine-cell axis beside a row reading "6%" with ten, so the fleet's
       largest fact holder drew the shortest trough. The percentage is written
       to three digits, which is every percentage there is, and the numbers
       beside it are measured at [max_value] -- the widest they can be -- so
       the axis comes off the gauge rather than off the row. *)
    let full_suffix =
      Printf.sprintf " %3d%% (%s / %s)" pct (format_compact_num value)
        (format_compact_num max_value)
    in
    let full_suffix_cells =
      let widest =
        Printf.sprintf " %3d%% (%s / %s)" 100 (format_compact_num max_value)
          (format_compact_num max_value)
      in
      Stdlib.max (Layout.display_width widest)
        (Layout.display_width full_suffix)
    in
    let full_suffix = Layout.fit_width full_suffix full_suffix_cells in
    let chrome_cells = prefix_cells + full_suffix_cells + 2 in
    if width >= chrome_cells + 4 then
      let bar_width = width - chrome_cells in
      let filled = bar_filled_cells ~width:bar_width ~value:clamped_val ~max_value in
      let unfilled = Stdlib.max 0 (bar_width - filled) in
      prefix ^ "[" ^ repeat bar_full filled ^ Masc_tui_theme.Sgr.dim
      ^ repeat bar_light unfilled ^ Masc_tui_theme.Sgr.reset ^ "]" ^ full_suffix
    else
      (* Three digits, so " 100%" and "   6%" are the same five cells and the
         text after the bar starts in one column too. *)
      let short_suffix = Printf.sprintf " %3d%%" pct in
      let short_chrome = prefix_cells + Layout.display_width short_suffix + 2 in
      if width >= short_chrome + 2 then
        let bar_width = width - short_chrome in
        let filled = bar_filled_cells ~width:bar_width ~value:clamped_val ~max_value in
        let unfilled = Stdlib.max 0 (bar_width - filled) in
        prefix ^ "[" ^ repeat bar_full filled ^ Masc_tui_theme.Sgr.dim
        ^ repeat bar_light unfilled ^ Masc_tui_theme.Sgr.reset ^ "]" ^ short_suffix
      else
        Layout.fit_width (Printf.sprintf "%s%d%%" prefix pct) width
;;

type meter_scale =
  | Declared_limit of Masc_tui_theme.limit_paint
  | Relative

let meter_cell_colour scale ~index ~width =
  match scale with
  | Declared_limit paint ->
    Masc_tui_theme.limit_cell_colour ~depth:paint.Masc_tui_theme.depth ~index
      ~width
  | Relative -> Masc_tui_theme.Cell_plain
;;

let meter_cell_style scale ~index ~width =
  match scale with
  | Declared_limit paint ->
    Masc_tui_theme.meter_cell_readable paint
      (meter_cell_colour scale ~index ~width)
  | Relative -> ""
;;

let meter_bar ~width ~value ~max_value ~scale ?(track_style = "")
    ?(reset = Masc_tui_theme.Sgr.reset) () =
  if width <= 0 then ""
  else
    let filled = bar_filled_cells ~width ~value ~max_value in
    let unfilled = Stdlib.max 0 (width - filled) in
    let filled_part =
      if filled <= 0 then ""
      else
        match scale with
        | Relative -> repeat meter_fill filled
        | Declared_limit _ ->
          String.concat ""
            (List.init filled (fun index ->
               meter_cell_style scale ~index ~width ^ meter_fill))
          ^ reset
    in
    let track_part =
      if unfilled <= 0 then ""
      else if String.equal track_style "" then repeat meter_track unfilled
      else track_style ^ repeat meter_track unfilled ^ reset
    in
    filled_part ^ track_part
;;

let meter ~width ~value ~max_value ~scale ?label ?suffix
    ?(track_style = "") ?(suffix_style = "")
    ?(reset = Masc_tui_theme.Sgr.reset) () =
  if width <= 0 then ""
  else
    let clamped_val =
      Stdlib.max 0 (if max_value > 0 then Stdlib.min value max_value else value)
    in
    let pct =
      if max_value <= 0 then 0
      else
        let scaled =
          Z.to_int
            (Z.div
               (Z.mul (Z.of_int clamped_val) (Z.of_int 100))
               (Z.of_int max_value))
        in
        Stdlib.min 100 scaled
    in
    let prefix =
      match label with
      | Some l when l <> "" -> l ^ " "
      | Some _ | None -> ""
    in
    let raw_suffix =
      match suffix with
      | Some s -> s
      | None -> Printf.sprintf "%3d%%" pct
    in
    let styled_suffix =
      if String.equal raw_suffix "" then ""
      else if String.equal suffix_style "" then " " ^ raw_suffix
      else " " ^ suffix_style ^ raw_suffix ^ reset
    in
    let suffix_cells =
      if String.equal raw_suffix "" then 0
      else 1 + Layout.display_width raw_suffix
    in
    let chrome_cells = Layout.display_width prefix + suffix_cells in
    if width >= chrome_cells + 3 then
      let bar_width = width - chrome_cells in
      prefix
      ^ meter_bar ~width:bar_width ~value:clamped_val ~max_value ~scale
          ~track_style ~reset ()
      ^ styled_suffix
    else
      let fallback =
        if String.equal raw_suffix "" then Printf.sprintf "%d%%" pct
        else raw_suffix
      in
      Layout.fit_width (prefix ^ fallback) width
;;


type bar_item = {
  name : string;
  count : int;
  style : Masc_tui_theme.status;
}

type distribution_share = { percentage : int; filled_cells : int }

let distribution_shares ~cells counts =
  let counts = List.map (fun count -> Z.of_int (Stdlib.max 0 count)) counts in
  let total = List.fold_left Z.add Z.zero counts in
  let cells = Z.of_int (Stdlib.max 0 cells) in
  let percentage_scale = Z.of_int 100 in
  let scaled scale count =
    if Z.equal total Z.zero then 0
    else
      (* [count <= total], so the quotient fits the original int scale even
         when the exact sum or multiplication does not fit an OCaml int. *)
      Z.to_int (Z.div (Z.mul count scale) total)
  in
  List.map (fun count ->
    { percentage = scaled percentage_scale count
    ; filled_cells = scaled cells count }) counts
;;

let distribution_bars ~width items =
  if width <= 0 || items = [] then []
  else
    let count_width = List.fold_left (fun acc it ->
      Stdlib.max acc (String.length (string_of_int (Stdlib.max 0 it.count)))) 5 items in
    let max_name_len = List.fold_left (fun acc it -> Stdlib.max acc (Layout.display_width it.name)) 0 items in
    let name_col_width = Stdlib.min 18 (Stdlib.max 6 max_name_len) in
    let fixed_cols = 2 + name_col_width + 2 + 1 + count_width + 1 + 6 in
    let bar_width = Stdlib.max 0 (width - fixed_cols) in
    let shares = distribution_shares ~cells:bar_width (List.map (fun it -> it.count) items) in
    List.map2
      (fun it share ->
        let count = Stdlib.max 0 it.count in
        let pct = share.percentage in
        let color = Masc_tui_theme.status it.style in
        let padded_name = Layout.fit_width it.name name_col_width in
        if bar_width <= 0 then
          Layout.fit_width
            (Printf.sprintf "  %s  %s%*d (%2d%%)%s"
               padded_name color count_width count pct Masc_tui_theme.Sgr.reset)
            width
        else
          let filled =
            if count <= 0 then 0
            else Stdlib.max 1 (Stdlib.min bar_width share.filled_cells)
          in
          let unfilled = Stdlib.max 0 (bar_width - filled) in
          Printf.sprintf "  %s  %s%s%s%s%s %*d (%2d%%)"
            padded_name
            color
            (repeat meter_fill filled)
            (Masc_tui_theme.Sgr.reset ^ Masc_tui_theme.Sgr.dim)
            (repeat meter_track unfilled)
            Masc_tui_theme.Sgr.reset
            count_width count
            pct)
      items shares
;;

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

type sample =
  | Unread
  | Absent
  | Zero
  | Value of int

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
   axis with no height, fills it too; a Value at or below zero sits on the
   baseline, where the axis starts. *)
let braille_level ~dots ~maximum sample =
  let dots = Stdlib.max 2 dots in
  match sample with
  | Unread | Absent -> 0
  | Zero -> 1
  | Value value when value <= 0 -> 1
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

let draw_rows ~rows ~mask cell_pairs =
  List.init rows (fun row ->
    String.concat ""
      (List.map
         (fun (left, right) -> braille_cell ~mask:(mask ~row left right))
         cell_pairs))
;;

(* Rows, top first, of columns growing up: the top row holds the dots
   [rows - 1] rows above the base. *)
let rising_rows ~rows cell_pairs =
  draw_rows ~rows cell_pairs ~mask:(fun ~row left right ->
    let from_base = rows - 1 - row in
    braille_left_dots.(row_dots ~row:from_base left)
    lor braille_right_dots.(row_dots ~row:from_base right))
;;

(* Rows, top first, of columns growing down from the row above them. *)
let falling_rows ~rows cell_pairs =
  draw_rows ~rows cell_pairs ~mask:(fun ~row left right ->
    braille_left_dots_down.(row_dots ~row left)
    lor braille_right_dots_down.(row_dots ~row right))
;;

let with_axis ~axis ~axis_cells rows =
  List.mapi
    (fun row dots ->
      (if row = 0 then axis ^ " " else String.make axis_cells ' ') ^ dots)
    rows
;;

let braille_graph ~width ~rows ~axis ~maximum samples =
  let rows = Stdlib.max 1 rows in
  let axis_cells, cells = graph_layout ~width ~axis in
  if never_read samples then Never_read
  else if cells < graph_min_cells then Too_narrow
  else
    let dots = rows * braille_top in
    Drawn
      (with_axis ~axis ~axis_cells
         (rising_rows ~rows (levelled ~dots ~maximum ~cells samples)))
;;

let braille_mirror ~width ~half_rows ~axis ~maximum ~up ~down =
  let half_rows = Stdlib.max 1 half_rows in
  let axis_cells, cells = graph_layout ~width ~axis in
  if never_read up && never_read down then Never_read
  else if cells < graph_min_cells then Too_narrow
  else
    let dots = half_rows * braille_top in
    Drawn
      (with_axis ~axis ~axis_cells
         (rising_rows ~rows:half_rows (levelled ~dots ~maximum ~cells up)
          @ falling_rows ~rows:half_rows (levelled ~dots ~maximum ~cells down)))
;;
