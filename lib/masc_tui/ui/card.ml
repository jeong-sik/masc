module Glyph = Masc_tui_core.Glyph
module Rect = Masc_tui_core.Rect
module Theme = Masc_tui_core.Theme
module Attr = Masc_tui_term.Attr
module Color = Masc_tui_term.Color
module Style = Masc_tui_term.Style
module Grapheme = Masc_tui_term.Grapheme
module Cell_grid = Masc_tui_term.Cell_grid

type badge = {
  glyph : Glyph.t option;
  text : string;
  tone : Theme.status_token option;
}

type spec = {
  title : string;
  subtitle : string option;
  badge : badge option;
  hotkey : string option;
  footer_hint : string option;
  focused : bool;
  elevated : bool;
  unicode_borders : bool;
}

let default_spec ~title =
  {
    title;
    subtitle = None;
    badge = None;
    hotkey = None;
    footer_hint = None;
    focused = false;
    elevated = false;
    unicode_borders = true;
  }

let inner_rect (rect : Rect.t) =
  if rect.w < 2 || rect.h < 2 then Rect.empty
  else Rect.inset_uniform ~dx:1 ~dy:1 rect

let pad_inner ?(pad_x = 2) ?(pad_y = 0) (inner : Rect.t) =
  if Rect.is_empty inner then Rect.empty
  else
    let px = Int.max 0 (Int.min pad_x ((inner.w - 1) / 2)) in
    let py = Int.max 0 (Int.min pad_y ((inner.h - 1) / 2)) in
    Rect.inset_uniform ~dx:px ~dy:py inner

let content_rect ?(pad_x = 2) ?(pad_y = 0) (rect : Rect.t) =
  pad_inner ~pad_x ~pad_y (inner_rect rect)

(* Precomputed border header/footer geometry independent of focus color so
   focus flips repaint in O(perimeter) without re-segmenting UTF-8 titles. *)
type prepared_geometry = {
  width : int;
  left_title : string;
  left_title_w : int;
  left_subtitle : string;
  left_subtitle_w : int;
  badge_text : string;
  badge_w : int;
  right_hotkey : string;
  right_hotkey_w : int;
  footer_text : string;
  footer_w : int;
}

type cache_key = {
  k_width : int;
  k_title : string;
  k_subtitle : string;
  k_badge_prefix : string;
  k_badge_text : string;
  k_hotkey : string;
  k_footer : string;
  k_unicode : bool;
}

let equal_cache_key a b =
  Int.equal a.k_width b.k_width
  && Bool.equal a.k_unicode b.k_unicode
  && String.equal a.k_title b.k_title
  && String.equal a.k_subtitle b.k_subtitle
  && String.equal a.k_badge_prefix b.k_badge_prefix
  && String.equal a.k_badge_text b.k_badge_text
  && String.equal a.k_hotkey b.k_hotkey
  && String.equal a.k_footer b.k_footer

module Cache = struct
  type entry = {
    key : cache_key;
    geom : prepared_geometry;
    mutable last_used : int;
  }

  type stats = {
    capacity : int;
    entries : int;
    hits : int;
    misses : int;
    evictions : int;
  }

  type t = {
    capacity : int;
    mutable tick : int;
    mutable hits : int;
    mutable misses : int;
    mutable evictions : int;
    mutable entries : entry list;
  }

  let default_capacity = 64

  let create ?(capacity = default_capacity) () =
    {
      capacity = Int.max 1 capacity;
      tick = 0;
      hits = 0;
      misses = 0;
      evictions = 0;
      entries = [];
    }

  let clear t =
    t.tick <- 0;
    t.hits <- 0;
    t.misses <- 0;
    t.evictions <- 0;
    t.entries <- []

  let stats t =
    {
      capacity = t.capacity;
      entries = List.length t.entries;
      hits = t.hits;
      misses = t.misses;
      evictions = t.evictions;
    }

  let find_or_build t key build =
    t.tick <- t.tick + 1;
    match List.find_opt (fun e -> equal_cache_key e.key key) t.entries with
    | Some e ->
        e.last_used <- t.tick;
        t.hits <- t.hits + 1;
        e.geom
    | None ->
        t.misses <- t.misses + 1;
        let geom = build () in
        let fresh = { key; geom; last_used = t.tick } in
        if List.length t.entries >= t.capacity then begin
          (* Evict strict least-recently-used entry. *)
          let min_tick =
            List.fold_left (fun acc e -> Int.min acc e.last_used) max_int t.entries
          in
          let removed = ref false in
          let kept =
            List.filter
              (fun e ->
                if (not !removed) && Int.equal e.last_used min_tick then begin
                  removed := true;
                  false
                end
                else true)
              t.entries
          in
          t.evictions <- t.evictions + 1;
          t.entries <- fresh :: kept
        end
        else t.entries <- fresh :: t.entries;
        geom
