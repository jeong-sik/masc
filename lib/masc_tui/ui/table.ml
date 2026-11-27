module Glyph = Masc_tui_core.Glyph
module Rect = Masc_tui_core.Rect
module Say = Masc_tui_core.Say
module Theme = Masc_tui_core.Theme
module Attr = Masc_tui_term.Attr
module Color = Masc_tui_term.Color
module Style = Masc_tui_term.Style
module Grapheme = Masc_tui_term.Grapheme
module Cell_grid = Masc_tui_term.Cell_grid
module Presenter = Masc_tui_term.Presenter

type align =
  | Left
  | Right
  | Center

type column = {
  id : string;
  header : Say.t;
  priority : int;
  min_width : int;
  max_width : int option;
  weight : int;
  align : align;
}

type cell_content =
  | Text of { text : string; fg : Color.t option; attrs : Attr.t }
  | Badge of { glyph : Glyph.t option; text : string; tone : Theme.status_token }
  | Sparkline of { samples : Chart.Series.sample array; gradient : Chart.Gradient.t }
  | Gauge of { ratio : float; gradient : Chart.Gradient.t; label : string option }

type row = {
  id : string;
  cells : (string * cell_content) list;
}

type layout_result = {
  visible_columns : (column * int) list;
  dropped_columns : column list;
  viewport_start : int;
  viewport_rows : int;
  total_rows : int;
  selected_visible : bool;
}

let text_cell ?fg ?(attrs = Attr.none) text = Text { text; fg; attrs }

let selection_gutter = 2

let right_pad_for ~avail_w = if avail_w >= 20 then 1 else 0

let min_needed ~gap cols =
  let n = List.length cols in
  if n = 0 then 0
  else
    let mins = List.fold_left (fun acc c -> acc + Int.max 1 c.min_width) 0 cols in
    mins + (gap * (n - 1))

let drop_lowest_priority cols =
  (* Highest [priority] value (> 0) drops first; break ties by rightmost column. *)
  let indexed = List.mapi (fun idx c -> (idx, c)) cols in
  let droppable = List.filter (fun (_, c) -> c.priority > 0) indexed in
  match droppable with
  | [] -> None
  | first :: rest ->
      let victim_idx, victim_col =
        List.fold_left
          (fun ((best_i, best_c) as best) ((i, c) as cur) ->
            if c.priority > best_c.priority then cur
            else if c.priority = best_c.priority && i > best_i then cur
            else best)
          first rest
      in
      let remaining =
        List.filter_map
          (fun (i, c) -> if i = victim_idx then None else Some c)
          indexed
      in
      Some (remaining, victim_col)

let resolve_columns_with_gap ?col_gap ~avail_w columns =
  let rpad = right_pad_for ~avail_w in
  let content_w = Int.max 0 (avail_w - selection_gutter - rpad) in
  if content_w <= 0 || columns = [] then (1, [], columns)
  else
    let prune_with ~gap =
      let rec prune active dropped =
        if min_needed ~gap active <= content_w then (active, List.rev dropped)
        else
          match drop_lowest_priority active with
          | Some (next_active, victim) -> prune next_active (victim :: dropped)
          | None -> (active, List.rev dropped)
      in
      prune columns []
    in
    let gap, visible, dropped =
      match col_gap with
      | Some g ->
          let g = Int.max 1 g in
          let v, d = prune_with ~gap:g in
          (g, v, d)
      | None ->
          let v1, d1 = prune_with ~gap:1 in
          let n = List.length v1 in
          let extra_for_gap2 = Int.max 0 (n - 1) in
          let comfort_headroom = Int.max 8 (3 * n) in
          if avail_w >= 52
             && min_needed ~gap:1 v1 + extra_for_gap2 + comfort_headroom <= content_w
          then (2, v1, d1)
          else (1, v1, d1)
    in
    let constraints =
      List.map
        (fun c ->
          let lo = Int.max 1 c.min_width in
          let hi =
            match c.max_width with
            | Some m -> Int.max lo m
            | None -> content_w
          in
          Layout.Min_max { min = lo; max = hi; weight = Int.max 1 c.weight })
        visible
    in
    let widths = Layout.allocate ~total:content_w ~gap constraints in
    (gap, List.combine visible widths, dropped)

let resolve_columns ?col_gap ~avail_w columns =
  let _, visible, dropped = resolve_columns_with_gap ?col_gap ~avail_w columns in
  (visible, dropped)

