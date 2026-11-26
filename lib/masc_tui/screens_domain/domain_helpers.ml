open Masc_tui_core
open Masc_tui_term
open Masc_tui_ui
open Masc_tui_protocol
open Masc_tui_store

type pill = {
  label : string;
  active : bool;
  tone : Theme.status_token option;
  glyph : Glyph.t option;
}

let default_caps = Presenter.default_capabilities
let is_wide_split (rect : Rect.t) = rect.w >= 100

let layout_bp ~(model : Model.t) ~(rect : Rect.t) =
  let cols = Int.max model.viewport.cols rect.w in
  let rows = Int.max model.viewport.rows rect.h in
  Layout.classify_viewport ~cols ~rows

let body_rect ~bp (rect : Rect.t) =
  if rect.x = 0 then Layout.inset_body bp rect else rect

let pad_content ~bp ?(pad_y = 0) (inner : Rect.t) =
  Card.pad_inner ~pad_x:(Layout.card_pad_x_for_width bp inner.w) ~pad_y inner

let clamp_index = Text_util.clamp_index

let safe_take n xs =
  if n <= 0 then []
  else
    let rec loop acc k = function
      | [] -> List.rev acc
      | _ when k <= 0 -> List.rev acc
      | x :: rest -> loop (x :: acc) (k - 1) rest
    in
    loop [] n xs

let resolve_bg (theme : Theme.t) = function
  | Some bg -> Color.of_rgb bg
  | None -> Color.of_rgb theme.surface_1

let anchor_style ~(theme : Theme.t) ?bg ?(underline = false) () =
  Typography.anchor ~bg:(resolve_bg theme bg) ~underline theme

let text_style ~(theme : Theme.t) ?bg ?(attrs = Attr.none) () =
  Style.make ~fg:(Color.of_rgb theme.text_primary) ~bg:(resolve_bg theme bg)
    ~attrs ()

let secondary_style ~(theme : Theme.t) ?bg ?(attrs = Attr.none) () =
  Style.make ~fg:(Color.of_rgb theme.text_secondary) ~bg:(resolve_bg theme bg)
    ~attrs ()

let muted_style ~(theme : Theme.t) ?bg ?(attrs = Attr.none) () =
  Style.make ~fg:(Color.of_rgb theme.text_muted) ~bg:(resolve_bg theme bg)
    ~attrs ()

let whisper_style ~(theme : Theme.t) ?bg ?(italic = true) () =
  Typography.whisper ~bg:(resolve_bg theme bg) ~italic theme

let accent_style ~(theme : Theme.t) ?bg ?(attrs = Attr.none) () =
  Style.make ~fg:(Color.of_rgb theme.accent) ~bg:(resolve_bg theme bg) ~attrs ()

let ai_style ~(theme : Theme.t) ?bg ?(bold = false) ?(italic = false) () =
  Typography.ai ~bg:(resolve_bg theme bg) ~bold ~italic theme

let status_style ~(theme : Theme.t) ?bg ?(attrs = Attr.none) tone =
  Style.make
    ~fg:(Color.of_rgb (Theme.status_color theme tone))
    ~bg:(resolve_bg theme bg) ~attrs ()

let selection_style ~(theme : Theme.t) ?(attrs = Attr.none) () =
  Style.make
    ~fg:(Color.of_rgb theme.selection_fg)
    ~bg:(Color.of_rgb theme.selection_bg)
    ~attrs ()

let row_text_style ~(theme : Theme.t) ~selected ~focused ~bg =
  if selected && focused then anchor_style ~theme ~bg ()
  else text_style ~theme ~bg ()

let make_badge ?glyph ?tone text : Card.badge = { glyph; text; tone }

let card_spec ?subtitle ?badge ?hotkey ?footer_hint ?(focused = false)
    ?(elevated = false) title : Card.spec =
  {
    title;
    subtitle;
    badge;
    hotkey;
    footer_hint;
    focused;
    elevated;
    unicode_borders = true;
  }

let sanitize_single_line = Text_util.sanitize_single_line

let put_clipped ~grid ~clip ~x ~y ~max_w ~style text =
  if max_w <= 0 || Rect.is_empty clip then 0
  else
    let clean = sanitize_single_line text in
    let fitted = Grapheme.truncate_to_width ~max_width:max_w clean in
    Cell_grid.put_text ~clip grid ~x ~y ~style fitted