end

let glyph_str ~unicode g =
  if unicode then Glyph.to_utf8 g else Glyph.to_ascii_fallback g

let build_geometry ~width (spec : spec) =
  (* Reserve corners (2) + minimum 1-cell border dash + space padding on each side (4). *)
  let inner_budget = Int.max 0 (width - 6) in
  let badge_raw =
    match spec.badge with
    | None -> ""
    | Some b ->
        let prefix =
          match b.glyph with
          | Some g -> glyph_str ~unicode:spec.unicode_borders g ^ " "
          | None -> ""
        in
        String.trim (prefix ^ b.text)
  in
  let right_raw =
    match spec.hotkey with
    | Some h -> String.trim h
    | None -> ""
  in
  let title_clean = String.trim spec.title in
  let title_nat_w = Grapheme.display_width title_clean in
  let title_reserve =
    if title_nat_w = 0 then 0
    else Int.min title_nat_w (Int.max 8 (inner_budget / 2))
  in
  (* Right cluster: btop-style [badge]  [hotkey] right-aligned in top border.
     Uses all remaining width after reserving the title so short titles never
     unnecessarily clip hotkeys on Standard/Compact cards. *)
  let max_right_cluster =
    if title_reserve > 0 then Int.max 0 (inner_budget - title_reserve - 4)
    else inner_budget
  in
  let badge_text, badge_w =
    if String.length badge_raw = 0 || max_right_cluster < 4 then ("", 0)
    else
      let fitted =
        Grapheme.truncate_to_width ~max_width:max_right_cluster badge_raw
      in
      (fitted, Grapheme.display_width fitted)
  in
  let hotkey_room =
    if badge_w > 0 then Int.max 0 (max_right_cluster - badge_w - 2)
    else max_right_cluster
  in
  let right_hotkey, right_hotkey_w =
    if String.length right_raw = 0 || hotkey_room < 4 || inner_budget < 10 then
      ("", 0)
    else
      let fitted = Grapheme.truncate_to_width ~max_width:hotkey_room right_raw in
      (fitted, Grapheme.display_width fitted)
  in
  let right_cluster_w =
    match (badge_w > 0, right_hotkey_w > 0) with
    | true, true -> badge_w + 2 + right_hotkey_w
    | true, false -> badge_w
    | false, true -> right_hotkey_w
    | false, false -> 0
  in
  let left_budget =
    if right_cluster_w > 0 then Int.max 0 (inner_budget - right_cluster_w - 4)
    else inner_budget
  in
  let left_title, left_title_w =
    if left_budget <= 0 || String.length title_clean = 0 then ("", 0)
    else
      let fitted = Grapheme.truncate_to_width ~max_width:left_budget title_clean in
      (fitted, Grapheme.display_width fitted)
  in
  let rem_after_title = Int.max 0 (left_budget - left_title_w) in
  let sub_raw =
    match spec.subtitle with
    | Some s -> String.trim s
    | None -> ""
  in
  let left_subtitle, left_subtitle_w =
    if String.length sub_raw = 0 || rem_after_title < 5 then ("", 0)
    else
      let sep =
        if spec.unicode_borders then " " ^ Glyph.to_utf8 Glyph.Separator_dot ^ " "
        else " - "
      in
      let sep_w = Grapheme.display_width sep in
      let fitted =
        Grapheme.truncate_to_width ~max_width:(rem_after_title - sep_w) sub_raw
      in
      let full = sep ^ fitted in
      (full, Grapheme.display_width full)
  in
  let footer_raw =
    match spec.footer_hint with
    | Some f -> String.trim f
    | None -> ""
  in
  let footer_text, footer_w =
    if String.length footer_raw = 0 || inner_budget < 4 then ("", 0)
    else
      let fitted = Grapheme.truncate_to_width ~max_width:inner_budget footer_raw in
      (fitted, Grapheme.display_width fitted)
  in
  {
    width;
    left_title;
    left_title_w;
    left_subtitle;
    left_subtitle_w;
    badge_text;
    badge_w;
    right_hotkey;
    right_hotkey_w;
    footer_text;
    footer_w;
  }

