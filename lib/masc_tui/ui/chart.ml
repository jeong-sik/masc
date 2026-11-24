module Format_val = Masc_tui_core.Format_val
module Glyph = Masc_tui_core.Glyph
module Observed = Masc_tui_core.Observed
module Rect = Masc_tui_core.Rect
module Say = Masc_tui_core.Say
module Theme = Masc_tui_core.Theme
module Attr = Masc_tui_term.Attr
module Color = Masc_tui_term.Color
module Style = Masc_tui_term.Style
module Grapheme = Masc_tui_term.Grapheme
module Cell_grid = Masc_tui_term.Cell_grid
module Presenter = Masc_tui_term.Presenter

module Time_window = struct
  type t =
    | Last_5m
    | Last_1h
    | Last_24h
    | Last_7d
    | Last_14d
    | Last_30d
    | Rev_span of { from_rev : int; to_rev : int }

  let label = function
    | Last_5m -> "5m"
    | Last_1h -> "1h"
    | Last_24h -> "24h"
    | Last_7d -> "7d"
    | Last_14d -> "14d"
    | Last_30d -> "30d"
    | Rev_span { from_rev; to_rev } -> Printf.sprintf "r%d..r%d" from_rev to_rev

  let ticks = function
    | Last_5m -> ("-5m", "-2.5m", "now")
    | Last_1h -> ("-1h", "-30m", "now")
    | Last_24h -> ("-24h", "-12h", "now")
    | Last_7d -> ("-7d", "-3.5d", "now")
    | Last_14d -> ("-14d", "-7d", "now")
    | Last_30d -> ("-30d", "-15d", "now")
    | Rev_span { from_rev; to_rev } ->
        let mid = (from_rev + to_rev) / 2 in
        ( Printf.sprintf "r%d" from_rev
        , Printf.sprintf "r%d" mid
        , Printf.sprintf "r%d" to_rev )
end

module Gradient = struct
  type t =
    | Thermal
    | Cool_flow
    | Warm_flow
    | Efficiency
    | Ai_flow
    | Semantic_fixed of Theme.status_token

  let violet = Ai_flow

  let sample_rgb theme grad ratio =
    match grad with
    | Thermal -> Theme.gradient_sample theme Theme.Thermal ratio
    | Cool_flow -> Theme.gradient_sample theme Theme.Cool_flow ratio
    | Warm_flow -> Theme.gradient_sample theme Theme.Warm_flow ratio
    | Efficiency -> Theme.gradient_sample theme Theme.Efficiency ratio
    | Ai_flow -> Theme.gradient_sample theme Theme.Ai_flow ratio
    | Semantic_fixed tok -> Theme.status_color theme tok
end

module Scale = struct
  type t =
    | Fixed_bounds of { floor : float; ceiling : float }
    | Auto_ceil of { floor : float; nice_step : bool }
    | Synced_pair
    | Dual_independent of {
        top_min : float;
        top_max : float;
        bot_min : float;
        bot_max : float;
      }

  let nice_ceiling raw =
    if (not (Float.is_finite raw)) || raw <= 0.0 then 1.0
    else
      let exp = Float.floor (Float.log10 raw) in
      let mag = 10.0 ** exp in
      let frac = raw /. mag in
      let step =
        if frac <= 1.0 then 1.0
        else if frac <= 2.0 then 2.0
        else if frac <= 5.0 then 5.0
        else 10.0
      in
      step *. mag
end

module Series = struct
  type sample =
    | Unread
    | Absent
    | Zero
    | Value of float

  type t = {
    label : Say.t;
    unit : Format_val.unit_kind;
    gradient : Gradient.t;
    samples : sample array;
    current : float Observed.t;
    peak : float Observed.t;
    avg : float Observed.t;
    delta_pct : float option;
  }

  let sample_dot_level ~dots ~floor ~ceiling sample =
    let dots = Int.max 2 dots in
    match sample with
    | Unread | Absent -> 0
    | Zero -> 1
    | Value v when (not (Float.is_finite v)) || v < 0.0 -> 0
    | Value v when v = 0.0 -> 1
    | Value v ->
        let span = ceiling -. floor in
        if (not (Float.is_finite span)) || span <= 0.0 then dots
        else
          let norm = Float.max 0.0 (Float.min 1.0 ((v -. floor) /. span)) in
          let above = dots - 1 in
          let scaled = int_of_float (Float.round (norm *. float_of_int above)) in
          1 + Int.max 1 (Int.min above scaled)

  let merge_bucket a b =
    match (a, b) with
    | Value x, Value y -> Value (Float.max x y)
    | Value x, (Zero | Absent | Unread) -> Value x
    | (Zero | Absent | Unread), Value y -> Value y
    | Zero, (Zero | Absent | Unread) -> Zero
    | (Absent | Unread), Zero -> Zero
    | Absent, (Absent | Unread) -> Absent
    | Unread, Absent -> Absent
    | Unread, Unread -> Unread

  let is_nonneg_finite v = Float.is_finite v && v >= 0.0

  let interpolate_pair ~t a b =
    match (a, b) with
    | Value x, Value y when is_nonneg_finite x && is_nonneg_finite y ->
        let v = x +. (t *. (y -. x)) in
        if v <= 0.0 then Zero else Value v
    | Value x, Zero when is_nonneg_finite x ->
        let v = x *. (1.0 -. t) in
        if v <= 0.0 then Zero else Value v
    | Zero, Value y when is_nonneg_finite y ->
        let v = y *. t in
        if v <= 0.0 then Zero else Value v
    | Zero, Zero -> Zero
    | (Value _ | Zero | Absent | Unread), (Value _ | Zero | Absent | Unread) ->
        if t < 0.5 then a else b

  let resample_peak_preserving ~target_len samples =
    let target_len = Int.max 0 target_len in
    let n = Array.length samples in
    if target_len = 0 then [||]
    else if n = 0 then Array.make target_len Absent
    else if n = target_len then Array.copy samples
    else if n = 1 then
      Array.init target_len (fun i ->
          if i = target_len - 1 then samples.(0) else Absent)
    else if n < target_len then
      let denom = float_of_int (target_len - 1) in
      let max_idx = float_of_int (n - 1) in
      Array.init target_len (fun i ->
          if i = 0 then samples.(0)
          else if i = target_len - 1 then samples.(n - 1)
          else
            let pos = float_of_int i *. max_idx /. denom in
            let lo =
              Int.max 0 (Int.min (n - 2) (int_of_float (Float.floor pos)))
            in
            let hi = lo + 1 in
            let t = Float.max 0.0 (Float.min 1.0 (pos -. float_of_int lo)) in
            interpolate_pair ~t samples.(lo) samples.(hi))
    else
      Array.init target_len (fun bucket ->
          let lo = (bucket * n) / target_len in
          let hi = Int.max (lo + 1) (((bucket + 1) * n) / target_len) in
          let hi = Int.min n hi in
          let acc = ref samples.(lo) in
          for idx = lo + 1 to hi - 1 do
            acc := merge_bucket !acc samples.(idx)
          done;
          !acc)
end