let put_right ~grid ~clip ~right_x ~y ~max_w ~style text =
  if max_w <= 0 || Rect.is_empty clip then 0
  else
    let clean = sanitize_single_line text in
    let fitted = Grapheme.truncate_to_width ~max_width:max_w clean in
    let fw = Grapheme.display_width fitted in
    let x = Int.max clip.x (right_x - fw) in
    Cell_grid.put_text ~clip grid ~x ~y ~style fitted

let put_link ~grid ~clip ~x ~y ~max_w ~style ~uri text =
  if max_w <= 0 || Rect.is_empty clip then 0
  else
    let link_id = Cell_grid.intern_hyperlink grid uri in
    let link_style =
      if link_id > 0 then
        style |> Style.add_attr Attr.underline |> Style.with_hyperlink link_id
      else style
    in
    put_clipped ~grid ~clip ~x ~y ~max_w ~style:link_style text

let put_kv ~grid ~clip ~x ~y ~max_w ~(theme : Theme.t) ?bg ?key_w ~key
    ?value_style value =
  if max_w <= 0 || Rect.is_empty clip then ()
  else
    let k_style = secondary_style ~theme ?bg () in
    let v_style =
      match value_style with
      | Some s -> s
      | None -> text_style ~theme ?bg ()
    in
    match key_w with
    | Some fixed_kw when fixed_kw > 0 && fixed_kw + 2 < max_w ->
        let kw_cap = Int.min fixed_kw (max_w - 2) in
        ignore (put_clipped ~grid ~clip ~x ~y ~max_w:kw_cap ~style:k_style key);
        let vx = x + kw_cap + 1 in
        let rem = max_w - kw_cap - 1 in
        if rem > 0 then
          ignore
            (put_clipped ~grid ~clip ~x:vx ~y ~max_w:rem ~style:v_style value)
    | Some _ | None ->
        let k_txt = key ^ ":" in
        let kw = put_clipped ~grid ~clip ~x ~y ~max_w ~style:k_style k_txt in
        let vx = x + kw + 1 in
        let rem = max_w - kw - 1 in
        if rem > 0 then
          ignore
            (put_clipped ~grid ~clip ~x:vx ~y ~max_w:rem ~style:v_style value)

let selected_row_bg ~(theme : Theme.t) ~focused =
  if focused then theme.selection_bg else theme.surface_2

let paint_selected_row_bg ~grid ~clip ~(row_rect : Rect.t) ~(theme : Theme.t)
    ?(focused = true) ?tone () =
  if Rect.is_empty row_rect || Rect.is_empty clip then ()
  else
    let sel_bg = Color.of_rgb (selected_row_bg ~theme ~focused) in
    Cell_grid.fill_rect ~clip grid ~rect:row_rect
      ~style:(Typography.primary ~bg:sel_bg theme) ();
    if focused then
      Card.draw_left_rail ~bg:sel_bg ?tone grid ~x:row_rect.x ~y:row_rect.y ~h:1
        ~theme

