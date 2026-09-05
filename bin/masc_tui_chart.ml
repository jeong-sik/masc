(** Visual charting and graphing primitives for the MASC TUI. *)

module Layout = Masc_tui_message_layout

type style =
  | Status of Masc_tui_theme.status
  | Tone of Masc_tui_theme.tone

let render_style = function
  | Status s -> Masc_tui_theme.status s
  | Tone t -> Masc_tui_theme.tone t
;;

let bar_full = "\xe2\x96\x88" (* U+2588 FULL BLOCK *)
let bar_dark = "\xe2\x96\x93" (* U+2593 DARK SHADE *)
let bar_medium = "\xe2\x96\x92" (* U+2592 MEDIUM SHADE *)
let bar_light = "\xe2\x96\x91" (* U+2591 LIGHT SHADE *)
let dot_empty = "\xc2\xb7" (* U+00B7 MIDDLE DOT *)

let glyph_block_1 = "\xe2\x96\x81" (* U+2581 *)
let glyph_block_2 = "\xe2\x96\x82" (* U+2582 *)
let glyph_block_3 = "\xe2\x96\x83" (* U+2583 *)
let glyph_block_4 = "\xe2\x96\x84" (* U+2584 *)
let glyph_block_5 = "\xe2\x96\x85" (* U+2585 *)
let glyph_block_6 = "\xe2\x96\x86" (* U+2586 *)
let glyph_block_7 = "\xe2\x96\x87" (* U+2587 *)
let glyph_block_8 = "\xe2\x96\x88" (* U+2588 *)

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

let sparkline ?min ?max values =
  match values with
  | [] -> ""
  | _ ->
    let v_min =
      match min with
      | Some m -> m
      | None -> List.fold_left Stdlib.min (List.hd values) values
    in
    let v_max =
      match max with
      | Some m -> m
      | None -> List.fold_left Stdlib.max (List.hd values) values
    in
    let range = v_max - v_min in
    let buf = Buffer.create (List.length values * 3) in
    List.iter
      (fun v ->
        let level =
          if range <= 0 then
            if v_min <= 0 then 0 else 3
          else
            let clamped_v = Stdlib.max v_min (Stdlib.min v_max v) in
            let raw = ((clamped_v - v_min) * 7) / range in
            Stdlib.max 0 (Stdlib.min 7 raw)
        in
        Buffer.add_string buf sparkline_glyphs.(level))
      values;
    Buffer.contents buf
;;

let sparkline_colored ?min ?max ~style_of_level values =
  match values with
  | [] -> ""
  | _ ->
    let v_min =
      match min with
      | Some m -> m
      | None -> List.fold_left Stdlib.min (List.hd values) values
    in
    let v_max =
      match max with
      | Some m -> m
      | None -> List.fold_left Stdlib.max (List.hd values) values
    in
    let range = v_max - v_min in
    let buf = Buffer.create (List.length values * 16) in
    List.iter
      (fun v ->
        let level =
          if range <= 0 then
            if v_min <= 0 then 0 else 3
          else
            let clamped_v = Stdlib.max v_min (Stdlib.min v_max v) in
            let raw = ((clamped_v - v_min) * 7) / range in
            Stdlib.max 0 (Stdlib.min 7 raw)
        in
        let st = style_of_level level in
        Buffer.add_string buf (render_style st);
        Buffer.add_string buf sparkline_glyphs.(level);
        Buffer.add_string buf Masc_tui_theme.Sgr.reset)
      values;
    Buffer.contents buf
;;

type gauge_thresholds = {
  warn_percent : int;
  bad_percent : int;
}

let default_gauge_thresholds = {
  warn_percent = 70;
  bad_percent = 85;
}

let format_compact_num n =
  if n = min_int then "-4.6M"
  else
    let abs_n = abs n in
    if abs_n >= 1_000_000 then
      Printf.sprintf "%.1fM" (float_of_int n /. 1_000_000.0)
    else if abs_n >= 10_000 then
      Printf.sprintf "%dk" (n / 1_000)
    else if abs_n >= 1_000 then
      Printf.sprintf "%.1fk" (float_of_int n /. 1_000.0)
    else
      string_of_int n