module Spec = struct
  type kind =
    | Time_series of {
        series : Series.t;
        scale : Scale.t;
        window : Time_window.t;
      }
    | Dual_inverted of {
        upper : Series.t;
        lower : Series.t;
        scale : Scale.t;
        window : Time_window.t;
      }
    | Ratio_gauge of {
        used : float Observed.t;
        limit : float Observed.t;
        unit : Format_val.unit_kind;
        gradient : Gradient.t;
        reset_hint : Say.t option;
      }
    | Stacked_bar of {
        segments : (Say.t * float * Theme.status_token) list;
        total_label : Say.t;
        unit : Format_val.unit_kind;
      }

  type t = {
    title : Say.t;
    kind : kind;
    hotkey_hint : string option;
  }
end

module Render_mode = struct
  type glyph_tier =
    | Braille_2x4
    | Block_vertical
    | Ascii_tty

  type gauge_glyphs =
    | Eighth_block
    | Half_block
    | Ascii_gauge

  type spark_glyphs =
    | Spark_eighth_block
    | Spark_ascii

  type layout_mode =
    | Full_area_chart of {
        glyphs : glyph_tier;
        plot_cols : int;
        plot_rows : int;
        show_y_axis : bool;
        show_x_ticks : bool;
        show_inline_legend : bool;
      }
    | Dual_mirror_chart of {
        glyphs : glyph_tier;
        plot_cols : int;
        half_rows : int;
        show_y_axis : bool;
        show_inline_legend : bool;
      }
    | Half_block_gauge of {
        glyphs : gauge_glyphs;
        bar_cols : int;
        multiline_detail : bool;
      }
    | Inline_sparkline of {
        glyphs : spark_glyphs;
        spark_cols : int;
      }
    | Numeric_delta_pill

  let glyph_tier_rank = function
    | Braille_2x4 -> 0
    | Block_vertical -> 1
    | Ascii_tty -> 2

  let equal_glyph_tier a b = Int.equal (glyph_tier_rank a) (glyph_tier_rank b)

  let gauge_glyphs_rank = function
    | Eighth_block -> 0
    | Half_block -> 1
    | Ascii_gauge -> 2

  let equal_gauge_glyphs a b =
    Int.equal (gauge_glyphs_rank a) (gauge_glyphs_rank b)

  let spark_glyphs_rank = function
    | Spark_eighth_block -> 0
    | Spark_ascii -> 1

  let equal_spark_glyphs a b =
    Int.equal (spark_glyphs_rank a) (spark_glyphs_rank b)

  let equal_layout_mode a b =
    match (a, b) with
    | Full_area_chart x, Full_area_chart y ->
        equal_glyph_tier x.glyphs y.glyphs
        && Int.equal x.plot_cols y.plot_cols
        && Int.equal x.plot_rows y.plot_rows
        && Bool.equal x.show_y_axis y.show_y_axis
        && Bool.equal x.show_x_ticks y.show_x_ticks
        && Bool.equal x.show_inline_legend y.show_inline_legend
    | Dual_mirror_chart x, Dual_mirror_chart y ->
        equal_glyph_tier x.glyphs y.glyphs
        && Int.equal x.plot_cols y.plot_cols
        && Int.equal x.half_rows y.half_rows
        && Bool.equal x.show_y_axis y.show_y_axis
        && Bool.equal x.show_inline_legend y.show_inline_legend
    | Half_block_gauge x, Half_block_gauge y ->
        equal_gauge_glyphs x.glyphs y.glyphs
        && Int.equal x.bar_cols y.bar_cols
        && Bool.equal x.multiline_detail y.multiline_detail
    | Inline_sparkline x, Inline_sparkline y ->
        equal_spark_glyphs x.glyphs y.glyphs
        && Int.equal x.spark_cols y.spark_cols
    | Numeric_delta_pill, Numeric_delta_pill -> true
    | ( Full_area_chart _
      | Dual_mirror_chart _
      | Half_block_gauge _
      | Inline_sparkline _
      | Numeric_delta_pill ),
      _ ->
        false

  let select_glyph_tier ~(caps : Presenter.capabilities) =
    if caps.braille_safe && caps.unicode_blocks then Braille_2x4
    else if caps.unicode_blocks then Block_vertical
    else Ascii_tty

  let y_axis_gutter = 8

  let resolve ~avail_w ~avail_h ~(caps : Presenter.capabilities) (spec : Spec.t) =
    let glyphs = select_glyph_tier ~caps in
    let spark_g =
      if caps.unicode_blocks then Spark_eighth_block else Spark_ascii
    in
    let gauge_g =
      if caps.unicode_blocks then Eighth_block else Ascii_gauge
    in
    match spec.kind with
    | Spec.Time_series _ ->
        if avail_w >= 36 && avail_h >= 6 then
          Full_area_chart
            {
              glyphs;
              plot_cols = Int.max 4 (avail_w - y_axis_gutter);
              plot_rows = Int.max 1 (avail_h - 2);
              show_y_axis = true;
              show_x_ticks = true;
              show_inline_legend = true;
            }
        else if avail_w >= 20 && avail_h >= 3 then
          let show_y_axis = avail_w >= 28 in
          let gutter = if show_y_axis then y_axis_gutter else 0 in
          Full_area_chart
            {
              glyphs;
              plot_cols = Int.max 4 (avail_w - gutter);
              plot_rows = Int.max 1 (avail_h - 1);
              show_y_axis;
              show_x_ticks = false;
              show_inline_legend = true;
            }
        else if avail_w >= 12 && avail_h >= 1 then
          Inline_sparkline
            {
              glyphs = spark_g;
              spark_cols = Int.max 4 (Int.min 32 (avail_w / 2));
            }
        else Numeric_delta_pill
    | Spec.Dual_inverted _ ->
        if avail_w >= 36 && avail_h >= 6 then
          Dual_mirror_chart
            {
              glyphs;
              plot_cols = Int.max 4 (avail_w - y_axis_gutter);
              half_rows = Int.max 2 ((avail_h - 3) / 2);
              show_y_axis = true;
              show_inline_legend = true;
            }
        else if avail_w >= 20 && avail_h >= 2 then
          Inline_sparkline
            {
              glyphs = spark_g;
              spark_cols = Int.max 4 (Int.min 28 (avail_w - 14));
            }
        else Numeric_delta_pill
    | Spec.Ratio_gauge _ ->
        if avail_w >= 24 && avail_h >= 1 then
          Half_block_gauge
            {
              glyphs = gauge_g;
              bar_cols = Int.max 8 (Int.min 40 (avail_w / 2));
              multiline_detail = avail_h >= 2;
            }
        else Numeric_delta_pill
    | Spec.Stacked_bar _ ->
        if avail_w >= 24 && avail_h >= 1 then
          Half_block_gauge
            {
              glyphs = gauge_g;
              bar_cols = avail_w;
              multiline_detail = avail_h >= 2;
            }
        else Numeric_delta_pill
end

(* Static Unicode LUTs (zero per-cell heap allocations). *)
let braille_left_up = [| 0x00; 0x40; 0x44; 0x46; 0x47 |]
let braille_right_up = [| 0x00; 0x80; 0xA0; 0xB0; 0xB8 |]
let braille_left_down = [| 0x00; 0x01; 0x03; 0x07; 0x47 |]
let braille_right_down = [| 0x00; 0x08; 0x18; 0x38; 0xB8 |]

