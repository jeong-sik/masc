(** Visual charting and graphing primitives for the MASC TUI. *)

module Layout = Masc_tui_message_layout

let bar_full = "\xe2\x96\x88" (* U+2588 FULL BLOCK *)
let bar_light = "\xe2\x96\x91" (* U+2591 LIGHT SHADE *)
let meter_fill = "\xe2\x96\xa0" (* U+25A0 BLACK SQUARE *)
let dot_fill_full = "\xe2\xa3\xbf" (* U+28FF BRAILLE FULL 8-DOT *)
let dot_fill_half = "\xe2\xa1\x87" (* U+2847 BRAILLE LEFT COLUMN 4-DOT *)
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
  | Declared_limit of Masc_tui_theme.paint
  | Series of { paint : Masc_tui_theme.paint; series : Masc_tui_theme.series }
  | Anomaly of { paint : Masc_tui_theme.paint; alarm : alarm }

and alarm =
  | Alarm_warn
  | Alarm_bad

let alarm_status = function
  | Alarm_warn -> Masc_tui_theme.Warn
  | Alarm_bad -> Masc_tui_theme.Bad

(* How far along the bar a filled cell reaches: its far edge, unless the value
   stops short of it, so the last cell takes the colour of the value it draws
   and never one past it. *)
let cell_reach ~index ~width ~value ~max_value =
  let width = Stdlib.max 1 width in
  let max_value = Stdlib.max 1 max_value in
  let value = Stdlib.max 0 (Stdlib.min max_value value) in
  Float.min
    (float_of_int (Stdlib.min width (index + 1)) /. float_of_int width)
    (float_of_int value /. float_of_int max_value)
;;

let meter_cell_style scale ~index ~width ~value ~max_value =
  match scale with
  | Declared_limit paint ->
    Masc_tui_theme.meter_cell_readable paint
      (Masc_tui_theme.limit_cell_colour ~depth:paint.Masc_tui_theme.depth ~index
         ~width ~value ~limit:max_value)
  | Series { paint; series } ->
    Masc_tui_theme.ramp_style paint series
      ~position:(cell_reach ~index ~width ~value ~max_value)
  | Anomaly { paint; alarm } -> (
    match paint.Masc_tui_theme.depth with
    | Masc_tui_theme.No_color -> ""
    | Masc_tui_theme.Colors_16 | Masc_tui_theme.Colors_256 | Masc_tui_theme.Truecolor ->
      Masc_tui_theme.status_readable ~surface:paint.Masc_tui_theme.surface
        paint.Masc_tui_theme.palette (alarm_status alarm))
;;

(* Text-readable SGR for a meter's numeric readout. Declared limits and
   anomalies enforce 4.5:1 across their full range, so a one-cell bar
   ([edge / width = 1.0]) evaluates the exact [clamped / max_value] share
   without quantization. Series ramps lift only their bright end (position 1.0)
   to the 4.5:1 text floor (the deep end uses the 3:1 non-text picture floor),
   so series text readouts read position 1.0 to keep the series hue legible. *)
let meter_tip_style scale ~value ~max_value =
  if value <= 0 || max_value <= 0 then ""
  else
    let clamped = Stdlib.min value max_value in
    match scale with
    | Declared_limit _ | Anomaly _ ->
      meter_cell_style scale ~index:0 ~width:1 ~value:clamped ~max_value
    | Series { paint; series } ->
      Masc_tui_theme.ramp_style paint series ~position:1.0
;;

(* [meter_cell_style] for every cell of one bar, with a series ramp's table
   found once for the whole bar. *)
let meter_cell_styler scale ~width ~value ~max_value =
  match scale with
  | Series { paint; series } ->
    let read = Masc_tui_theme.ramp_reader paint series in
    fun ~index -> read ~position:(cell_reach ~index ~width ~value ~max_value)
  | Declared_limit _ | Anomaly _ ->
    fun ~index -> meter_cell_style scale ~index ~width ~value ~max_value
;;

(* Neighbouring cells of a ramp often round to the same colour; the code goes
   out only where it changes, and one reset closes the run. *)
let styled_run ~reset styled =
  let buffer = Buffer.create 64 in
  let last =
    List.fold_left
      (fun last (style, glyph) ->
        if not (String.equal style last) then
          (* An empty style is the foreground, which only a reset gives back. *)
          Buffer.add_string buffer (if String.equal style "" then reset else style);
        Buffer.add_string buffer glyph;
        style)
      "" styled
  in
  if not (String.equal last "") then Buffer.add_string buffer reset;
  Buffer.contents buffer