;;

let gauge ~width ~value ~max_value ?(thresholds = default_gauge_thresholds) ?label () =
  if width <= 0 then ""
  else
    let clamped_val = Stdlib.max 0 (if max_value > 0 then Stdlib.min value max_value else value) in
    let pct =
      if max_value <= 0 then 0
      else Stdlib.min 100 ((clamped_val * 100) / max_value)
    in
    let status_style =
      if pct >= thresholds.bad_percent then Masc_tui_theme.status Bad
      else if pct >= thresholds.warn_percent then Masc_tui_theme.status Warn
      else Masc_tui_theme.status Ok
    in
    let prefix = match label with Some l -> l ^ " " | None -> "" in
    let prefix_cells = Layout.display_width prefix in
    let full_suffix = Printf.sprintf " %d%% (%s / %s)" pct (format_compact_num value) (format_compact_num max_value) in
    let full_suffix_cells = Layout.display_width full_suffix in
    let chrome_cells = prefix_cells + full_suffix_cells + 2 in
    if width >= chrome_cells + 4 then
      let bar_width = width - chrome_cells in
      let filled =
        if max_value <= 0 || clamped_val <= 0 then 0
        else Stdlib.max 1 (Stdlib.min bar_width ((clamped_val * bar_width) / max_value))
      in
      let unfilled = Stdlib.max 0 (bar_width - filled) in
      prefix ^ "[" ^ status_style ^ repeat bar_full filled ^ Masc_tui_theme.Sgr.dim
      ^ repeat bar_light unfilled ^ Masc_tui_theme.Sgr.reset ^ "]" ^ full_suffix
    else
      let short_suffix = Printf.sprintf " %d%%" pct in
      let short_chrome = prefix_cells + Layout.display_width short_suffix + 2 in
      if width >= short_chrome + 2 then
        let bar_width = width - short_chrome in
        let filled =
          if max_value <= 0 || clamped_val <= 0 then 0
          else Stdlib.max 1 (Stdlib.min bar_width ((clamped_val * bar_width) / max_value))
        in
        let unfilled = Stdlib.max 0 (bar_width - filled) in
        prefix ^ "[" ^ status_style ^ repeat bar_full filled ^ Masc_tui_theme.Sgr.dim
        ^ repeat bar_light unfilled ^ Masc_tui_theme.Sgr.reset ^ "]" ^ short_suffix
      else
        Layout.fit_width (Printf.sprintf "%s%d%%" prefix pct) width
;;

type waterfall_step = {
  label : string;
  duration_ms : int;
  style : style option;
}

let waterfall ~width ?total_ms steps =
  if width <= 0 || steps = [] then []
  else
    let computed_total =
      match total_ms with
      | Some t when t > 0 -> t
      | _ ->
        let sum = List.fold_left (fun acc s -> acc + Stdlib.max 0 s.duration_ms) 0 steps in
        if sum <= 0 then 1 else sum
    in
    let len = List.length steps in
    let max_label_len =
      List.fold_left (fun acc s -> Stdlib.max acc (Layout.display_width s.label)) 0 steps
    in
    let label_col_width = Stdlib.min 20 (Stdlib.max 6 max_label_len) in
    (* fixed cells: indent (2) + tree (3) + label (label_col_width) + " : " (3) + "  " (2) + duration (7) + " " (1) + pct (6) = label_col_width + 24 *)
    let fixed_cols = 2 + 3 + label_col_width + 3 + 2 + 7 + 1 + 6 in
    let bar_width = Stdlib.max 0 (width - fixed_cols) in
    List.mapi
      (fun i step ->
        let is_last = (i = len - 1) in
        let tree = if is_last then "\xe2\x94\x94\xe2\x94\x80 " else "\xe2\x94\x9c\xe2\x94\x80 " in (* └─ vs ├─ *)
        let duration = Stdlib.max 0 step.duration_ms in
        let pct = (duration * 100) / computed_total in
        let color_start =
          match step.style with
          | Some s -> render_style s
          | None -> Masc_tui_theme.tone Accent
        in
        let duration_str =
          if duration >= 1000 then
            Printf.sprintf "%5.2fs" (float_of_int duration /. 1000.0)
          else
            Printf.sprintf "%5dms" duration
        in
        let padded_label = Layout.fit_width step.label label_col_width in
        if bar_width <= 0 then
          Layout.fit_width
            (Printf.sprintf "  %s%s : %s %s (%2d%%)"
               tree padded_label color_start duration_str pct)
            width
        else
          let filled =
            if duration <= 0 then 0
            else Stdlib.max 1 (Stdlib.min bar_width ((duration * bar_width) / computed_total))
          in
          let unfilled = Stdlib.max 0 (bar_width - filled) in
          Printf.sprintf "  %s%s : %s%s%s%s%s  %s (%2d%%)"
            tree
            padded_label
            color_start
            (repeat bar_full filled)
            Masc_tui_theme.Sgr.dim
            (repeat bar_light unfilled)
            Masc_tui_theme.Sgr.reset
            duration_str
            pct)
      steps