let spark_unicode_lut =
  [|
    " ";
    "\xe2\x96\x81"; (* ▁ *)
    "\xe2\x96\x82"; (* ▂ *)
    "\xe2\x96\x83"; (* ▃ *)
    "\xe2\x96\x84"; (* ▄ *)
    "\xe2\x96\x85"; (* ▅ *)
    "\xe2\x96\x86"; (* ▆ *)
    "\xe2\x96\x87"; (* ▇ *)
    "\xe2\x96\x88"; (* █ *)
  |]

let spark_ascii_lut = [| ' '; '.'; ':'; '-'; '='; '+'; '*'; '#'; '@' |]

let eighth_block_lut =
  [|
    " ";
    "\xe2\x96\x8f"; (* ▏ *)
    "\xe2\x96\x8e"; (* ▎ *)
    "\xe2\x96\x8d"; (* ▍ *)
    "\xe2\x96\x8c"; (* ▌ *)
    "\xe2\x96\x8b"; (* ▋ *)
    "\xe2\x96\x8a"; (* ▊ *)
    "\xe2\x96\x89"; (* ▉ *)
    "\xe2\x96\x88"; (* █ *)
  |]

let block_vert_up_lut =
  [|
    " ";
    "\xe2\x96\x82"; (* ▂ *)
    "\xe2\x96\x84"; (* ▄ *)
    "\xe2\x96\x86"; (* ▆ *)
    "\xe2\x96\x88"; (* █ *)
  |]

let block_vert_down_lut =
  [|
    " ";
    "\xe2\x96\x94"; (* ▔ *)
    "\xe2\x96\x80"; (* ▀ *)
    "\xe2\x96\x80"; (* ▀ *)
    "\xe2\x96\x88"; (* █ *)
  |]

let ascii_vert_lut = [| ' '; '.'; ':'; '='; '#' |]
let track_unicode = "\xe2\x96\x91" (* ░ *)
let full_block_utf8 = "\xe2\x96\x88" (* █ *)

let series_max_value (samples : Series.sample array) =
  Array.fold_left
    (fun acc s ->
      match s with
      | Series.Value v when Float.is_finite v && v > acc -> v
      | Series.Value _ | Series.Zero | Series.Absent | Series.Unread -> acc)
    0.0 samples

let series_is_all_unread (samples : Series.sample array) =
  Array.length samples > 0
  && Array.for_all
       (function
         | Series.Unread -> true
         | Series.Absent | Series.Zero | Series.Value _ -> false)
       samples

let series_has_any_data (samples : Series.sample array) =
  Array.exists
    (function
      | Series.Zero | Series.Value _ -> true
      | Series.Unread | Series.Absent -> false)
    samples

let compute_bounds ~scale max_val =
  match scale with
  | Scale.Fixed_bounds { floor; ceiling } ->
      let ceil = if ceiling > floor then ceiling else floor +. 1.0 in
      (floor, ceil)
  | Scale.Auto_ceil { floor; nice_step } ->
      let raw = if max_val > floor then max_val else floor +. 1.0 in
      let ceil = if nice_step then Scale.nice_ceiling raw else raw in
      (floor, ceil)
  | Scale.Synced_pair ->
      let raw = if max_val > 0.0 then max_val else 1.0 in
      (0.0, Scale.nice_ceiling raw)
  | Scale.Dual_independent { top_min; top_max; _ } ->
      let floor = if Float.is_finite top_min then top_min else 0.0 in
      let ceil =
        if Float.is_finite top_max && top_max > floor then top_max
        else if max_val > floor then Scale.nice_ceiling max_val
        else floor +. 1.0
      in
      (floor, ceil)

let format_dual_axis_value unit_kind v =
  if not (Float.is_finite v) then Glyph.to_utf8 Glyph.Missing_unreported
  else
    match unit_kind with
    | Format_val.Usd ->
        if v >= 100.0 then Printf.sprintf "$%.0f" v
        else if v > 0.0 && v < 0.01 then Printf.sprintf "$%.3f" v
        else Format_val.format_value Format_val.Usd v
    | Format_val.Count
    | Format_val.Rate_per_sec
    | Format_val.Percent
    | Format_val.Milliseconds
    | Format_val.Bytes
    | Format_val.Tokens
    | Format_val.Candles ->
        Format_val.format_value unit_kind v

let draw_sparkline_run ?clip grid ~x ~y ~width ~(theme : Theme.t) ~bg ~unicode
    ~gradient samples =
  if width <= 0 then 0
  else if series_is_all_unread samples then begin
    let style = Style.make ~fg:(Color.of_rgb theme.text_muted) ~bg () in
    Cell_grid.put_glyph ?clip grid ~x ~y ~style Glyph.Transport_reconnecting;
    1
  end
  else
    let resampled = Series.resample_peak_preserving ~target_len:width samples in
    let max_v = series_max_value resampled in
    let ceiling = if max_v > 0.0 then max_v else 1.0 in
    let base_style = Style.make ~fg:(Color.of_rgb theme.text_muted) ~bg () in
    for i = 0 to width - 1 do
      let lvl = Series.sample_dot_level ~dots:8 ~floor:0.0 ~ceiling resampled.(i) in
      if lvl > 0 then
        let style =
          if lvl = 1 then base_style
          else
            let share = float_of_int (lvl - 2) /. 6.0 in
            let fg = Color.of_rgb (Gradient.sample_rgb theme gradient share) in
            Style.make ~fg ~bg ()
        in
        if unicode then
          Cell_grid.set_cell ?clip grid ~x:(x + i) ~y
            { glyph = Cell_grid.Utf8 spark_unicode_lut.(lvl); width = 1; style }
        else
          Cell_grid.put_ascii ?clip grid ~x:(x + i) ~y ~style spark_ascii_lut.(lvl)
    done;
    width

let draw_ratio_bar_run ?clip grid ~x ~y ~width ~(theme : Theme.t) ~bg ~unicode
    ~gradient ~ratio =
  if width <= 0 then 0
  else
    let clamped =
      if not (Float.is_finite ratio) then 0.0
      else Float.max 0.0 (Float.min 1.0 ratio)
    in
    let total_eighths = width * 8 in
    let filled_eighths =
      if clamped <= 0.0 then 0
      else if clamped >= 1.0 then total_eighths
      else Int.max 1 (int_of_float (Float.round (clamped *. float_of_int total_eighths)))
    in
    let track_style = Style.make ~fg:(Color.of_rgb theme.border_inactive) ~bg () in
    for i = 0 to width - 1 do
      let cell_eighths = Int.max 0 (Int.min 8 (filled_eighths - (i * 8))) in
      let pos =
        if width <= 1 then clamped
        else float_of_int i /. float_of_int (width - 1)
      in
      if cell_eighths = 0 then
        if unicode then
          Cell_grid.set_cell ?clip grid ~x:(x + i) ~y
            { glyph = Cell_grid.Utf8 track_unicode; width = 1; style = track_style }
        else Cell_grid.put_ascii ?clip grid ~x:(x + i) ~y ~style:track_style '-'
      else
        let fg = Color.of_rgb (Gradient.sample_rgb theme gradient pos) in
        let style = Style.make ~fg ~bg () in
        if unicode then
          Cell_grid.set_cell ?clip grid ~x:(x + i) ~y
            { glyph = Cell_grid.Utf8 eighth_block_lut.(cell_eighths); width = 1; style }
        else
          let ch = if cell_eighths >= 5 then '#' else '=' in
          Cell_grid.put_ascii ?clip grid ~x:(x + i) ~y ~style ch
    done;
    width