let draw_pills ~grid ~(rect : Rect.t) ~(theme : Theme.t) ?bg ?right_hint pills =
  if Rect.is_empty rect then 0
  else
    let bg_rgb = match bg with Some b -> b | None -> theme.surface_0 in
    let base_bg = Color.of_rgb bg_rgb in
    let bar_style = Typography.structure ~bg:base_bg theme in
    Cell_grid.fill_rect ~clip:rect grid ~rect ~style:bar_style ();
    let left_pad =
      match bg with
      | None ->
          if rect.w >= 44 then 2
          else if rect.w >= 24 then 1
          else 0
      | Some _ -> 0
    in
    let right_edge = Rect.right rect - left_pad in
    let hint_reserve =
      match right_hint with
      | Some h when String.length (String.trim h) > 0 && rect.w >= 36 ->
          let h_clean = sanitize_single_line h in
          let max_hw = Int.min (rect.w / 3) (Grapheme.display_width h_clean) in
          let fitted = Grapheme.truncate_to_width ~max_width:max_hw h_clean in
          let fw = Grapheme.display_width fitted in
          let hx = right_edge - fw in
          ignore
            (Cell_grid.put_text ~clip:rect grid ~x:hx ~y:rect.y
               ~style:(Typography.whisper ~bg:base_bg theme)
               fitted);
          fw + 2
      | Some _ | None -> 0
    in
    let pill_right = right_edge - hint_reserve in
    let pill_clip =
      Rect.make ~x:rect.x ~y:rect.y
        ~w:(Int.max 0 (pill_right - rect.x))
        ~h:1
    in
    let pill_gap = if rect.w >= 72 then 2 else 1 in
    let cx = ref (rect.x + left_pad) in
    List.iter
      (fun (p : pill) ->
        let avail = pill_right - !cx in
        if avail >= 3 then begin
          let glyph_str =
            match p.glyph with
            | Some g -> Glyph.to_utf8 g ^ " "
            | None -> ""
          in
          if p.active then begin
            let pill_bg = Color.of_rgb theme.surface_2 in
            let rail_rgb =
              match p.tone with
              | Some tok -> Theme.status_color theme tok
              | None -> theme.accent
            in
            let rail_style =
              Style.make ~fg:(Color.of_rgb rail_rgb) ~bg:pill_bg
                ~attrs:Attr.bold ()
            in
            let lbl_fg =
              match p.tone with
              | Some tok -> Theme.status_color theme tok
              | None -> theme.text_bright
            in
            let lbl_style =
              Style.make ~fg:(Color.of_rgb lbl_fg) ~bg:pill_bg
                ~attrs:(Attr.union Attr.bold Attr.underline) ()
            in
            let pad_style = Typography.primary ~bg:pill_bg theme in
            let cur = ref !cx in
            if !cur < pill_right then begin
              Cell_grid.put_glyph ~clip:pill_clip grid ~x:!cur ~y:rect.y
                ~style:rail_style Glyph.Left_rail;
              incr cur
            end;
            if !cur < pill_right then begin
              Cell_grid.put_ascii ~clip:pill_clip grid ~x:!cur ~y:rect.y
                ~style:pad_style ' ';
              incr cur
            end;
            let adv =
              put_clipped ~grid ~clip:pill_clip ~x:!cur ~y:rect.y
                ~max_w:(Int.max 0 (pill_right - !cur))
                ~style:lbl_style (glyph_str ^ p.label)
            in
            cur := !cur + adv;
            if !cur < pill_right then begin
              Cell_grid.put_ascii ~clip:pill_clip grid ~x:!cur ~y:rect.y
                ~style:pad_style ' ';
              incr cur
            end;
            cx := !cur + pill_gap
          end
          else begin
            let fg_rgb =
              match p.tone with
              | Some tok -> Theme.status_color theme tok
              | None -> theme.text_secondary
            in
            let style =
              Style.make ~fg:(Color.of_rgb fg_rgb) ~bg:base_bg ()
            in
            let text = glyph_str ^ p.label in
            let adv =
              put_clipped ~grid ~clip:pill_clip ~x:!cx ~y:rect.y ~max_w:avail
                ~style text
            in
            cx := !cx + adv + pill_gap
          end
        end)
      pills;
    !cx - rect.x

let draw_divider ~grid ~(rect : Rect.t) ~y ~(theme : Theme.t) ?bg ?(pad_x = 0)
    ?label () =
  let bg_color = resolve_bg theme bg in
  Card.draw_hairline ~pad_x ?label ~unicode:true ~bg:bg_color grid ~rect ~y
    ~theme

let draw_empty_notice ~grid ~(rect : Rect.t) ~(theme : Theme.t) ?bg ?hint msg =
  if Rect.is_empty rect then ()
  else
    let bg_color = resolve_bg theme bg in
    let style = Typography.whisper ~bg:bg_color theme in
    let clean = sanitize_single_line msg in
    let fitted = Grapheme.truncate_to_width ~max_width:rect.w clean in
    let fw = Grapheme.display_width fitted in
    let lines = match hint with Some h when rect.h >= 2 && String.length (String.trim h) > 0 -> 2 | _ -> 1 in
    let cy = rect.y + Int.max 0 ((rect.h - lines) / 2) in
    let cx = rect.x + Int.max 0 ((rect.w - fw) / 2) in
    ignore (Cell_grid.put_text ~clip:rect grid ~x:cx ~y:cy ~style fitted);
    match hint with
    | Some h when lines = 2 ->
        let h_clean = sanitize_single_line h in
        let h_fit = Grapheme.truncate_to_width ~max_width:rect.w h_clean in
        let hw = Grapheme.display_width h_fit in
        let hx = rect.x + Int.max 0 ((rect.w - hw) / 2) in
        ignore
          (Cell_grid.put_text ~clip:rect grid ~x:hx ~y:(cy + 1) ~style h_fit)
    | Some _ | None -> ()