;;

let heatmap_glyphs = [| " "; bar_light; bar_medium; bar_dark; bar_full |]

let heatmap_row ?max_val ?(empty_glyph = dot_empty) buckets =
  if buckets = [] then ""
  else
    let effective_max =
      match max_val with
      | Some m -> m
      | None -> List.fold_left Stdlib.max 0 buckets
    in
    let buf = Buffer.create (List.length buckets * 16) in
    List.iter
      (fun count ->
        if count <= 0 then
          Buffer.add_string buf (Masc_tui_theme.tone Dim ^ empty_glyph ^ Masc_tui_theme.Sgr.reset)
        else if effective_max <= 0 then
          Buffer.add_string buf empty_glyph
        else
          let level = 1 + (((count - 1) * 3) / Stdlib.max 1 (effective_max - 1)) in
          let glyph = heatmap_glyphs.(Stdlib.min 4 (Stdlib.max 1 level)) in
          let style =
            if level >= 4 then Masc_tui_theme.status Bad
            else if level >= 3 then Masc_tui_theme.status Warn
            else if level >= 2 then Masc_tui_theme.tone Accent
            else Masc_tui_theme.tone Dim
          in
          Buffer.add_string buf (style ^ glyph ^ Masc_tui_theme.Sgr.reset))
      buckets;
    Buffer.contents buf
;;

let heatmap_24h ?label hours =
  let arr = Array.make 24 0 in
  List.iteri (fun i h -> if i < 24 then arr.(i) <- Stdlib.max 0 h) hours;
  let global_peak = Array.fold_left Stdlib.max 0 arr in
  let first_12 = Array.to_list (Array.sub arr 0 12) in
  let last_12 = Array.to_list (Array.sub arr 12 12) in
  let header =
    match label with
    | Some l -> [ Printf.sprintf "  %s%s%s (Peak: %d/h)" Masc_tui_theme.Sgr.bold l Masc_tui_theme.Sgr.reset global_peak ]
    | None -> []
  in
  let row1 = "  00:00 " ^ heatmap_row ~max_val:global_peak first_12 ^ " 12:00" in
  let row2 = "  12:00 " ^ heatmap_row ~max_val:global_peak last_12 ^ " 24:00" in
  header @ [ row1; row2 ]
;;

type bar_item = {
  name : string;
  count : int;
  style : style option;
}