let format_header_legend ~lang (series : Series.t) =
  let now_lbl = Say.resolve lang (Say.make ~ko:"현재" ~en:"Now") in
  let peak_lbl = Say.resolve lang (Say.make ~ko:"최대" ~en:"Peak") in
  let avg_lbl = Say.resolve lang (Say.make ~ko:"평균" ~en:"Avg") in
  let now_v = Format_val.format_observed series.unit series.current ~lang in
  let peak_v = Format_val.format_observed series.unit series.peak ~lang in
  let avg_v = Format_val.format_observed series.unit series.avg ~lang in
  let delta =
    match series.delta_pct with
    | Some d -> " " ^ Format_val.format_delta_pct d
    | None -> ""
  in
  Printf.sprintf "%s %s%s %s %s %s %s %s %s"
    now_lbl now_v delta
    (Glyph.to_utf8 Glyph.Separator_dot)
    peak_lbl peak_v
    (Glyph.to_utf8 Glyph.Separator_dot)
    avg_lbl avg_v

let put_styled_runs grid ~clip ~x ~y runs =
  let cx = ref x in
  List.iter
    (fun (text, style) ->
      if String.length text > 0 && !cx < Rect.right clip then begin
        let avail = Rect.right clip - !cx in
        let fit = Grapheme.truncate_to_width ~max_width:avail text in
        let adv = Cell_grid.put_text ~clip grid ~x:!cx ~y ~style fit in
        cx := !cx + adv
      end)
    runs;
  !cx - x

let runs_display_width runs =
  List.fold_left (fun acc (s, _) -> acc + Grapheme.display_width s) 0 runs

let draw_ts_header grid ~clip ~x ~y ~w ~(theme : Theme.t) ~bg ~lang ~show_title
    ~title_with_hotkey ~window ~show_inline_legend (series : Series.t) =
  let win_str = Time_window.label window in
  let dot_style = Typography.whisper ~bg ~italic:false theme in
  let whisper_style = Typography.whisper ~bg theme in
  let left_runs =
    if show_title && String.length (String.trim title_with_hotkey) > 0 then
      [
        (title_with_hotkey, Typography.anchor ~bg theme);
        (Typography.sep_dot, dot_style);
        (win_str, whisper_style);
      ]
    else
      let slbl = String.trim (Say.resolve lang series.label) in
      if String.length slbl > 0 then
        [
          (slbl, Typography.structure ~bg theme);
          (Typography.sep_dot, dot_style);
          (win_str, whisper_style);
        ]
      else []
  in
  let right_runs =
    if not show_inline_legend then []
    else
      let now_lbl = Say.resolve lang (Say.make ~ko:"현재" ~en:"Now") in
      let peak_lbl = Say.resolve lang (Say.make ~ko:"최대" ~en:"Peak") in
      let avg_lbl = Say.resolve lang (Say.make ~ko:"평균" ~en:"Avg") in
      let now_v = Format_val.format_observed series.unit series.current ~lang in
      let peak_v = Format_val.format_observed series.unit series.peak ~lang in
      let avg_v = Format_val.format_observed series.unit series.avg ~lang in
      let now_val_style = Typography.anchor ~bg theme in
      let sub_val_style = Typography.structure ~bg theme in
      let delta_runs =
        match series.delta_pct with
        | Some d ->
            let tok =
              if d > 0.0 then Theme.Status_ok
              else if d < 0.0 then Theme.Status_critical
              else Theme.Status_historical
            in
            [ (" " ^ Format_val.format_delta_pct d, Typography.status ~bg theme tok) ]
        | None -> []
      in
      [ (now_lbl ^ " ", whisper_style); (now_v, now_val_style) ]
      @ delta_runs
      @ [
          (Typography.sep_dot, dot_style);
          (peak_lbl ^ " ", whisper_style);
          (peak_v, sub_val_style);
          (Typography.sep_dot, dot_style);
          (avg_lbl ^ " ", whisper_style);
          (avg_v, sub_val_style);
        ]
  in
  let right_w = runs_display_width right_runs in
  let left_max =
    if right_w > 0 && w > right_w + 4 then w - right_w - 2 else w
  in
  let adv =
    if left_runs = [] then 0
    else
      let left_clip = Rect.intersect clip (Rect.make ~x ~y ~w:left_max ~h:1) in
      put_styled_runs grid ~clip:left_clip ~x ~y left_runs
  in
  let gap = if adv > 0 then 1 else 0 in
  if right_w > 0 && adv + gap < w then begin
    let avail_right = w - adv - gap in
    let rx = x + w - Int.min right_w avail_right in
    let rclip =
      Rect.intersect clip (Rect.make ~x:rx ~y ~w:(Int.min right_w avail_right) ~h:1)
    in
    ignore (put_styled_runs grid ~clip:rclip ~x:rx ~y right_runs)
  end

let draw_dual_header grid ~clip ~x ~y ~w ~(theme : Theme.t) ~bg ~lang ~show_title
    ~title_with_hotkey ~window ~show_inline_legend ~(upper : Series.t)
    ~(lower : Series.t) =
  let win_str = Time_window.label window in
  let dot_style = Typography.whisper ~bg ~italic:false theme in
  let whisper_style = Typography.whisper ~bg theme in
  let up_rgb = Gradient.sample_rgb theme upper.gradient 0.65 in
  let dn_rgb = Gradient.sample_rgb theme lower.gradient 0.65 in
  let up_style = Style.make ~fg:(Color.of_rgb up_rgb) ~bg ~attrs:Attr.bold () in
  let dn_style = Style.make ~fg:(Color.of_rgb dn_rgb) ~bg ~attrs:Attr.bold () in
  let left_runs =
    if show_title && String.length (String.trim title_with_hotkey) > 0 then
      [
        (title_with_hotkey, Typography.anchor ~bg theme);
        (Typography.sep_dot, dot_style);
        (win_str, whisper_style);
      ]
    else
      let ul = String.trim (Say.resolve lang upper.label) in
      let dl = String.trim (Say.resolve lang lower.label) in
      match (String.length ul > 0, String.length dl > 0) with
      | true, true ->
          [
            (Glyph.to_utf8 Glyph.Delta_up ^ " " ^ ul, up_style);
            (Typography.sep_dot, dot_style);
            (Glyph.to_utf8 Glyph.Delta_down ^ " " ^ dl, dn_style);
          ]
      | true, false ->
          [ (Glyph.to_utf8 Glyph.Delta_up ^ " " ^ ul, up_style) ]
      | false, true ->
          [ (Glyph.to_utf8 Glyph.Delta_down ^ " " ^ dl, dn_style) ]
      | false, false -> []
  in
  let right_runs =
    if not show_inline_legend then []
    else
      [
        (Glyph.to_utf8 Glyph.Delta_up ^ " ", up_style);
        ( Format_val.format_observed upper.unit upper.current ~lang,
          Typography.anchor ~bg theme );
        (Typography.sep_dot, dot_style);
        (Glyph.to_utf8 Glyph.Delta_down ^ " ", dn_style);
        ( Format_val.format_observed lower.unit lower.current ~lang,
          Typography.anchor ~bg theme );
      ]
  in
  let right_w = runs_display_width right_runs in
  let left_max =
    if right_w > 0 && w > right_w + 4 then w - right_w - 2 else w
  in
  let left_clip = Rect.intersect clip (Rect.make ~x ~y ~w:left_max ~h:1) in
  let adv = put_styled_runs grid ~clip:left_clip ~x ~y left_runs in
  if right_w > 0 && adv + 1 < w then begin
    let avail_right = w - adv - 1 in
    let rx = x + w - Int.min right_w avail_right in
    let rclip =
      Rect.intersect clip (Rect.make ~x:rx ~y ~w:(Int.min right_w avail_right) ~h:1)
    in
    ignore (put_styled_runs grid ~clip:rclip ~x:rx ~y right_runs)
  end

