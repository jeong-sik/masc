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
  Card.pad_inner ~pad_x:(Layout.card_pad_x bp) ~pad_y inner

let clamp_index len idx =
  if len <= 0 then 0
  else if idx < 0 then 0
  else if idx >= len then len - 1
  else idx

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

let sanitize_single_line s =
  let len = String.length s in
  if len = 0 then ""
  else
    let buf = Buffer.create len in
    let prev_space = ref false in
    for i = 0 to len - 1 do
      match s.[i] with
      | '\n' | '\r' | '\t' ->
          if not !prev_space then begin
            Buffer.add_char buf ' ';
            prev_space := true
          end
      | c ->
          let is_sp = Char.equal c ' ' in
          if not (is_sp && !prev_space) then Buffer.add_char buf c;
          prev_space := is_sp
    done;
    String.trim (Buffer.contents buf)

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

let paint_selected_row_bg ~grid ~clip ~(row_rect : Rect.t) ~(theme : Theme.t)
    ?tone () =
  if Rect.is_empty row_rect || Rect.is_empty clip then ()
  else
    let sel_bg = Color.of_rgb theme.selection_bg in
    Cell_grid.fill_rect ~clip grid ~rect:row_rect
      ~style:(Typography.primary ~bg:sel_bg theme) ();
    Card.draw_left_rail ~bg:sel_bg ?tone grid ~x:row_rect.x ~y:row_rect.y ~h:1
      ~theme

let draw_pills ~grid ~(rect : Rect.t) ~(theme : Theme.t) ?bg ?right_hint pills =
  if Rect.is_empty rect then 0
  else
    let bg_rgb = match bg with Some b -> b | None -> theme.surface_0 in
    let base_bg = Color.of_rgb bg_rgb in
    let bar_style = Typography.structure ~bg:base_bg theme in
    Cell_grid.fill_rect ~clip:rect grid ~rect ~style:bar_style ();
    let right_edge = Rect.right rect in
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
    let left_pad =
      match bg with
      | None when rect.x = 0 && rect.w >= 4 -> 1
      | None | Some _ -> 0
    in
    let pill_gap = if rect.w >= 96 then 2 else 1 in
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
                ~attrs:Attr.bold ()
            in
            Cell_grid.put_glyph ~clip:rect grid ~x:!cx ~y:rect.y
              ~style:rail_style Glyph.Left_rail;
            let body_x = !cx + 1 in
            let body_max = Int.max 0 (avail - 1) in
            let text = " " ^ glyph_str ^ p.label ^ " " in
            let adv =
              put_clipped ~grid ~clip:rect ~x:body_x ~y:rect.y ~max_w:body_max
                ~style:lbl_style text
            in
            cx := body_x + adv + pill_gap
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
              put_clipped ~grid ~clip:rect ~x:!cx ~y:rect.y ~max_w:avail ~style
                text
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
    obs =
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
                 ~ko:("조회 실패: " ^ reason ^ suffix)
                 ~en:("Fetch failed: " ^ reason ^ suffix))
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
        let line =
          Glyph.to_utf8 Glyph.Live_healthy
          ^ " "
          ^ Say.resolve lang (Say.make ~ko:"준비됨" ~en:"Ready")
        in
        ignore
          (put_clipped ~grid ~clip:rect ~x:rect.x ~y:rect.y ~max_w:rect.w
             ~style:(Typography.status ~bg:bg_color theme Theme.Status_ok)
             line)

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

let short_hash ?(len = 8) s =
  let trimmed = String.trim s in
  if String.length trimmed <= len then trimmed else String.sub trimmed 0 len

let human_account_alias (acct : Wire_runtime.account_usage) =
  Wire_runtime.human_provider_label acct

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

let contains_ci ~needle haystack =
  let n_len = String.length needle in
  if n_len = 0 then true
  else
    let h_len = String.length haystack in
    if n_len > h_len then false
    else
      let n_low = String.lowercase_ascii needle in
      let h_low = String.lowercase_ascii haystack in
      let limit = h_len - n_len in
      let rec scan i =
        if i > limit then false
        else if String.equal (String.sub h_low i n_len) n_low then true
        else scan (i + 1)
      in
      scan 0

let extract_embedded_json s =
  let len = String.length s in
  let find_first_delim () =
    let rec loop i =
      if i >= len then None
      else
        match s.[i] with
        | '{' | '[' -> Some i
        | _ -> loop (i + 1)
    in
    loop 0
  in
  match find_first_delim () with
  | None -> None
  | Some idx -> (
      let prefix = String.trim (String.sub s 0 idx) in
      let rest = String.sub s idx (len - idx) in
      match Yojson.Safe.from_string rest with
      | json -> Some (prefix, json)
      | exception Yojson.Json_error _ -> None)

let is_wrap_punct = function
  | '"' | '\'' | ',' | ';' | '{' | '}' | '[' | ']' | '(' | ')' -> true
  | _ -> false

let strip_wrap_punct s =
  let len = String.length s in
  let rec left i = if i < len && is_wrap_punct s.[i] then left (i + 1) else i in
  let rec right j =
    if j > 0 && is_wrap_punct s.[j - 1] then right (j - 1) else j
  in
  let l = left 0 in
  let r = right len in
  if r <= l then "" else String.sub s l (r - l)

let redact_atom ~redact_next atom =
  let stripped = strip_wrap_punct atom in
  let lower = String.lowercase_ascii stripped in
  if String.equal lower "bearer" || String.equal lower "basic" then begin
    redact_next := true;
    atom
  end
  else if !redact_next then begin
    redact_next := false;
    "[REDACTED]"
  end
  else if Json_tree.is_secret_value stripped then "[REDACTED]"
  else
    match String.index_opt atom '=' with
    | Some eq when eq > 0 ->
        let k = String.sub atom 0 eq in
        let v = String.sub atom (eq + 1) (String.length atom - eq - 1) in
        let k_clean = strip_wrap_punct k in
        let v_clean = strip_wrap_punct v in
        if Json_tree.is_secret_key k_clean || Json_tree.is_secret_value v_clean
        then k ^ "=[REDACTED]"
        else atom
    | Some _ | None -> (
        if contains_ci ~needle:"://" stripped then
          if Json_tree.is_secret_value stripped then "[REDACTED]" else atom
        else
          match String.index_opt atom ':' with
          | Some col when col > 0 ->
              let k = String.sub atom 0 col in
              let v = String.sub atom (col + 1) (String.length atom - col - 1) in
              let k_clean = strip_wrap_punct k in
              let v_clean = strip_wrap_punct v in
              if Json_tree.is_secret_key k_clean then
                if String.equal v_clean "" then begin
                  redact_next := true;
                  atom
                end
                else k ^ ":[REDACTED]"
              else if Json_tree.is_secret_value v_clean then k ^ ":[REDACTED]"
              else atom
          | Some _ | None -> atom)

let redact_line line =
  if
    contains_ci ~needle:"-----BEGIN" line
    && contains_ci ~needle:"PRIVATE KEY" line
  then "[REDACTED]"
  else
    let redact_next = ref false in
    let words = String.split_on_char ' ' line in
    words
    |> List.map (fun w ->
           if String.contains w ',' then
             String.split_on_char ',' w
             |> List.map (redact_atom ~redact_next)
             |> String.concat ","
           else redact_atom ~redact_next w)
    |> String.concat " "

let redact_secrets_in_text s =
  String.split_on_char '\n' s |> List.map redact_line |> String.concat "\n"