let draw_observed_placeholder ~grid ~(rect : Rect.t) ~(theme : Theme.t) ~lang ?bg
    ?(filter_query = "") ?empty_msg obs =
  if Rect.is_empty rect then ()
  else
    let bg_color = resolve_bg theme bg in
    match obs with
    | Observed.Loading _ ->
        let line =
          Glyph.to_utf8 Glyph.Transport_reconnecting
          ^ " "
          ^ Say.resolve lang (Say.make ~ko:"불러오는 중…" ~en:"Loading…")
        in
        draw_empty_notice ~grid ~rect ~theme ?bg line
    | Observed.Absent ->
        let line =
          Glyph.to_utf8 Glyph.Missing_absent
          ^ " "
          ^ Say.resolve lang
              (Say.make ~ko:"표시할 항목 없음" ~en:"No items available")
        in
        draw_empty_notice ~grid ~rect ~theme ?bg line
    | Observed.Unreported ->
        let line =
          Glyph.to_utf8 Glyph.Missing_unreported
          ^ " "
          ^ Say.resolve lang
              (Say.make ~ko:"서버 미보고" ~en:"Unreported by server")
        in
        draw_empty_notice ~grid ~rect ~theme ?bg line
    | Observed.Failed { reason; retryable; at = _ } ->
        let clean_reason = Chat_transcript.scrub_secrets_in_text reason in
        let suffix =
          if retryable then
            Say.resolve lang
              (Say.make ~ko:" (재시도 가능)" ~en:" (retryable)")
          else ""
        in
        let line =
          Glyph.to_utf8 Glyph.Live_failing
          ^ " "
          ^ Say.resolve lang
              (Say.make
                 ~ko:("조회 실패: " ^ clean_reason ^ suffix)
                 ~en:("Fetch failed: " ^ clean_reason ^ suffix))
        in
        let cy = rect.y + (rect.h / 2) in
        Card.draw_left_rail ~bg:bg_color ~tone:Theme.Status_critical grid
          ~x:rect.x ~y:cy ~h:1 ~theme;
        ignore
          (put_clipped ~grid ~clip:rect ~x:(rect.x + 2) ~y:cy
             ~max_w:(Int.max 0 (rect.w - 2))
             ~style:(Typography.status ~bg:bg_color ~bold:true theme Theme.Status_critical)
             line)
    | Observed.Value _ ->
        let trimmed_q = String.trim filter_query in
        if not (String.equal trimmed_q "") then
          draw_empty_notice ~grid ~rect ~theme ?bg
            (Say.resolve lang
               (Say.make
                  ~ko:"필터 결과 없음 ([Esc] 초기화)"
                  ~en:"No filter matches ([Esc] clear)"))
        else (
          match empty_msg with
          | Some msg ->
              draw_empty_notice ~grid ~rect ~theme ?bg (Say.resolve lang msg)
          | None ->
              let line =
                Glyph.to_utf8 Glyph.Live_healthy
                ^ " "
                ^ Say.resolve lang (Say.make ~ko:"준비됨" ~en:"Ready")
              in
              ignore
                (put_clipped ~grid ~clip:rect ~x:rect.x ~y:rect.y ~max_w:rect.w
                   ~style:(Typography.status ~bg:bg_color theme Theme.Status_ok)
                   line))

let format_age ~now_unix ts_unix =
  if
    (not (Float.is_finite now_unix))
    || (not (Float.is_finite ts_unix))
    || now_unix <= 0.0
    || ts_unix <= 0.0
  then Glyph.to_utf8 Glyph.Missing_absent
  else
    let delta = Float.max 0.0 (now_unix -. ts_unix) in
    if delta < 5.0 then "now" else Format_val.format_duration_s delta

let format_countdown ~now_unix resets_at_unix =
  if
    (not (Float.is_finite now_unix))
    || (not (Float.is_finite resets_at_unix))
    || now_unix <= 0.0
    || resets_at_unix <= 0.0
  then Glyph.to_utf8 Glyph.Missing_absent
  else
    let rem = resets_at_unix -. now_unix in
    if rem <= 0.0 then "0s" else Format_val.format_duration_s rem

let extract_hhmmss ts =
  match String.index_opt ts 'T' with
  | Some idx when idx + 9 <= String.length ts -> String.sub ts (idx + 1) 8
  | Some _ | None -> (
      match String.index_opt ts ' ' with
      | Some idx when idx + 9 <= String.length ts -> String.sub ts (idx + 1) 8
      | Some _ | None ->
          if String.length ts >= 8 then String.sub ts 0 8 else ts)