let draw_empty_plot_notice grid ~clip ~x ~y ~cols ~rows ~(theme : Theme.t) ~bg
    ~lang ~loading =
  if cols <= 0 || rows <= 0 then ()
  else
    let msg =
      if loading then
        Say.resolve lang
          (Say.make
             ~ko:(Glyph.to_utf8 Glyph.Transport_reconnecting ^ " 관측 데이터 수집 중…")
             ~en:(Glyph.to_utf8 Glyph.Transport_reconnecting ^ " Loading observations…"))
      else
        Say.resolve lang
          (Say.make
             ~ko:"관측 데이터 없음 · [r] 새로고침"
             ~en:"No observed data · [r] refresh")
    in
    let style = Typography.whisper ~bg theme in
    let fit = Grapheme.truncate_to_width ~max_width:cols msg in
    let fw = Grapheme.display_width fit in
    let cx = x + Int.max 0 ((cols - fw) / 2) in
    let cy = y + (rows / 2) in
    ignore (Cell_grid.put_text ~clip grid ~x:cx ~y:cy ~style fit)

let draw_y_axis_label grid ~clip ~x ~y ~gutter ~(theme : Theme.t) ~bg text =
  let style = Typography.whisper ~bg ~italic:false theme in
  let fit = Grapheme.truncate_to_width ~max_width:(Int.max 1 (gutter - 1)) text in
  let fw = Grapheme.display_width fit in
  let rx = x + Int.max 0 (gutter - 1 - fw) in
  ignore (Cell_grid.put_text ~clip grid ~x:rx ~y ~style fit)

let row_band_dots ~from_base level =
  Int.max 0 (Int.min 4 (level - (from_base * 4)))

let paint_area_rows grid ~clip ~x ~y ~cols ~rows ~down ~glyphs ~floor ~ceiling
    ~(theme : Theme.t) ~bg ~gradient (samples : Series.sample array) =
  if cols <= 0 || rows <= 0 then ()
  else if series_is_all_unread samples then begin
    let style = Style.make ~fg:(Color.of_rgb theme.text_muted) ~bg () in
    Cell_grid.put_glyph ~clip grid ~x ~y ~style Glyph.Transport_reconnecting
  end
  else
    let dots = rows * 4 in
    let baseline_style = Style.make ~fg:(Color.of_rgb theme.text_muted) ~bg () in
    match glyphs with
    | Render_mode.Braille_2x4 ->
        let subcols = cols * 2 in
        let resampled = Series.resample_peak_preserving ~target_len:subcols samples in
        let levels =
          Array.init subcols (fun i ->
              Series.sample_dot_level ~dots ~floor ~ceiling resampled.(i))
        in
        for row = 0 to rows - 1 do
          let from_base = if down then row else rows - 1 - row in
          let row_ratio =
            if rows <= 1 then 0.5
            else float_of_int from_base /. float_of_int (rows - 1)
          in
          let row_fg = Color.of_rgb (Gradient.sample_rgb theme gradient row_ratio) in
          let row_style = Style.make ~fg:row_fg ~bg () in
          let py = y + row in
          for c = 0 to cols - 1 do
            let l_lvl = levels.(2 * c) in
            let r_lvl = levels.((2 * c) + 1) in
            let l_dots = row_band_dots ~from_base l_lvl in
            let r_dots = row_band_dots ~from_base r_lvl in
            let mask =
              if down then braille_left_down.(l_dots) lor braille_right_down.(r_dots)
              else braille_left_up.(l_dots) lor braille_right_up.(r_dots)
            in
            if mask <> 0 then
              let cell_style =
                if from_base = 0 && Int.max l_lvl r_lvl = 1 then baseline_style
                else if rows > 1 then row_style
                else
                  let peak_lvl = Int.max l_lvl r_lvl in
                  let share =
                    Float.max 0.0
                      (Float.min 1.0
                         (float_of_int (peak_lvl - 2) /. float_of_int (Int.max 1 (dots - 2))))
                  in
                  Style.make ~fg:(Color.of_rgb (Gradient.sample_rgb theme gradient share)) ~bg ()
              in
              Cell_grid.put_braille ~clip grid ~x:(x + c) ~y:py ~style:cell_style mask
          done
        done
    | Render_mode.Block_vertical ->
        let resampled = Series.resample_peak_preserving ~target_len:cols samples in
        let lut = if down then block_vert_down_lut else block_vert_up_lut in
        for row = 0 to rows - 1 do
          let from_base = if down then row else rows - 1 - row in
          let row_ratio =
            if rows <= 1 then 0.5
            else float_of_int from_base /. float_of_int (rows - 1)
          in
          let row_style =
            Style.make ~fg:(Color.of_rgb (Gradient.sample_rgb theme gradient row_ratio)) ~bg ()
          in
          let py = y + row in
          for c = 0 to cols - 1 do
            let lvl = Series.sample_dot_level ~dots ~floor ~ceiling resampled.(c) in
            let band = row_band_dots ~from_base lvl in
            if band > 0 then
              let style = if from_base = 0 && lvl = 1 then baseline_style else row_style in
              Cell_grid.set_cell ~clip grid ~x:(x + c) ~y:py
                { glyph = Cell_grid.Utf8 lut.(band); width = 1; style }
          done
        done
    | Render_mode.Ascii_tty ->
        let resampled = Series.resample_peak_preserving ~target_len:cols samples in
        for row = 0 to rows - 1 do
          let from_base = if down then row else rows - 1 - row in
          let row_ratio =
            if rows <= 1 then 0.5
            else float_of_int from_base /. float_of_int (rows - 1)
          in
          let row_style =
            Style.make ~fg:(Color.of_rgb (Gradient.sample_rgb theme gradient row_ratio)) ~bg ()
          in
          let py = y + row in
          for c = 0 to cols - 1 do
            let lvl = Series.sample_dot_level ~dots ~floor ~ceiling resampled.(c) in
            let band = row_band_dots ~from_base lvl in
            if band > 0 then
              let style = if from_base = 0 && lvl = 1 then baseline_style else row_style in
              Cell_grid.put_ascii ~clip grid ~x:(x + c) ~y:py ~style ascii_vert_lut.(band)
          done
        done

let draw_x_ticks grid ~clip ~x ~y ~cols ~(theme : Theme.t) ~bg window =
  let start_lbl, mid_lbl, end_lbl = Time_window.ticks window in
  let style = Typography.whisper ~bg theme in
  let sw = Grapheme.display_width start_lbl in
  let mw = Grapheme.display_width mid_lbl in
  let ew = Grapheme.display_width end_lbl in
  ignore (Cell_grid.put_text ~clip grid ~x ~y ~style start_lbl);
  if cols >= sw + mw + ew + 4 then begin
    let mx = x + ((cols - mw) / 2) in
    ignore (Cell_grid.put_text ~clip grid ~x:mx ~y ~style mid_lbl)
  end;
  if cols >= sw + ew + 2 then begin
    let ex = x + cols - ew in
    ignore (Cell_grid.put_text ~clip grid ~x:ex ~y ~style end_lbl)
  end