let put_border_glyph grid ~clip ~x ~y ~style ~unicode g =
  if unicode then Cell_grid.put_glyph ~clip grid ~x ~y ~style g
  else
    let s = Glyph.to_ascii_fallback g in
    if String.length s = 1 then
      Cell_grid.put_ascii ~clip grid ~x ~y ~style s.[0]
    else ignore (Cell_grid.put_text ~clip grid ~x ~y ~style s)

let draw ?cache grid ~(rect : Rect.t) ~(theme : Theme.t) (spec : spec) =
  if rect.w < 2 || rect.h < 2 then Rect.empty
  else
    let bg_rgb = if spec.elevated then theme.surface_2 else theme.surface_1 in
    let bg = Color.of_rgb bg_rgb in
    let border_rgb =
      if spec.focused then theme.border_focused else theme.border_inactive
    in
    let border_style = Style.make ~fg:(Color.of_rgb border_rgb) ~bg () in
    let fill_style = Style.make ~fg:(Color.of_rgb theme.text_primary) ~bg () in
    Cell_grid.fill_rect grid ~rect ~style:fill_style ();
    let unicode = spec.unicode_borders in
    let key =
      {
        k_width = rect.w;
        k_title = spec.title;
        k_subtitle = (match spec.subtitle with Some s -> s | None -> "");
        k_badge_prefix =
          (match spec.badge with
           | Some { glyph = Some g; _ } -> glyph_str ~unicode g
           | Some { glyph = None; _ } | None -> "");
        k_badge_text =
          (match spec.badge with Some b -> b.text | None -> "");
        k_hotkey = (match spec.hotkey with Some h -> h | None -> "");
        k_footer = (match spec.footer_hint with Some f -> f | None -> "");
        k_unicode = unicode;
      }
    in
    let geom =
      match cache with
      | Some c -> Cache.find_or_build c key (fun () -> build_geometry ~width:rect.w spec)
      | None -> build_geometry ~width:rect.w spec
    in
    let right_x = Rect.right rect - 1 in
    let bottom_y = Rect.bottom rect - 1 in
    let g_tl, g_tr, g_bl, g_br, g_h, g_v =
      if spec.focused then
        ( Glyph.Box_heavy_tl,
          Glyph.Box_heavy_tr,
          Glyph.Box_heavy_bl,
          Glyph.Box_heavy_br,
          Glyph.Box_heavy_h,
          Glyph.Box_heavy_v )
      else
        ( Glyph.Box_tl,
          Glyph.Box_tr,
          Glyph.Box_bl,
          Glyph.Box_br,
          Glyph.Box_h,
          Glyph.Box_v )
    in
    (* Top and bottom horizontal border lines *)
    put_border_glyph grid ~clip:rect ~x:rect.x ~y:rect.y ~style:border_style
      ~unicode g_tl;
    put_border_glyph grid ~clip:rect ~x:right_x ~y:rect.y ~style:border_style
      ~unicode g_tr;
    put_border_glyph grid ~clip:rect ~x:rect.x ~y:bottom_y ~style:border_style
      ~unicode g_bl;
    put_border_glyph grid ~clip:rect ~x:right_x ~y:bottom_y ~style:border_style
      ~unicode g_br;
    for x = rect.x + 1 to right_x - 1 do
      put_border_glyph grid ~clip:rect ~x ~y:rect.y ~style:border_style
        ~unicode g_h;
      put_border_glyph grid ~clip:rect ~x ~y:bottom_y ~style:border_style
        ~unicode g_h
    done;
    for y = rect.y + 1 to bottom_y - 1 do
      put_border_glyph grid ~clip:rect ~x:rect.x ~y ~style:border_style
        ~unicode g_v;
      put_border_glyph grid ~clip:rect ~x:right_x ~y ~style:border_style
        ~unicode g_v
    done;
    (* Embed left title + subtitle into top border. Focused cards lead with an
       accent Focus_caret chevron and bright anchor title; unfocused cards recede
       to muted structure text so active focus is unmistakable at a glance. *)
    let title_style =
      if spec.focused then Typography.anchor ~bg theme
      else Typography.structure ~bg theme
    in
    let sub_style = Typography.structure ~bg theme in
    let badge_style =
      match spec.badge with
      | Some { tone = Some tok; _ } -> Typography.status ~bg ~bold:spec.focused theme tok
      | Some { tone = None; _ } | None -> Typography.structure ~bg ~bold:spec.focused theme
    in
    let cx = ref (rect.x + 2) in
    let top_clip = Rect.make ~x:(rect.x + 1) ~y:rect.y ~w:(Int.max 0 (rect.w - 2)) ~h:1 in
    if geom.left_title_w > 0 then begin
      if spec.focused then begin
        put_border_glyph grid ~clip:top_clip ~x:(rect.x + 1) ~y:rect.y
          ~style:(Typography.accent ~bg ~bold:true theme)
          ~unicode Glyph.Focus_caret
      end;
      Cell_grid.put_ascii ~clip:top_clip grid ~x:!cx ~y:rect.y ~style:border_style ' ';
      cx := !cx + 1;
      let adv = Cell_grid.put_text ~clip:top_clip grid ~x:!cx ~y:rect.y ~style:title_style geom.left_title in
      cx := !cx + adv;
      if geom.left_subtitle_w > 0 then begin
        let adv_sub =
          Cell_grid.put_text ~clip:top_clip grid ~x:!cx ~y:rect.y ~style:sub_style
            geom.left_subtitle
        in
        cx := !cx + adv_sub
      end;
      Cell_grid.put_ascii ~clip:top_clip grid ~x:!cx ~y:rect.y ~style:border_style ' ';
      cx := !cx + 1
    end;
    (* Embed btop-style right-aligned badge + Tier-4 italic hotkey into top border *)
    let right_cluster_w =
      match (geom.badge_w > 0, geom.right_hotkey_w > 0) with
      | true, true -> geom.badge_w + 2 + geom.right_hotkey_w
      | true, false -> geom.badge_w
      | false, true -> geom.right_hotkey_w
      | false, false -> 0
    in
    if right_cluster_w > 0 then begin
      let hotkey_style = Typography.whisper ~bg theme in
      let start_x = right_x - 2 - right_cluster_w in
      if start_x > !cx then begin
        Cell_grid.put_ascii ~clip:top_clip grid ~x:(start_x - 1) ~y:rect.y
          ~style:border_style ' ';
        let rx = ref start_x in
        if geom.badge_w > 0 then begin
          let adv_b =
            Cell_grid.put_text ~clip:top_clip grid ~x:!rx ~y:rect.y
              ~style:badge_style geom.badge_text
          in
          rx := !rx + adv_b;
          if geom.right_hotkey_w > 0 then begin
            Cell_grid.put_ascii ~clip:top_clip grid ~x:!rx ~y:rect.y
              ~style:border_style ' ';
            Cell_grid.put_ascii ~clip:top_clip grid ~x:(!rx + 1) ~y:rect.y
              ~style:border_style ' ';
            rx := !rx + 2
          end
        end;
        if geom.right_hotkey_w > 0 then begin
          let adv_h =
            Cell_grid.put_text ~clip:top_clip grid ~x:!rx ~y:rect.y
              ~style:hotkey_style geom.right_hotkey
          in
          rx := !rx + adv_h
        end;
        Cell_grid.put_ascii ~clip:top_clip grid ~x:!rx ~y:rect.y
          ~style:border_style ' '
      end
    end;
    (* Embed optional Tier-4 italic footer hint into bottom border *)
    if geom.footer_w > 0 then begin
      let bot_clip =
        Rect.make ~x:(rect.x + 1) ~y:bottom_y ~w:(Int.max 0 (rect.w - 2)) ~h:1
      in
      let footer_style = Typography.whisper ~bg theme in
      let start_x = right_x - 2 - geom.footer_w in
      if start_x >= rect.x + 2 then begin
        Cell_grid.put_ascii ~clip:bot_clip grid ~x:(start_x - 1) ~y:bottom_y
          ~style:border_style ' ';
        ignore
          (Cell_grid.put_text ~clip:bot_clip grid ~x:start_x ~y:bottom_y
             ~style:footer_style geom.footer_text);
        Cell_grid.put_ascii ~clip:bot_clip grid ~x:(start_x + geom.footer_w)
          ~y:bottom_y ~style:border_style ' '
      end
    end;
    ignore geom.width;
    inner_rect rect