let format_local_hhmmss ~tz_offset_sec ts =
  match Wire_common.parse_rfc3339_unix ts with
  | Error _ -> extract_hhmmss ts
  | Ok unix_ts ->
      let shifted =
        Int64.add (Int64.of_float (Float.floor unix_ts))
          (Int64.of_int tz_offset_sec)
      in
      let rem = Int64.rem shifted 86400L in
      let day_s =
        Int64.to_int (if Int64.compare rem 0L < 0 then Int64.add rem 86400L else rem)
      in
      let h = day_s / 3600 in
      let m = (day_s mod 3600) / 60 in
      let s = day_s mod 60 in
      Printf.sprintf "%02d:%02d:%02d" h m s

let format_local_datetime ~tz_offset_sec ts =
  match Wire_common.parse_rfc3339_unix ts with
  | Error _ -> ts
  | Ok unix_ts ->
      let shifted = unix_ts +. Float.of_int tz_offset_sec in
      let utc_fmt = Wire_common.format_unix_rfc3339 shifted in
      let base =
        if String.length utc_fmt = 20 && Char.equal utc_fmt.[19] 'Z' then
          String.sub utc_fmt 0 10 ^ " " ^ String.sub utc_fmt 11 8
        else utc_fmt
      in
      if tz_offset_sec = 0 then base ^ " UTC"
      else
        let sign = if tz_offset_sec > 0 then '+' else '-' in
        let abs_s = Int.abs tz_offset_sec in
        let oh = abs_s / 3600 in
        let om = (abs_s mod 3600) / 60 in
        Printf.sprintf "%s %c%02d:%02d" base sign oh om

let wrap_lines ~max_width text =
  let width = Int.max 1 max_width in
  let clean = sanitize_single_line text in
  if String.equal clean "" then []
  else
    let words = String.split_on_char ' ' clean in
    let flush_cur acc cur =
      let s = Buffer.contents cur in
      Buffer.clear cur;
      if String.equal s "" then acc else s :: acc
    in
    let push_long_word acc w =
      let segs = Grapheme.split_clusters w in
      let buf = Buffer.create (String.length w) in
      let cur_w = ref 0 in
      let out = ref acc in
      List.iter
        (fun (g_text, cell_w) ->
          let gw = Int.max 1 cell_w in
          if !cur_w > 0 && !cur_w + gw > width then begin
            out := Buffer.contents buf :: !out;
            Buffer.clear buf;
            cur_w := 0
          end;
          Buffer.add_string buf g_text;
          cur_w := !cur_w + gw)
        segs;
      if Buffer.length buf > 0 then out := Buffer.contents buf :: !out;
      !out
    in
    let cur = Buffer.create width in
    let cur_w = ref 0 in
    let acc =
      List.fold_left
        (fun acc word ->
          let ww = Grapheme.display_width word in
          if !cur_w = 0 then begin
            if ww <= width then begin
              Buffer.add_string cur word;
              cur_w := ww;
              acc
            end
            else push_long_word acc word
          end
          else if !cur_w + 1 + ww <= width then begin
            Buffer.add_char cur ' ';
            Buffer.add_string cur word;
            cur_w := !cur_w + 1 + ww;
            acc
          end
          else begin
            let acc = flush_cur acc cur in
            cur_w := 0;
            if ww <= width then begin
              Buffer.add_string cur word;
              cur_w := ww;
              acc
            end
            else push_long_word acc word
          end)
        [] words
    in
    List.rev (flush_cur acc cur)

let short_hash = Text_util.short_hash

let format_json_scalar = function
  | `String s ->
      if Json_tree.is_secret_value s then "[REDACTED]"
      else sanitize_single_line s
  | `Int n -> string_of_int n
  | `Intlit s -> s
  | `Float f ->
      if Float.is_finite f then Printf.sprintf "%.2f" f
      else Glyph.to_utf8 Glyph.Missing_unreported
  | `Bool b -> if b then "true" else "false"
  | `Null -> Glyph.to_utf8 Glyph.Missing_absent
  | `Assoc kvs -> Printf.sprintf "{%d fields}" (List.length kvs)
  | `List xs -> Printf.sprintf "[%d items]" (List.length xs)

let json_kv_summary = function
  | `Assoc kvs ->
      List.map
        (fun (k, v) ->
          let display =
            if Json_tree.is_secret_key k then "[REDACTED]"
            else format_json_scalar v
          in
          (k, display))
        kvs
  | `List _ | `String _ | `Int _ | `Intlit _ | `Float _ | `Bool _ | `Null -> []

let contains_ci = Text_util.contains_ci

let redact_secrets_in_text s =
  Chat_transcript.scrub_secrets_in_text_with ~replacement:"[REDACTED]" s