;;

let meter_fill_run ~scale ~width ~value ~max_value ~reset glyphs =
  let style = meter_cell_styler scale ~width ~value ~max_value in
  styled_run ~reset (List.mapi (fun index glyph -> (style ~index, glyph)) glyphs)
;;

let track_segment ~track_style ~reset count =
  if count <= 0 then ""
  else if String.equal track_style "" then repeat meter_track count
  else track_style ^ repeat meter_track count ^ reset
;;

let meter_bar ~width ~value ~max_value ~scale ?(track_style = "")
    ?(reset = Masc_tui_theme.Sgr.reset) () =
  if width <= 0 then ""
  else
    let filled = bar_filled_cells ~width ~value ~max_value in
    let unfilled = Stdlib.max 0 (width - filled) in
    let filled_part =
      meter_fill_run ~scale ~width ~value ~max_value ~reset
        (List.init (Stdlib.max 0 filled) (fun _ -> meter_fill))
    in
    filled_part ^ track_segment ~track_style ~reset unfilled
;;

let dot_meter_bar ~width ~value ~max_value ~scale ?(track_style = "")
    ?(reset = Masc_tui_theme.Sgr.reset) () =
  if width <= 0 then ""
  else
    let clamped_val =
      Stdlib.max 0 (if max_value > 0 then Stdlib.min value max_value else value)
    in
    let subcells = 2 * width in
    let filled_subs = bar_filled_cells ~width:subcells ~value:clamped_val ~max_value in
    let full_cells = Stdlib.min width (filled_subs / 2) in
    let has_half = full_cells < width && filled_subs mod 2 = 1 in
    let glyphs =
      List.init full_cells (fun _ -> dot_fill_full)
      @ (if has_half then [ dot_fill_half ] else [])
    in
    let filled_count = List.length glyphs in
    let unfilled = Stdlib.max 0 (width - filled_count) in
    let filled_part =
      meter_fill_run ~scale ~width ~value ~max_value ~reset glyphs
    in
    filled_part ^ track_segment ~track_style ~reset unfilled
;;

let meter_with ~draw_bar ~width ~value ~max_value ~scale ?label ?(label_style = "")
    ?suffix ?(track_style = "") ?suffix_style
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
      | Some l when l <> "" ->
        if String.equal label_style "" then l ^ " "
        else label_style ^ l ^ reset ^ " "
      | Some _ | None -> ""
    in
    let raw_suffix =
      match suffix with
      | Some s -> s
      | None -> Printf.sprintf "%3d%%" pct
    in
    let resolved_suffix_style =
      match suffix_style with
      | Some s -> s
      | None -> meter_tip_style scale ~value:clamped_val ~max_value
    in
    let styled_suffix =
      if String.equal raw_suffix "" then ""
      else if String.equal resolved_suffix_style "" then " " ^ raw_suffix
      else " " ^ resolved_suffix_style ^ raw_suffix ^ reset
    in
    let suffix_cells =
      if String.equal raw_suffix "" then 0
      else 1 + Layout.display_width raw_suffix
    in
    let chrome_cells = Layout.display_width prefix + suffix_cells in
    if width >= chrome_cells + 3 then
      let bar_width = width - chrome_cells in
      prefix
      ^ draw_bar ~width:bar_width ~value:clamped_val ~max_value ~scale
          ~track_style ~reset ()
      ^ styled_suffix
    else
      let fallback =
        if String.equal raw_suffix "" then Printf.sprintf "%d%%" pct
        else raw_suffix
      in
      let styled_fallback =
        if String.equal resolved_suffix_style "" then fallback
        else resolved_suffix_style ^ fallback ^ reset
      in
      Layout.fit_width (prefix ^ styled_fallback) width
;;

let meter =
  meter_with ~draw_bar:(fun ~width ~value ~max_value ~scale ~track_style ~reset () ->
    meter_bar ~width ~value ~max_value ~scale ~track_style ~reset ())
;;

let dot_meter =
  meter_with ~draw_bar:(fun ~width ~value ~max_value ~scale ~track_style ~reset () ->
    dot_meter_bar ~width ~value ~max_value ~scale ~track_style ~reset ())
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