let draw_hairline ?(pad_x = 0) ?label ?(focused = true) ?(unicode = true) ?bg
    grid ~(rect : Rect.t) ~y ~(theme : Theme.t) =
  if Rect.is_empty rect || y < rect.y || y >= Rect.bottom rect then ()
  else
    let px = Int.max 0 (Int.min pad_x ((rect.w - 1) / 2)) in
    let x0 = rect.x + px in
    let w = Int.max 0 (rect.w - (2 * px)) in
    if w <= 0 then ()
    else
      let bg = match bg with Some c -> c | None -> Color.of_rgb theme.surface_1 in
      let subtle_style = Style.make ~fg:(Color.of_rgb theme.border_subtle) ~bg () in
      let labeled_line_style =
        if focused then
          Style.make ~fg:(Color.of_rgb theme.border_inactive) ~bg ()
        else subtle_style
      in
      let lbl_style =
        if focused then Typography.anchor ~bg theme
        else Typography.structure ~bg theme
      in
      let clip = Rect.make ~x:x0 ~y ~w ~h:1 in
      let ellipsis = if unicode then "…" else "." in
      match label with
      | None ->
          for x = x0 to x0 + w - 1 do
            put_border_glyph grid ~clip ~x ~y ~style:subtle_style ~unicode
              Glyph.Box_h
          done
      | Some raw ->
          let lbl = String.trim raw in
          if String.length lbl = 0 then
            for x = x0 to x0 + w - 1 do
              put_border_glyph grid ~clip ~x ~y ~style:subtle_style ~unicode
                Glyph.Box_h
            done
          else if w < 6 then
            let adv =
              Cell_grid.put_text ~clip grid ~x:x0 ~y ~style:lbl_style
                (Grapheme.truncate_to_width ~max_width:w ~ellipsis lbl)
            in
            for x = x0 + adv to x0 + w - 1 do
              Cell_grid.put_ascii ~clip grid ~x ~y ~style:labeled_line_style ' '
            done
          else
            let marker =
              if focused then
                if unicode then Glyph.to_utf8 Glyph.Focus_caret else ">"
              else if unicode then Glyph.to_utf8 Glyph.Separator_dot
              else "-"
            in
            let marker_style =
              if focused then Typography.accent ~bg ~bold:true theme
              else Typography.whisper ~bg ~italic:false theme
            in
            let m_adv =
              Cell_grid.put_text ~clip grid ~x:x0 ~y ~style:marker_style marker
            in
            Cell_grid.put_ascii ~clip grid ~x:(x0 + m_adv) ~y
              ~style:labeled_line_style ' ';
            let max_lbl = Int.max 1 (w - m_adv - 3) in
            let fitted =
              Grapheme.truncate_to_width ~max_width:max_lbl ~ellipsis lbl
            in
            let l_adv =
              Cell_grid.put_text ~clip grid ~x:(x0 + m_adv + 1) ~y
                ~style:lbl_style fitted
            in
            let gap_x = x0 + m_adv + 1 + l_adv in
            if gap_x < x0 + w then begin
              Cell_grid.put_ascii ~clip grid ~x:gap_x ~y
                ~style:labeled_line_style ' ';
              for x = gap_x + 1 to x0 + w - 1 do
                put_border_glyph grid ~clip ~x ~y ~style:labeled_line_style
                  ~unicode Glyph.Box_h
              done
            end