let compute_viewport ~total_rows ~viewport_rows ~scroll ~selected =
  if total_rows <= 0 || viewport_rows <= 0 then (0, false)
  else
    let max_start = Int.max 0 (total_rows - viewport_rows) in
    let base = Int.max 0 (Int.min max_start scroll) in
    match selected with
    | None -> (base, false)
    | Some idx ->
        let clamped_idx = Int.max 0 (Int.min (total_rows - 1) idx) in
        let start =
          if clamped_idx < base then clamped_idx
          else if clamped_idx >= base + viewport_rows then
            Int.max 0 (clamped_idx - viewport_rows + 1)
          else base
        in
        let start = Int.min max_start start in
        let visible = clamped_idx >= start && clamped_idx < start + viewport_rows in
        (start, visible)

let put_aligned grid ~clip ~x ~y ~w ~align ~style text =
  if w <= 0 then ()
  else
    let fitted = Grapheme.truncate_to_width ~max_width:w text in
    let dx =
      match align with
      | Left -> 0
      | Right -> Int.max 0 (w - Grapheme.display_width fitted)
      | Center -> Int.max 0 ((w - Grapheme.display_width fitted) / 2)
    in
    ignore (Cell_grid.put_text ~clip grid ~x:(x + dx) ~y ~style fitted)

let rec find_cell id = function
  | [] -> None
  | (k, v) :: rest -> if String.equal k id then Some v else find_cell id rest