let apportion_floats ~width weights =
  let count = List.length weights in
  if width <= 0 || count = 0 then List.init count (fun _ -> 0)
  else
    let arr = Array.of_list (List.map (fun w -> if Float.is_finite w && w > 0.0 then w else 0.0) weights) in
    let total = Array.fold_left ( +. ) 0.0 arr in
    if total <= 0.0 then List.init count (fun _ -> 0)
    else
      let cells = Array.make count 0 in
      let rems = Array.make count 0.0 in
      let sum = ref 0 in
      for i = 0 to count - 1 do
        let exact = arr.(i) *. float_of_int width /. total in
        let fl = int_of_float (Float.floor exact) in
        cells.(i) <- fl;
        rems.(i) <- exact -. float_of_int fl;
        sum := !sum + fl
      done;
      (* Guarantee >= 1 cell for every positive segment when width allows. *)
      let pos_count = Array.fold_left (fun c w -> if w > 0.0 then c + 1 else c) 0 arr in
      if pos_count <= width then
        for i = 0 to count - 1 do
          if arr.(i) > 0.0 && cells.(i) = 0 then begin
            cells.(i) <- 1;
            incr sum
          end
        done;
      (* Balance excess or shortfall deterministically. *)
      while !sum > width do
        let best = ref (-1) in
        for i = 0 to count - 1 do
          if cells.(i) > 1 && (!best < 0 || cells.(i) > cells.(!best)) then best := i
        done;
        if !best >= 0 then begin
          cells.(!best) <- cells.(!best) - 1;
          decr sum
        end
        else sum := width
      done;
      let order = Array.init count (fun i -> i) in
      Array.sort
        (fun a b ->
          let cmp = Float.compare rems.(b) rems.(a) in
          if cmp <> 0 then cmp else Int.compare a b)
        order;
      let idx = ref 0 in
      while !sum < width && !idx < count do
        let i = order.(!idx) in
        if arr.(i) > 0.0 then begin
          cells.(i) <- cells.(i) + 1;
          incr sum
        end;
        incr idx
      done;
      Array.to_list cells