let legacy_rule_label s =
  if not (String.starts_with ~prefix:"──" s) then None
  else
    let rec strip_leading_dashes str =
      let t = String.trim str in
      if String.starts_with ~prefix:"─" t then
        strip_leading_dashes (String.sub t 3 (String.length t - 3))
      else t
    in
    let rec strip_trailing_dashes str =
      let t = String.trim str in
      if String.ends_with ~suffix:"─" t then
        strip_trailing_dashes (String.sub t 0 (String.length t - 3))
      else t
    in
    let after = String.sub s 6 (String.length s - 6) in
    Some (after |> strip_leading_dashes |> strip_trailing_dashes)

let draw_v_hairline ?(unicode = true) ?bg grid ~x ~y ~h ~(theme : Theme.t) =
  if h <= 0 then ()
  else
    let bg = match bg with Some c -> c | None -> Color.of_rgb theme.surface_1 in
    let style = Style.make ~fg:(Color.of_rgb theme.border_subtle) ~bg () in
    let clip = Rect.make ~x ~y ~w:1 ~h in
    for row = 0 to h - 1 do
      put_border_glyph grid ~clip ~x ~y:(y + row) ~style ~unicode Glyph.Box_v
    done

let draw_left_rail ?(unicode = true) ?bg ?color ?tone grid ~x ~y ~h
    ~(theme : Theme.t) =
  if h <= 0 then ()
  else
    let bg = match bg with Some c -> c | None -> Color.of_rgb theme.surface_1 in
    let fg_rgb =
      match (color, tone) with
      | Some c, _ -> c
      | None, Some tok -> Theme.status_color theme tok
      | None, None -> theme.accent
    in
    let style = Style.make ~fg:(Color.of_rgb fg_rgb) ~bg () in
    let clip = Rect.make ~x ~y ~w:1 ~h in
    for row = 0 to h - 1 do
      put_border_glyph grid ~clip ~x ~y:(y + row) ~style ~unicode Glyph.Left_rail
    done