let draw_virtual grid ~(rect : Rect.t) ~(theme : Theme.t)
    ~(caps : Presenter.capabilities) ~lang ?(scroll = 0) ?selected
    ?(focused = true) ?(zebra = false) ?col_gap ?(header_separator = true)
    ~columns ~total_rows row_at =
  if Rect.is_empty rect then
    {
      visible_columns = [];
      dropped_columns = columns;
      viewport_start = 0;
      viewport_rows = 0;
      total_rows;
      selected_visible = false;
    }
  else
    let gap, visible_columns, dropped_columns =
      resolve_columns_with_gap ?col_gap ~avail_w:rect.w columns
    in
    let has_hidden_notice = dropped_columns <> [] && rect.h >= 3 in
    let header_rows = if rect.h >= 2 then 1 else 0 in
    let footer_rows = if has_hidden_notice then 1 else 0 in
    let sep_rows =
      if header_separator && header_rows = 1
         && rect.h - header_rows - footer_rows >= 3
      then 1
      else 0
    in
    let viewport_rows =
      Int.max 0 (rect.h - header_rows - sep_rows - footer_rows)
    in
    let viewport_start, selected_visible =
      compute_viewport ~total_rows ~viewport_rows ~scroll ~selected
    in
    let surface_card = Color.of_rgb theme.surface_1 in
    let surface_elev = Color.of_rgb theme.surface_2 in
    let surface_canvas = Color.of_rgb theme.surface_0 in
    let surface_sel = Color.of_rgb theme.selection_bg in
    let text_bright = Color.of_rgb theme.text_bright in
    let text_primary = Color.of_rgb theme.text_primary in
    let header_style = Typography.structure ~bg:surface_elev ~bold:true theme in
    let col_positions =
      let cx = ref (rect.x + selection_gutter) in
      Array.of_list
        (List.map
           (fun (col, w) ->
             let x = !cx in
             cx := x + w + gap;
             (col, x, w))
           visible_columns)
    in
    let n_vis_cols = Array.length col_positions in
    if header_rows = 1 then begin
      let hdr_rect = Rect.make ~x:rect.x ~y:rect.y ~w:rect.w ~h:1 in
      Cell_grid.fill_rect ~clip:rect grid ~rect:hdr_rect ~style:header_style ();
      for c = 0 to n_vis_cols - 1 do
        let col, x, w = Array.unsafe_get col_positions c in
        let hdr = Say.resolve lang col.header in
        put_aligned grid ~clip:hdr_rect ~x ~y:rect.y ~w ~align:col.align
          ~style:header_style hdr
      done
    end;
    if sep_rows = 1 then
      Card.draw_hairline ~unicode:caps.unicode_blocks ~bg:surface_card grid ~rect
        ~y:(rect.y + header_rows) ~theme;
    let body_y = rect.y + header_rows + sep_rows in
    let base_normal = Typography.primary ~bg:surface_card theme in
    let base_zebra = Typography.primary ~bg:surface_canvas theme in
    let base_sel_unfocused = Typography.primary ~bg:surface_elev theme in
    let base_sel_focused = Typography.primary ~bg:surface_sel theme in
    let anchor_sel_focused = Typography.anchor ~bg:surface_sel theme in
    let rail_style = Typography.accent ~bg:surface_sel ~bold:true theme in
    let empty_style = Typography.whisper ~bg:surface_card ~italic:false theme in
    let normal_st_ok = Typography.status ~bg:surface_card ~bold:true theme Theme.Status_ok in
    let normal_st_active = Typography.status ~bg:surface_card ~bold:true theme Theme.Status_active in
    let normal_st_attention = Typography.status ~bg:surface_card ~bold:true theme Theme.Status_attention in
    let normal_st_critical = Typography.status ~bg:surface_card ~bold:true theme Theme.Status_critical in
    let normal_st_ai = Typography.status ~bg:surface_card ~bold:true theme Theme.Status_ai in
    let normal_st_hist = Typography.status ~bg:surface_card ~bold:true theme Theme.Status_historical in
    let normal_status_style = function
      | Theme.Status_ok -> normal_st_ok
      | Theme.Status_active -> normal_st_active
      | Theme.Status_attention -> normal_st_attention
      | Theme.Status_critical -> normal_st_critical
      | Theme.Status_ai -> normal_st_ai
      | Theme.Status_historical -> normal_st_hist
    in
    if viewport_rows > 0 then begin
      let body_rect = Rect.make ~x:rect.x ~y:body_y ~w:rect.w ~h:viewport_rows in
      Cell_grid.fill_rect ~clip:rect grid ~rect:body_rect ~style:base_normal ()
    end;
    let cached_fg = ref Color.Default in
    let cached_attrs = ref Attr.none in
    let cached_style = ref base_normal in
    let has_cached = ref false in
    for vrow = 0 to viewport_rows - 1 do
      let idx = viewport_start + vrow in
      let py = body_y + vrow in
      if idx < total_rows then begin
        let row = row_at idx in
        let is_selected =
          match selected with Some s -> Int.equal s idx | None -> false
        in
        let is_normal_bg =
          (not is_selected) && not (zebra && idx land 1 = 1)
        in
        let bg, base_style, gauge_lbl_style =
          if is_normal_bg then (surface_card, base_normal, base_normal)
          else
            let bg, bs, gs =
              if is_selected && focused then
                (surface_sel, base_sel_focused, anchor_sel_focused)
              else if is_selected then
                (surface_elev, base_sel_unfocused, base_sel_unfocused)
              else (surface_canvas, base_zebra, base_zebra)
            in
            let row_rect = Rect.make ~x:rect.x ~y:py ~w:rect.w ~h:1 in
            Cell_grid.fill_rect ~clip:rect grid ~rect:row_rect ~style:bs ();
            if is_selected && focused then begin
              if caps.unicode_blocks then
                Cell_grid.put_glyph ~clip:row_rect grid ~x:rect.x ~y:py
                  ~style:rail_style Glyph.Left_rail
              else
                Cell_grid.put_ascii ~clip:row_rect grid ~x:rect.x ~y:py
                  ~style:rail_style '|'
            end;
            (bg, bs, gs)
        in
        for c = 0 to n_vis_cols - 1 do
          let (col : column), cx, w = Array.unsafe_get col_positions c in
          match find_cell col.id row.cells with
          | None -> ()
          | Some cell -> (
              match cell with
              | Text { text; fg; attrs } ->
                  let style =
                    if is_selected && focused && col.priority = 0 then
                      match fg with
                      | None when attrs = Attr.none -> anchor_sel_focused
                      | Some explicit ->
                          Style.make ~fg:explicit ~bg
                            ~attrs:Attr.(bold lor attrs)
                            ()
                      | None ->
                          Style.make ~fg:text_bright ~bg
                            ~attrs:Attr.(bold lor attrs)
                            ()
                    else
                      match fg with
                      | None when attrs = Attr.none -> base_style
                      | Some explicit ->
                          if is_normal_bg then
                            if !has_cached && Color.equal !cached_fg explicit && !cached_attrs = attrs then
                              !cached_style
                            else begin
                              let st = Style.make ~fg:explicit ~bg ~attrs () in
                              cached_fg := explicit;
                              cached_attrs := attrs;
                              cached_style := st;
                              has_cached := true;
                              st
                            end
                          else Style.make ~fg:explicit ~bg ~attrs ()
                      | None -> Style.make ~fg:text_primary ~bg ~attrs ()
                  in
                  put_aligned grid ~clip:rect ~x:cx ~y:py ~w
                    ~align:col.align ~style text
              | Badge { glyph; text; tone } ->
                  (* Preserve semantic badge hue on both normal and selected rows *)
                  let style =
                    if is_normal_bg then normal_status_style tone
                    else Typography.status ~bg ~bold:true theme tone
                  in
                  let label =
                    match glyph with
                    | Some g ->
                        if String.length text = 0 then Glyph.to_utf8 g
                        else Glyph.to_utf8 g ^ " " ^ text
                    | None -> text
                  in
                  put_aligned grid ~clip:rect ~x:cx ~y:py ~w
                    ~align:col.align ~style label
              | Sparkline { samples; gradient } ->
                  ignore
                    (Chart.draw_sparkline_run ~clip:rect grid ~x:cx ~y:py
                       ~width:w ~theme ~bg ~unicode:caps.unicode_blocks
                       ~gradient samples)
              | Gauge { ratio; gradient; label } -> (
                  match label with
                  | None ->
                      ignore
                        (Chart.draw_ratio_bar_run ~clip:rect grid ~x:cx
                           ~y:py ~width:w ~theme ~bg
                           ~unicode:caps.unicode_blocks ~gradient ~ratio)
                  | Some lbl ->
                      let lw = Grapheme.display_width lbl in
                      let bar_w = Int.max 0 (w - lw - 1) in
                      if bar_w >= 3 then begin
                        ignore
                          (Chart.draw_ratio_bar_run ~clip:rect grid ~x:cx
                             ~y:py ~width:bar_w ~theme ~bg
                             ~unicode:caps.unicode_blocks ~gradient ~ratio);
                        put_aligned grid ~clip:rect ~x:(cx + bar_w + 1)
                          ~y:py ~w:(w - bar_w - 1) ~align:Right
                          ~style:gauge_lbl_style lbl
                      end
                      else
                        put_aligned grid ~clip:rect ~x:cx ~y:py ~w
                          ~align:col.align ~style:gauge_lbl_style lbl))
        done;
        ignore row.id
      end
      else if empty_style != base_normal then begin
        let row_rect = Rect.make ~x:rect.x ~y:py ~w:rect.w ~h:1 in
        Cell_grid.fill_rect ~clip:rect grid ~rect:row_rect ~style:empty_style ()
      end
    done;
    if has_hidden_notice then begin
      let py = Rect.bottom rect - 1 in
      let dropped_count = List.length dropped_columns in
      let names =
        dropped_columns
        |> List.map (fun c -> Say.resolve lang c.header)
        |> String.concat ", "
      in
      let msg =
        match lang with
        | Say.Lang_ko ->
            Glyph.to_utf8 Glyph.Separator_dot ^ " 외 "
            ^ Int.to_string dropped_count ^ "열 숨김: " ^ names
        | Say.Lang_en ->
            Glyph.to_utf8 Glyph.Separator_dot ^ " +"
            ^ Int.to_string dropped_count ^ " hidden cols: " ^ names
      in
      let notice_style = Typography.whisper ~bg:surface_card theme in
      let notice_rect = Rect.make ~x:rect.x ~y:py ~w:rect.w ~h:1 in
      Cell_grid.fill_rect ~clip:rect grid ~rect:notice_rect ~style:notice_style ();
      let avail = Int.max 0 (rect.w - selection_gutter) in
      if avail > 0 then
        ignore
          (Cell_grid.put_text ~clip:notice_rect grid
             ~x:(rect.x + selection_gutter) ~y:py ~style:notice_style
             (Grapheme.truncate_to_width ~max_width:avail msg))
    end;
    {
      visible_columns;
      dropped_columns;
      viewport_start;
      viewport_rows;
      total_rows;
      selected_visible;
    }

let draw grid ~(rect : Rect.t) ~(theme : Theme.t) ~(caps : Presenter.capabilities)
    ~lang ?scroll ?selected ?focused ?zebra ?col_gap ?header_separator ~columns
    rows =
  let rows_arr = Array.of_list rows in
  let total_rows = Array.length rows_arr in
  draw_virtual grid ~rect ~theme ~caps ~lang ?scroll ?selected ?focused ?zebra
    ?col_gap ?header_separator ~columns ~total_rows
    (fun idx -> Array.unsafe_get rows_arr idx)