let draw grid ~(rect : Rect.t) ~(theme : Theme.t) ~(caps : Presenter.capabilities)
    ~lang ?(show_title = true) (spec : Spec.t) =
  let mode = Render_mode.resolve ~avail_w:rect.w ~avail_h:rect.h ~caps spec in
  if Rect.is_empty rect then mode
  else begin
    let bg = Color.of_rgb theme.surface_1 in
    Cell_grid.fill_rect ~clip:rect grid ~rect
      ~style:(Style.make ~fg:(Color.of_rgb theme.text_primary) ~bg ()) ();
    let title_str = Say.resolve lang spec.title in
    let title_with_hotkey =
      match spec.hotkey_hint with
      | Some hk when String.length (String.trim title_str) > 0 ->
          title_str ^ " " ^ hk
      | Some hk -> hk
      | None -> title_str
    in
    (match (spec.kind, mode) with
     | ( Spec.Time_series { series; scale; window },
         Render_mode.Full_area_chart
           { glyphs; plot_cols; plot_rows; show_y_axis; show_x_ticks; show_inline_legend } ) ->
         draw_ts_header grid ~clip:rect ~x:rect.x ~y:rect.y ~w:rect.w ~theme ~bg
           ~lang ~show_title ~title_with_hotkey ~window ~show_inline_legend series;
         let gutter = if show_y_axis then 8 else 0 in
         let plot_x = rect.x + gutter in
         let plot_y = rect.y + 1 in
         if not (series_has_any_data series.samples) then begin
           draw_empty_plot_notice grid ~clip:rect ~x:rect.x ~y:plot_y ~cols:rect.w
             ~rows:(Int.max 1 (Rect.bottom rect - plot_y)) ~theme ~bg ~lang
             ~loading:(series_is_all_unread series.samples)
         end
         else begin
           let max_v = series_max_value series.samples in
           let floor, ceiling = compute_bounds ~scale max_v in
           if show_y_axis then begin
             draw_y_axis_label grid ~clip:rect ~x:rect.x ~y:plot_y ~gutter ~theme ~bg
               (Format_val.format_value series.unit ceiling);
             if plot_rows >= 3 then
               draw_y_axis_label grid ~clip:rect ~x:rect.x ~y:(plot_y + (plot_rows / 2))
                 ~gutter ~theme ~bg
                 (Format_val.format_value series.unit ((floor +. ceiling) /. 2.0));
             if plot_rows >= 2 then
               draw_y_axis_label grid ~clip:rect ~x:rect.x ~y:(plot_y + plot_rows - 1)
                 ~gutter ~theme ~bg
                 (Format_val.format_value series.unit floor)
           end;
           paint_area_rows grid ~clip:rect ~x:plot_x ~y:plot_y ~cols:plot_cols
             ~rows:plot_rows ~down:false ~glyphs ~floor ~ceiling ~theme ~bg
             ~gradient:series.gradient series.samples;
           if show_x_ticks && plot_y + plot_rows < Rect.bottom rect then
             draw_x_ticks grid ~clip:rect ~x:plot_x ~y:(plot_y + plot_rows)
               ~cols:plot_cols ~theme ~bg window
         end
     | ( Spec.Time_series { series; _ },
         Render_mode.Inline_sparkline { glyphs; spark_cols } ) ->
         let unicode =
           match glyphs with
           | Render_mode.Spark_eighth_block -> true
           | Render_mode.Spark_ascii -> false
         in
         let lbl_style = Typography.structure ~bg theme in
         let val_style = Typography.anchor ~bg theme in
         let now_str = Format_val.format_observed series.unit series.current ~lang in
         let val_w = Grapheme.display_width now_str in
         let lbl_src =
           if show_title && String.length (String.trim title_str) > 0 then title_str
           else Say.resolve lang series.label
         in
         let lbl_budget = Int.max 0 (rect.w - spark_cols - val_w - 2) in
         let cx = ref rect.x in
         if lbl_budget > 0 && String.length (String.trim lbl_src) > 0 then begin
           let lbl_fit = Grapheme.truncate_to_width ~max_width:lbl_budget lbl_src in
           let adv = Cell_grid.put_text ~clip:rect grid ~x:!cx ~y:rect.y ~style:lbl_style lbl_fit in
           cx := !cx + adv + 1
         end;
         let drawn =
           draw_sparkline_run ~clip:rect grid ~x:!cx ~y:rect.y ~width:spark_cols
             ~theme ~bg ~unicode ~gradient:series.gradient series.samples
         in
         cx := !cx + drawn + 1;
         ignore (Cell_grid.put_text ~clip:rect grid ~x:!cx ~y:rect.y ~style:val_style now_str);
         if rect.h >= 2 then begin
           let sub = format_header_legend ~lang series in
           let sub_style = Typography.whisper ~bg theme in
           ignore
             (Cell_grid.put_text ~clip:rect grid ~x:rect.x ~y:(rect.y + 1)
                ~style:sub_style
                (Grapheme.truncate_to_width ~max_width:rect.w sub))
         end
     | ( Spec.Dual_inverted { upper; lower; scale; window },
         Render_mode.Dual_mirror_chart
           { glyphs; plot_cols; half_rows; show_y_axis; show_inline_legend } ) ->
         draw_dual_header grid ~clip:rect ~x:rect.x ~y:rect.y ~w:rect.w ~theme ~bg
           ~lang ~show_title ~title_with_hotkey ~window ~show_inline_legend
           ~upper ~lower;
         let gutter = if show_y_axis then 8 else 0 in
         let plot_x = rect.x + gutter in
         let up_y = rect.y + 1 in
         let has_zero_line = up_y + (2 * half_rows) + 2 <= Rect.bottom rect in
         let zero_y = up_y + half_rows in
         let down_y = if has_zero_line then zero_y + 1 else up_y + half_rows in
         if (not (series_has_any_data upper.samples))
            && not (series_has_any_data lower.samples)
         then
           draw_empty_plot_notice grid ~clip:rect ~x:rect.x ~y:up_y ~cols:rect.w
             ~rows:(Int.max 1 (Rect.bottom rect - up_y)) ~theme ~bg ~lang
             ~loading:
               (series_is_all_unread upper.samples && series_is_all_unread lower.samples)
         else begin
           let up_floor, up_ceil, dn_floor, dn_ceil =
             match scale with
             | Scale.Dual_independent { top_min; top_max; bot_min; bot_max } ->
                 let uf = if Float.is_finite top_min then top_min else 0.0 in
                 let uc =
                   if Float.is_finite top_max && top_max > uf then top_max
                   else
                     let mu = series_max_value upper.samples in
                     if mu > uf then Scale.nice_ceiling mu else uf +. 1.0
                 in
                 let df = if Float.is_finite bot_min then bot_min else 0.0 in
                 let dc =
                   if Float.is_finite bot_max && bot_max > df then bot_max
                   else
                     let ml = series_max_value lower.samples in
                     if ml > df then Scale.nice_ceiling ml else df +. 1.0
                 in
                 (uf, uc, df, dc)
             | Scale.Fixed_bounds _ | Scale.Auto_ceil _ | Scale.Synced_pair ->
                 let max_v =
                   Float.max (series_max_value upper.samples)
                     (series_max_value lower.samples)
                 in
                 let floor, ceiling = compute_bounds ~scale max_v in
                 (floor, ceiling, floor, ceiling)
           in
           if show_y_axis then begin
             let up_ceil_str = format_dual_axis_value upper.unit up_ceil in
             let dn_ceil_str = format_dual_axis_value lower.unit dn_ceil in
             draw_y_axis_label grid ~clip:rect ~x:rect.x ~y:up_y ~gutter ~theme ~bg
               (Glyph.to_utf8 Glyph.Delta_up ^ up_ceil_str);
             if has_zero_line then
               draw_y_axis_label grid ~clip:rect ~x:rect.x ~y:zero_y ~gutter ~theme ~bg "0";
             draw_y_axis_label grid ~clip:rect ~x:rect.x
               ~y:(down_y + half_rows - 1) ~gutter ~theme ~bg
               (Glyph.to_utf8 Glyph.Delta_down ^ dn_ceil_str)
           end;
           paint_area_rows grid ~clip:rect ~x:plot_x ~y:up_y ~cols:plot_cols
             ~rows:half_rows ~down:false ~glyphs ~floor:up_floor ~ceiling:up_ceil
             ~theme ~bg ~gradient:upper.gradient upper.samples;
           if has_zero_line then begin
             let zero_rect = Rect.make ~x:plot_x ~y:zero_y ~w:plot_cols ~h:1 in
             Card.draw_hairline ~unicode:caps.unicode_blocks ~bg grid
               ~rect:zero_rect ~y:zero_y ~theme
           end;
           paint_area_rows grid ~clip:rect ~x:plot_x ~y:down_y ~cols:plot_cols
             ~rows:half_rows ~down:true ~glyphs ~floor:dn_floor ~ceiling:dn_ceil
             ~theme ~bg ~gradient:lower.gradient lower.samples;
           if down_y + half_rows < Rect.bottom rect then
             draw_x_ticks grid ~clip:rect ~x:plot_x ~y:(down_y + half_rows)
               ~cols:plot_cols ~theme ~bg window
         end
     | ( Spec.Dual_inverted { upper; lower; _ },
         Render_mode.Inline_sparkline { glyphs; spark_cols } ) ->
         let unicode =
           match glyphs with
           | Render_mode.Spark_eighth_block -> true
           | Render_mode.Spark_ascii -> false
         in
         let lbl_style = Typography.structure ~bg theme in
         let val_style = Typography.primary ~bg theme in
         let paint_row ry glyph (s : Series.t) =
           let tag = Glyph.to_utf8 glyph ^ " " ^ Say.resolve lang s.label in
           let tag_fit = Grapheme.truncate_to_width ~max_width:8 tag in
           ignore (Cell_grid.put_text ~clip:rect grid ~x:rect.x ~y:ry ~style:lbl_style tag_fit);
           ignore
             (draw_sparkline_run ~clip:rect grid ~x:(rect.x + 9) ~y:ry
                ~width:spark_cols ~theme ~bg ~unicode ~gradient:s.gradient s.samples);
           let v = Format_val.format_observed s.unit s.current ~lang in
           ignore
             (Cell_grid.put_text ~clip:rect grid ~x:(rect.x + 10 + spark_cols) ~y:ry
                ~style:val_style v)
         in
         paint_row rect.y Glyph.Delta_up upper;
         if rect.h >= 2 then paint_row (rect.y + 1) Glyph.Delta_down lower
     | ( Spec.Ratio_gauge { used; limit; unit; gradient; reset_hint },
         Render_mode.Half_block_gauge { glyphs; bar_cols; multiline_detail } ) ->
         let unicode =
           match glyphs with
           | Render_mode.Eighth_block | Render_mode.Half_block -> true
           | Render_mode.Ascii_gauge -> false
         in
         let ratio =
           match (Observed.to_option used, Observed.to_option limit) with
           | Some u, Some l when Float.is_finite u && Float.is_finite l && l > 0.0 ->
               Float.max 0.0 (Float.min 1.0 (u /. l))
           | Some _, Some _ | Some _, None | None, Some _ | None, None -> 0.0
         in
         let pct_str =
           match (Observed.to_option used, Observed.to_option limit) with
           | Some u, Some l when Float.is_finite u && Float.is_finite l && l > 0.0 ->
               Format_val.format_value Format_val.Percent (100.0 *. u /. l)
           | Some _, Some _ | Some _, None | None, Some _ | None, None ->
               Format_val.format_observed unit used ~lang
         in
         let detail_str =
           let u_s = Format_val.format_observed unit used ~lang in
           let l_s = Format_val.format_observed unit limit ~lang in
           let hint_s =
             match reset_hint with
             | Some h -> Typography.sep_dot ^ Say.resolve lang h
             | None -> ""
           in
           Printf.sprintf "%s / %s%s" u_s l_s hint_s
         in
         let lbl_style = Typography.primary ~bg theme in
         let pct_style = Typography.anchor ~bg theme in
         let sub_style = Typography.whisper ~bg theme in
         let lbl_text = if show_title then title_str else "" in
         let lbl_w =
           if String.length (String.trim lbl_text) = 0 then 0
           else Int.max 0 (rect.w - bar_cols - Grapheme.display_width pct_str - 2)
         in
         let cx = ref rect.x in
         if lbl_w > 0 then begin
           let fit = Grapheme.truncate_to_width ~max_width:lbl_w lbl_text in
           let adv = Cell_grid.put_text ~clip:rect grid ~x:!cx ~y:rect.y ~style:lbl_style fit in
           cx := !cx + adv + 1
         end;
         let actual_bar_w =
           if lbl_w = 0 then
             Int.max bar_cols (Int.max 8 (rect.w - Grapheme.display_width pct_str - 2))
           else bar_cols
         in
         let drawn =
           draw_ratio_bar_run ~clip:rect grid ~x:!cx ~y:rect.y ~width:actual_bar_w
             ~theme ~bg ~unicode ~gradient ~ratio
         in
         cx := !cx + drawn + 1;
         ignore (Cell_grid.put_text ~clip:rect grid ~x:!cx ~y:rect.y ~style:pct_style pct_str);
         if multiline_detail && rect.h >= 2 then
           ignore
             (Cell_grid.put_text ~clip:rect grid ~x:rect.x ~y:(rect.y + 1)
                ~style:sub_style
                (Grapheme.truncate_to_width ~max_width:rect.w detail_str))
     | ( Spec.Stacked_bar { segments; total_label; unit },
         Render_mode.Half_block_gauge { glyphs; bar_cols; multiline_detail } ) ->
         let unicode =
           match glyphs with
           | Render_mode.Eighth_block | Render_mode.Half_block -> true
           | Render_mode.Ascii_gauge -> false
         in
         let weights = List.map (fun (_, w, _) -> w) segments in
         let total_w = List.fold_left (fun a w -> if Float.is_finite w && w > 0.0 then a +. w else a) 0.0 weights in
         if total_w <= 0.0 then begin
           let track_style = Style.make ~fg:(Color.of_rgb theme.border_inactive) ~bg () in
           for i = 0 to Int.min bar_cols rect.w - 1 do
             if unicode then
               Cell_grid.set_cell ~clip:rect grid ~x:(rect.x + i) ~y:rect.y
                 { glyph = Cell_grid.Utf8 track_unicode; width = 1; style = track_style }
             else Cell_grid.put_ascii ~clip:rect grid ~x:(rect.x + i) ~y:rect.y ~style:track_style '-'
           done
         end
         else begin
           let counts = apportion_floats ~width:bar_cols weights in
           let cx = ref rect.x in
           List.iter2
             (fun (_, _, tok) count ->
               let fg = Color.of_rgb (Theme.status_color theme tok) in
               let style = Style.make ~fg ~bg () in
               for _ = 1 to count do
                 if !cx < Rect.right rect then begin
                   if unicode then
                     Cell_grid.set_cell ~clip:rect grid ~x:!cx ~y:rect.y
                       { glyph = Cell_grid.Utf8 full_block_utf8; width = 1; style }
                   else Cell_grid.put_ascii ~clip:rect grid ~x:!cx ~y:rect.y ~style '#';
                   incr cx
                 end
               done)
             segments counts
         end;
         if multiline_detail && rect.h >= 2 then begin
           let py = rect.y + 1 in
           let row_clip = Rect.make ~x:rect.x ~y:py ~w:rect.w ~h:1 in
           let dot_s = Typography.whisper ~bg ~italic:false theme in
           let sub_s = Typography.structure ~bg theme in
           let prefix_runs =
             let tl = String.trim (Say.resolve lang total_label) in
             if String.length tl > 0 then [ (tl ^ ": ", Typography.whisper ~bg theme) ]
             else []
           in
           let seg_runs =
             segments
             |> List.mapi (fun i (lbl, w, tok) ->
                    let sep = if i = 0 then [] else [ (Typography.sep_dot, dot_s) ] in
                    let dot =
                      if unicode then Glyph.to_utf8 Glyph.Live_healthy ^ " "
                      else "* "
                    in
                    sep
                    @ [
                        (dot, Typography.status ~bg theme tok);
                        ( Printf.sprintf "%s %s" (Say.resolve lang lbl)
                            (Format_val.format_value unit w),
                          sub_s );
                      ])
             |> List.flatten
           in
           ignore (put_styled_runs grid ~clip:row_clip ~x:rect.x ~y:py (prefix_runs @ seg_runs))
         end
     | Spec.Time_series { series; _ }, Render_mode.Numeric_delta_pill ->
         let now_s = Format_val.format_observed series.unit series.current ~lang in
         let delta_s =
           match series.delta_pct with
           | Some d -> " " ^ Format_val.format_delta_pct d
           | None -> ""
         in
         let pill = Grapheme.truncate_to_width ~max_width:rect.w (now_s ^ delta_s) in
         let style = Typography.anchor ~bg theme in
         ignore (Cell_grid.put_text ~clip:rect grid ~x:rect.x ~y:rect.y ~style pill)
     | Spec.Dual_inverted { upper; lower; _ }, Render_mode.Numeric_delta_pill ->
         let pill =
           Printf.sprintf "%s%s %s%s"
             (Glyph.to_utf8 Glyph.Delta_up)
             (Format_val.format_observed upper.unit upper.current ~lang)
             (Glyph.to_utf8 Glyph.Delta_down)
             (Format_val.format_observed lower.unit lower.current ~lang)
         in
         let style = Typography.anchor ~bg theme in
         ignore
           (Cell_grid.put_text ~clip:rect grid ~x:rect.x ~y:rect.y ~style
              (Grapheme.truncate_to_width ~max_width:rect.w pill))
     | Spec.Ratio_gauge { used; limit; unit; _ }, Render_mode.Numeric_delta_pill ->
         let pill =
           match (Observed.to_option used, Observed.to_option limit) with
           | Some u, Some l when Float.is_finite u && Float.is_finite l && l > 0.0 ->
               Printf.sprintf "%s (%s/%s)"
                 (Format_val.format_value Format_val.Percent (100.0 *. u /. l))
                 (Format_val.format_value unit u)
                 (Format_val.format_value unit l)
           | Some _, Some _ | Some _, None | None, Some _ | None, None ->
               Format_val.format_observed unit used ~lang
         in
         let style = Typography.anchor ~bg theme in
         ignore
           (Cell_grid.put_text ~clip:rect grid ~x:rect.x ~y:rect.y ~style
              (Grapheme.truncate_to_width ~max_width:rect.w pill))
     | Spec.Stacked_bar { segments; unit; _ }, Render_mode.Numeric_delta_pill ->
         let total = List.fold_left (fun a (_, w, _) -> a +. w) 0.0 segments in
         let pill = Format_val.format_value unit total in
         let style = Typography.anchor ~bg theme in
         ignore
           (Cell_grid.put_text ~clip:rect grid ~x:rect.x ~y:rect.y ~style
              (Grapheme.truncate_to_width ~max_width:rect.w pill))
     | ( Spec.Time_series _,
         (Render_mode.Dual_mirror_chart _ | Render_mode.Half_block_gauge _) )
     | ( Spec.Dual_inverted _,
         (Render_mode.Full_area_chart _ | Render_mode.Half_block_gauge _) )
     | ( (Spec.Ratio_gauge _ | Spec.Stacked_bar _),
         ( Render_mode.Full_area_chart _
         | Render_mode.Dual_mirror_chart _
         | Render_mode.Inline_sparkline _ ) ) ->
         ());
    mode
  end