let distribution_bars ~width items =
  if width <= 0 || items = [] then []
  else
    let total = List.fold_left (fun acc it -> acc + Stdlib.max 0 it.count) 0 items in
    let max_count = List.fold_left (fun acc it -> Stdlib.max acc it.count) 0 items in
    let max_name_len = List.fold_left (fun acc it -> Stdlib.max acc (Layout.display_width it.name)) 0 items in
    let name_col_width = Stdlib.min 18 (Stdlib.max 6 max_name_len) in
    (* fixed: "  " (2) + name (name_col_width) + "  " (2) + " " (1) + count (5) + " " (1) + "(xxx%)" (6) = name_col_width + 17 *)
    let fixed_cols = 2 + name_col_width + 2 + 1 + 5 + 1 + 6 in
    let bar_width = Stdlib.max 0 (width - fixed_cols) in
    List.map
      (fun it ->
        let count = Stdlib.max 0 it.count in
        let pct = if total <= 0 then 0 else (count * 100) / total in
        let color =
          match it.style with
          | Some s -> render_style s
          | None -> Masc_tui_theme.tone Accent
        in
        let padded_name = Layout.fit_width it.name name_col_width in
        if bar_width <= 0 then
          Layout.fit_width
            (Printf.sprintf "  %s  %s%5d (%2d%%)%s"
               padded_name color count pct Masc_tui_theme.Sgr.reset)
            width
        else
          let filled =
            if max_count <= 0 || count <= 0 then 0
            else Stdlib.max 1 (Stdlib.min bar_width ((count * bar_width) / max_count))
          in
          let unfilled = Stdlib.max 0 (bar_width - filled) in
          Printf.sprintf "  %s  %s%s%s%s%s %5d (%2d%%)"
            padded_name
            color
            (repeat bar_full filled)
            Masc_tui_theme.Sgr.dim
            (repeat bar_light unfilled)
            Masc_tui_theme.Sgr.reset
            count
            pct)
      items
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

let dot_mask ~dx ~dy =
  match dx, dy with
  | 0, 0 -> 0x01
  | 0, 1 -> 0x02
  | 0, 2 -> 0x04
  | 0, 3 -> 0x40
  | 1, 0 -> 0x08
  | 1, 1 -> 0x10
  | 1, 2 -> 0x20
  | 1, 3 -> 0x80
  | _ -> 0
;;

let sanitize_float f =
  if Float.is_nan f || Float.is_infinite f then 0.0 else f
;;

let braille_plot ~width ~height ?min_val ?max_val points =
  if width <= 0 || height <= 0 || points = [] then []
  else
    let safe_points = List.map sanitize_float points in
    let v_min =
      match min_val with
      | Some m -> sanitize_float m
      | None -> List.fold_left Float.min (List.hd safe_points) safe_points
    in
    let v_max =
      match max_val with
      | Some m -> sanitize_float m
      | None -> List.fold_left Float.max (List.hd safe_points) safe_points
    in
    let range = if v_max -. v_min <= 0.0 then 1.0 else v_max -. v_min in
    let grid = Array.make_matrix height width 0 in
    let pixel_width = width * 2 in
    let pixel_height = height * 4 in
    let pts_arr = Array.of_list safe_points in
    let pts_len = Array.length pts_arr in
    let prev_y = ref None in
    for x = 0 to pixel_width - 1 do
      let v =
        if pts_len = 1 then pts_arr.(0)
        else
          let t = float_of_int x *. float_of_int (pts_len - 1) /. float_of_int (pixel_width - 1) in
          let i0 = int_of_float t in
          let i1 = Stdlib.min (pts_len - 1) (i0 + 1) in
          let frac = t -. float_of_int i0 in
          let v0 = pts_arr.(i0) in
          let v1 = pts_arr.(i1) in
          v0 +. frac *. (v1 -. v0)
      in
      let norm = (v -. v_min) /. range in
      let norm_clamped = Float.max 0.0 (Float.min 1.0 norm) in
      let y_pixel =
        int_of_float ((1.0 -. norm_clamped) *. float_of_int (pixel_height - 1))
      in
      let y_start, y_end =
        match !prev_y with
        | None -> y_pixel, y_pixel
        | Some py -> Stdlib.min py y_pixel, Stdlib.max py y_pixel
      in
      prev_y := Some y_pixel;
      for y = y_start to y_end do
        let cx = x / 2 in
        let dx = x mod 2 in
        let cy = y / 4 in
        let dy = y mod 4 in
        if cy >= 0 && cy < height && cx >= 0 && cx < width then
          grid.(cy).(cx) <- grid.(cy).(cx) lor (dot_mask ~dx ~dy)
      done
    done;
    let rows = ref [] in
    for r = 0 to height - 1 do
      let row_buf = Buffer.create (width * 3) in
      for c = 0 to width - 1 do
        Buffer.add_string row_buf (braille_cell ~mask:grid.(r).(c))
      done;
      rows := (Buffer.contents row_buf) :: !rows
    done;
    List.rev !rows
;;