let draw_section_band ?(pad_x = 2) grid ~(rect : Rect.t) ~(theme : Theme.t)
    ~left_title ?right_meta ?subtitle () =
  if Rect.is_empty rect then ()
  else
    let band_h =
      match subtitle with
      | Some _ when rect.h >= 2 -> 2
      | Some _ | None -> 1
    in
    let bg = Color.of_rgb theme.surface_2 in
    let band_rect = Rect.make ~x:rect.x ~y:rect.y ~w:rect.w ~h:band_h in
    Cell_grid.fill_rect ~clip:rect grid ~rect:band_rect
      ~style:(Typography.primary ~bg theme) ();
    let px = Int.max 0 (Int.min pad_x ((rect.w - 1) / 2)) in
    let inner_x = rect.x + px in
    let inner_w = Int.max 0 (rect.w - (2 * px)) in
    if inner_w > 0 then begin
      let row0 = Rect.make ~x:inner_x ~y:rect.y ~w:inner_w ~h:1 in
      let right_str =
        match right_meta with Some s -> String.trim s | None -> ""
      in
      let right_w = Grapheme.display_width right_str in
      let left_max =
        if right_w > 0 && inner_w > right_w + 4 then inner_w - right_w - 2
        else inner_w
      in
      let left_fit = Grapheme.truncate_to_width ~max_width:left_max left_title in
      let adv =
        Cell_grid.put_text ~clip:row0 grid ~x:inner_x ~y:rect.y
          ~style:(Typography.anchor ~bg theme) left_fit
      in
      if right_w > 0 && adv + 2 < inner_w then begin
        let avail_r = inner_w - adv - 2 in
        let r_fit = Grapheme.truncate_to_width ~max_width:avail_r right_str in
        let rw = Grapheme.display_width r_fit in
        ignore
          (Cell_grid.put_text ~clip:row0 grid ~x:(inner_x + inner_w - rw) ~y:rect.y
             ~style:(Typography.whisper ~bg theme) r_fit)
      end;
      match subtitle with
      | Some sub when band_h >= 2 ->
          let row1 = Rect.make ~x:inner_x ~y:(rect.y + 1) ~w:inner_w ~h:1 in
          let sub_fit = Grapheme.truncate_to_width ~max_width:inner_w sub in
          ignore
            (Cell_grid.put_text ~clip:row1 grid ~x:inner_x ~y:(rect.y + 1)
               ~style:(Typography.structure ~bg theme) sub_fit)
      | Some _ | None -> ()
    end
