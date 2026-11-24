module Glyph = Masc_tui_core.Glyph
module Rect = Masc_tui_core.Rect
module Theme = Masc_tui_core.Theme
module Attr = Masc_tui_term.Attr
module Color = Masc_tui_term.Color
module Style = Masc_tui_term.Style
module Grapheme = Masc_tui_term.Grapheme
module Cell_grid = Masc_tui_term.Cell_grid

type styled_span = {
  text : string;
  style : Style.t;
  hyperlink : string option;
}

type rendered_line = {
  spans : styled_span list;
}

type inline_kind =
  | Inl_plain
  | Inl_strong
  | Inl_emphasis
  | Inl_strike
  | Inl_code
  | Inl_link of string
  | Inl_link_target

type inline_piece = {
  text : string;
  kind : inline_kind;
}

let starts_at text index marker =
  let len = String.length marker in
  index + len <= String.length text
  &&
  let rec same k =
    k >= len || (Char.equal text.[index + k] marker.[k] && same (k + 1))
  in
  same 0

let find_close text ~from ~marker =
  let len = String.length marker in
  let limit = String.length text in
  let rec scan i =
    if i + len > limit then None
    else if starts_at text i marker then Some i
    else scan (i + 1)
  in
  if from >= limit then None else scan from

let is_word_byte c =
  (c >= 'a' && c <= 'z')
  || (c >= 'A' && c <= 'Z')
  || (c >= '0' && c <= '9')
  || Char.code c >= 0x80

let underscore_opens text idx =
  let before = if idx = 0 then ' ' else text.[idx - 1] in
  let after =
    if idx + 1 >= String.length text then ' ' else text.[idx + 1]
  in
  (not (is_word_byte before)) && not (Char.equal after ' ')

let underscore_closes text idx =
  let before = if idx = 0 then ' ' else text.[idx - 1] in
  let after =
    if idx + 1 >= String.length text then ' ' else text.[idx + 1]
  in
  (not (Char.equal before ' ')) && not (is_word_byte after)

let is_url_prefix text idx =
  starts_at text idx "https://"
  || starts_at text idx "http://"
  || starts_at text idx "file://"

let scan_bare_url text idx =
  let limit = String.length text in
  let rec scan i =
    if i >= limit then i
    else
      match text.[i] with
      | ' ' | '\t' | '\n' | '\r' | '<' | '>' | '"' | ')' | ']' -> i
      | _ -> scan (i + 1)
  in
  let raw_stop = scan idx in
  (* Trim trailing sentence punctuation. *)
  let rec trim s =
    if s <= idx then idx
    else
      match text.[s - 1] with
      | '.' | ',' | ';' | ':' | '!' | '?' -> trim (s - 1)
      | _ -> s
  in
  trim raw_stop

let has_non_space text ~from ~stop =
  let rec scan i =
    if i >= stop then false
    else
      match text.[i] with
      | ' ' | '\t' | '\n' | '\r' | '\x0c' -> scan (i + 1)
      | _ -> true
  in
  scan from

let parse_inline ~osc8 text =
  let limit = String.length text in
  let out = ref [] in
  let pending = Buffer.create limit in
  let flush () =
    if Buffer.length pending > 0 then begin
      out := { text = Buffer.contents pending; kind = Inl_plain } :: !out;
      Buffer.clear pending
    end
  in
  let emit kind body =
    if String.length body > 0 then begin
      flush ();
      out := { text = body; kind } :: !out
    end
  in
  (* Monotonic closing-index caches per delimiter marker: since [walk] advances
     [idx] strictly monotonically and closing predicates depend only on the
     closing position in [text], each delimiter scans [text] at most once
     across the entire line (O(N) worst case even on pathological unmatched
     delimiters). *)
  let next_backtick = ref (-1) in
  let next_dstar = ref (-1) in
  let next_dunder = ref (-1) in
  let next_dtilde = ref (-1) in
  let next_star = ref (-1) in
  let next_under = ref (-1) in
  let next_rbracket = ref (-1) in
  let next_rparen = ref (-1) in
  let last_link_target_check = ref (-1, false) in
  let find_cached_close ~cache ~closes ~marker ~opening =
    let cached = !cache in
    if cached >= opening then
      if cached >= limit then None else Some cached
    else
      let rec seek from =
        match find_close text ~from ~marker with
        | None -> None
        | Some close ->
            if closes close then Some close
            else seek (close + String.length marker)
      in
      let res = seek opening in
      cache := (match res with Some c -> c | None -> limit);
      res
  in
  let find_cached_char ~cache ~ch ~from =
    let cached = !cache in
    if cached >= from then
      if cached >= limit then None else Some cached
    else
      let res =
        if from >= limit then None else String.index_from_opt text from ch
      in
      cache := (match res with Some c -> c | None -> limit);
      res
  in
  let rec walk idx =
    if idx >= limit then ()
    else
      let literal () =
        Buffer.add_char pending text.[idx];
        walk (idx + 1)
      in
      let styled ~cache ?(closes = fun _ -> true) marker kind =
        let opening = idx + String.length marker in
        match find_cached_close ~cache ~closes ~marker ~opening with
        | None -> literal ()
        | Some close ->
            if not (has_non_space text ~from:opening ~stop:close) then
              literal ()
            else begin
              let body = String.sub text opening (close - opening) in
              emit kind body;
              walk (close + String.length marker)
            end
      in
      if is_url_prefix text idx then begin
        let stop = scan_bare_url text idx in
        if stop > idx then begin
          let url = String.sub text idx (stop - idx) in
          emit (Inl_link url) url;
          walk stop
        end
        else literal ()
      end
      else
        match text.[idx] with
        | '`' -> styled ~cache:next_backtick "`" Inl_code
        | '*' when starts_at text idx "**" ->
            styled ~cache:next_dstar "**" Inl_strong
        | '_' when starts_at text idx "__" ->
            if underscore_opens text idx then
              styled ~cache:next_dunder
                ~closes:(fun c -> underscore_closes text (c + 1))
                "__" Inl_strong
            else literal ()
        | '~' when starts_at text idx "~~" ->
            styled ~cache:next_dtilde "~~" Inl_strike
        | '*' -> styled ~cache:next_star "*" Inl_emphasis
        | '_' ->
            if underscore_opens text idx then
              styled ~cache:next_under ~closes:(underscore_closes text) "_"
                Inl_emphasis
            else literal ()
        | '[' -> (
            match
              find_cached_char ~cache:next_rbracket ~ch:']' ~from:(idx + 1)
            with
            | Some close_lbl when starts_at text (close_lbl + 1) "(" -> (
                match
                  find_cached_char ~cache:next_rparen ~ch:')'
                    ~from:(close_lbl + 2)
                with
                | Some close_url ->
                    let has_label = close_lbl > idx + 1 in
                    let has_target =
                      let prev_lbl, prev_ok = !last_link_target_check in
                      if Int.equal prev_lbl close_lbl then prev_ok
                      else begin
                        let ok =
                          has_non_space text ~from:(close_lbl + 2)
                            ~stop:close_url
                        in
                        last_link_target_check := (close_lbl, ok);
                        ok
                      end
                    in
                    if has_label && has_target then begin
                      let label =
                        String.sub text (idx + 1) (close_lbl - idx - 1)
                      in
                      let target =
                        String.trim
                          (String.sub text (close_lbl + 2)
                             (close_url - close_lbl - 2))
                      in
                      emit (Inl_link target) label;
                      if not osc8 then
                        emit Inl_link_target (Printf.sprintf " (%s)" target);
                      walk (close_url + 1)
                    end
                    else literal ()
                | None -> literal ())
            | Some _ | None -> literal ())
        | _ -> literal ()
  in
  walk 0;
  flush ();
  List.rev !out

let style_of_inline ~(theme : Theme.t) ~(base_style : Style.t) = function
  | Inl_plain -> (base_style, None)
  | Inl_strong ->
      ( Style.make
          ~fg:(Color.of_rgb theme.text_bright)
          ~bg:base_style.bg
          ~attrs:Attr.(bold lor base_style.attrs)
          (),
        None )
  | Inl_emphasis -> (Style.add_attr Attr.italic base_style, None)
  | Inl_strike -> (Style.add_attr Attr.strike base_style, None)
  | Inl_code ->
      ( Style.make
          ~fg:(Color.of_rgb theme.text_bright)
          ~bg:(Color.of_rgb theme.surface_2) (),
        None )
  | Inl_link url ->
      ( Style.make
          ~fg:(Color.of_rgb theme.status_active)
          ~bg:base_style.bg
          ~attrs:Attr.underline (),
        Some url )
  | Inl_link_target ->
      ( Style.make
          ~fg:(Color.of_rgb theme.text_muted)
          ~bg:base_style.bg
          ~attrs:Attr.italic (),
        None )

let wrap_styled_spans ~width ~prefix ~continuation spans =
  let width = Int.max 4 width in
  let lines = ref [] in
  let cur = ref (List.rev prefix) in
  let cur_w =
    ref
      (List.fold_left
         (fun a (sp : styled_span) -> a + Grapheme.display_width sp.text)
         0 prefix)
  in
  let cont_w =
    List.fold_left
      (fun a (sp : styled_span) -> a + Grapheme.display_width sp.text)
      0 continuation
  in
  let flush_line () =
    lines := { spans = List.rev !cur } :: !lines;
    cur := List.rev continuation;
    cur_w := cont_w
  in
  let append_span (sp : styled_span) =
    if String.length sp.text > 0 then begin
      cur := sp :: !cur;
      cur_w := !cur_w + Grapheme.display_width sp.text
    end
  in
  (* Break each span on spaces and grapheme boundaries for CJK-safe wrapping. *)
  let emit_word ~style ~hyperlink word =
    let ww = Grapheme.display_width word in
    if !cur_w > cont_w && !cur_w + ww > width then flush_line ();
    if !cur_w + ww <= width then append_span { text = word; style; hyperlink }
    else
      (* Hard-wrap long token on grapheme cluster boundaries. *)
      let buf = Buffer.create (String.length word) in
      let buf_w = ref 0 in
      let flush_buf () =
        if Buffer.length buf > 0 then begin
          append_span { text = Buffer.contents buf; style; hyperlink };
          Buffer.clear buf;
          buf_w := 0
        end
      in
      Grapheme.iter_clusters word (fun ~text ~start_offset ~end_offset ~cell_width ->
          if !cur_w + !buf_w + cell_width > width && (!cur_w > cont_w || !buf_w > 0)
          then begin
            flush_buf ();
            flush_line ()
          end;
          Buffer.add_substring buf text start_offset (end_offset - start_offset);
          buf_w := !buf_w + cell_width);
      flush_buf ()
  in
  List.iter
    (fun (sp : styled_span) ->
      let s = sp.text in
      let len = String.length s in
      let rec scan i =
        if i >= len then ()
        else if Char.equal s.[i] ' ' then begin
          let rec end_sp j =
            if j < len && Char.equal s.[j] ' ' then end_sp (j + 1) else j
          in
          let j = end_sp i in
          let spaces = String.sub s i (j - i) in
          let sw = j - i in
          if !cur_w + sw <= width then
            append_span { text = spaces; style = sp.style; hyperlink = sp.hyperlink }
          else if !cur_w > cont_w then flush_line ();
          scan j
        end
        else begin
          let rec end_word j =
            if j < len && not (Char.equal s.[j] ' ') then end_word (j + 1) else j
          in
          let j = end_word i in
          emit_word ~style:sp.style ~hyperlink:sp.hyperlink (String.sub s i (j - i));
          scan j
        end
      in
      scan 0)
    spans;
  lines := { spans = List.rev !cur } :: !lines;
  List.rev !lines

let pad_line_to_width ~width ~pad_style (line : rendered_line) =
  let used =
    List.fold_left (fun acc (sp : styled_span) -> acc + Grapheme.display_width sp.text) 0 line.spans
  in
  let rem = width - used in
  if rem <= 0 then line
  else
    {
      spans =
        line.spans
        @ [ { text = String.make rem ' '; style = pad_style; hyperlink = None } ];
    }

let heading_prefix line =
  let len = String.length line in
  let rec count i =
    if i < len && Char.equal line.[i] '#' && i < 6 then count (i + 1) else i
  in
  let lvl = count 0 in
  if lvl >= 1 && (lvl = len || Char.equal line.[lvl] ' ') then
    Some (lvl, String.trim (String.sub line lvl (len - lvl)))
  else None

let ordered_list_prefix trimmed =
  let len = String.length trimmed in
  let rec digits i =
    if i < len && trimmed.[i] >= '0' && trimmed.[i] <= '9' && i < 4 then
      digits (i + 1)
    else i
  in
  let d = digits 0 in
  if d >= 1 && d + 1 < len && Char.equal trimmed.[d] '.' && Char.equal trimmed.[d + 1] ' '
  then
    let num = String.sub trimmed 0 (d + 1) in
    let body = String.trim (String.sub trimmed (d + 2) (len - d - 2)) in
    Some (num, body)
  else None

let is_thematic_break trimmed =
  let len = String.length trimmed in
  if len < 3 then false
  else
    let ch = trimmed.[0] in
    (Char.equal ch '-' || Char.equal ch '*' || Char.equal ch '_')
    &&
    let n = ref 0 in
    let ok = ref true in
    for i = 0 to len - 1 do
      if Char.equal trimmed.[i] ch then incr n
      else if not (Char.equal trimmed.[i] ' ') then ok := false
    done;
    !ok && !n >= 3

let is_fence_open trimmed =
  if starts_at trimmed 0 "```" then
    let info = String.trim (String.sub trimmed 3 (String.length trimmed - 3)) in
    Some ('`', info)
  else if starts_at trimmed 0 "~~~" then
    let info = String.trim (String.sub trimmed 3 (String.length trimmed - 3)) in
    Some ('~', info)
  else None

let is_fence_close ~fence trimmed =
  let marker = String.make 3 fence in
  starts_at trimmed 0 marker

let split_table_cells line =
  let trimmed = String.trim line in
  let len = String.length trimmed in
  if len < 2 || not (Char.equal trimmed.[0] '|') then None
  else
    let inner =
      if Char.equal trimmed.[len - 1] '|' then String.sub trimmed 1 (len - 2)
      else String.sub trimmed 1 (len - 1)
    in
    Some (List.map String.trim (String.split_on_char '|' inner))

let is_table_rule line =
  let trimmed = String.trim line in
  String.length trimmed >= 3
  && Char.equal trimmed.[0] '|'
  &&
  let has_dash = ref false in
  let valid = ref true in
  for i = 0 to String.length trimmed - 1 do
    match trimmed.[i] with
    | '-' -> has_dash := true
    | '|' | ':' | ' ' | '\t' -> ()
    | _ -> valid := false
  done;
  !valid && !has_dash

let render_lines ~(theme : Theme.t) ~width ?(osc8 = true) raw =
  let width = Int.max 8 width in
  let bg = Color.of_rgb theme.surface_1 in
  let base_style = Typography.primary ~bg theme in
  let muted_style = Typography.whisper ~bg ~italic:false theme in
  let hairline_style = Style.make ~fg:(Color.of_rgb theme.border_subtle) ~bg () in
  let accent_style = Typography.accent ~bg ~bold:true theme in
  let quote_rail_style = Style.make ~fg:(Color.of_rgb theme.border_inactive) ~bg () in
  let quote_style = Typography.whisper ~bg theme in
  let raw_lines =
    String.split_on_char '\n' raw
    |> List.map (fun l ->
           let n = String.length l in
           if n > 0 && Char.equal l.[n - 1] '\r' then String.sub l 0 (n - 1)
           else l)
  in
  let out = ref [] in
  let push_lines ls = out := List.rev_append ls !out in
  let render_inline_line ~base ~prefix ~continuation body =
    let pieces = parse_inline ~osc8 body in
    let spans =
      List.map
        (fun p ->
          let style, hyperlink = style_of_inline ~theme ~base_style:base p.kind in
          { text = p.text; style; hyperlink })
        pieces
    in
    push_lines (wrap_styled_spans ~width ~prefix ~continuation spans)
  in
  let rec walk = function
    | [] -> ()
    | line :: rest -> (
        let trimmed = String.trim line in
        if String.length trimmed = 0 then begin
          push_lines [ { spans = [] } ];
          walk rest
        end
        else
          match is_fence_open trimmed with
          | Some (fence, info) ->
              let rec collect acc = function
                | [] -> (List.rev acc, [])
                | l :: tl ->
                    if is_fence_close ~fence (String.trim l) then (List.rev acc, tl)
                    else collect (l :: acc) tl
              in
              let body_lines, after = collect [] rest in
              let lang_tag =
                match String.split_on_char ' ' info with
                | first :: _ -> first
                | [] -> ""
              in
              let language = Code_lexer.language_of_tag lang_tag in
              let code_bg = Color.of_rgb theme.surface_0 in
              let code_pad = Style.make ~fg:(Color.of_rgb theme.text_primary) ~bg:code_bg () in
              let gutter_span =
                {
                  text = Glyph.to_utf8 Glyph.Left_rail ^ " ";
                  style = Style.make ~fg:(Color.of_rgb theme.border_subtle) ~bg:code_bg ();
                  hyperlink = None;
                }
              in
              if String.length lang_tag > 0 then begin
                let hdr_line =
                  pad_line_to_width ~width ~pad_style:code_pad
                    {
                      spans =
                        [
                          gutter_span;
                          {
                            text = lang_tag;
                            style = Typography.whisper ~bg:code_bg theme;
                            hyperlink = None;
                          };
                        ];
                    }
                in
                push_lines [ hdr_line ]
              end;
              let lexed_rows =
                Code_lexer.rows_of_source ~language (String.concat "\n" body_lines)
              in
              List.iter
                (fun row_segs ->
                  let row_spans =
                    List.map
                      (fun (seg : Code_lexer.segment) ->
                        {
                          text = seg.text;
                          style = Code_lexer.style_of_token ~theme ~bg:code_bg seg.kind;
                          hyperlink = None;
                        })
                      row_segs
                  in
                  let wrapped =
                    wrap_styled_spans ~width ~prefix:[ gutter_span ]
                      ~continuation:[ gutter_span ] row_spans
                    |> List.map (pad_line_to_width ~width ~pad_style:code_pad)
                  in
                  push_lines wrapped)
                lexed_rows;
              walk after
          | None -> (
              match heading_prefix trimmed with
              | Some (lvl, heading_text) ->
                  let h_style =
                    if lvl <= 2 then Typography.anchor ~bg theme
                    else Typography.structure ~bg ~bold:true theme
                  in
                  render_inline_line ~base:h_style ~prefix:[] ~continuation:[]
                    heading_text;
                  if lvl = 1 then begin
                    let rule_w =
                      Int.min width
                        (Int.max 12 (Grapheme.display_width heading_text + 2))
                    in
                    let rule =
                      String.concat ""
                        (List.init rule_w (fun _ -> Glyph.to_utf8 Glyph.Box_h))
                    in
                    push_lines
                      [
                        {
                          spans =
                            [ { text = rule; style = hairline_style; hyperlink = None } ];
                        };
                      ]
                  end;
                  walk rest
              | None ->
                  if is_thematic_break trimmed then begin
                    let rule =
                      String.concat ""
                        (List.init width (fun _ -> Glyph.to_utf8 Glyph.Box_h))
                    in
                    push_lines
                      [
                        {
                          spans =
                            [ { text = rule; style = hairline_style; hyperlink = None } ];
                        };
                      ];
                    walk rest
                  end
                  else if Char.equal trimmed.[0] '>' then begin
                    let body =
                      String.trim (String.sub trimmed 1 (String.length trimmed - 1))
                    in
                    let q_pref =
                      [
                        {
                          text = Glyph.to_utf8 Glyph.Left_rail ^ " ";
                          style = quote_rail_style;
                          hyperlink = None;
                        };
                      ]
                    in
                    render_inline_line ~base:quote_style ~prefix:q_pref
                      ~continuation:q_pref body;
                    walk rest
                  end
                  else if
                    String.length trimmed >= 2
                    && (Char.equal trimmed.[0] '-'
                       || Char.equal trimmed.[0] '*'
                       || Char.equal trimmed.[0] '+')
                    && Char.equal trimmed.[1] ' '
                  then begin
                    let body =
                      String.trim (String.sub trimmed 2 (String.length trimmed - 2))
                    in
                    let bullet_text, clean_body, bullet_style =
                      if starts_at body 0 "[x] " || starts_at body 0 "[X] " then
                        ( Glyph.to_utf8 Glyph.Check_mark ^ " ",
                          String.sub body 4 (String.length body - 4),
                          Typography.status ~bg ~bold:true theme Theme.Status_ok )
                      else if starts_at body 0 "[ ] " then
                        ( Glyph.to_utf8 Glyph.Live_idle ^ " ",
                          String.sub body 4 (String.length body - 4),
                          muted_style )
                      else
                        ( Glyph.to_utf8 Glyph.Separator_dot ^ " ",
                          body,
                          accent_style )
                    in
                    let pref =
                      [ { text = "  " ^ bullet_text; style = bullet_style; hyperlink = None } ]
                    in
                    let cont =
                      [ { text = "    "; style = base_style; hyperlink = None } ]
                    in
                    render_inline_line ~base:base_style ~prefix:pref
                      ~continuation:cont clean_body;
                    walk rest
                  end
                  else
                    match ordered_list_prefix trimmed with
                    | Some (num, body) ->
                        let pref_text = "  " ^ num ^ " " in
                        let cont_text =
                          String.make (Grapheme.display_width pref_text) ' '
                        in
                        let pref =
                          [
                            {
                              text = pref_text;
                              style = Typography.structure ~bg theme;
                              hyperlink = None;
                            };
                          ]
                        in
                        let cont =
                          [ { text = cont_text; style = base_style; hyperlink = None } ]
                        in
                        render_inline_line ~base:base_style ~prefix:pref
                          ~continuation:cont body;
                        walk rest
                    | None -> (
                        match (split_table_cells trimmed, rest) with
                        | Some header_cells, next_line :: after_rule
                          when is_table_rule next_line ->
                            let rec collect_rows acc = function
                              | r :: tl -> (
                                  match split_table_cells r with
                                  | Some cells -> collect_rows (cells :: acc) tl
                                  | None -> (List.rev acc, r :: tl))
                              | [] -> (List.rev acc, [])
                            in
                            let body_rows, remaining = collect_rows [] after_rule in
                            let col_count = Int.max 1 (List.length header_cells) in
                            let sep_w = 3 * (col_count - 1) in
                            let col_w = Int.max 4 ((width - sep_w) / col_count) in
                            let format_trow style cells =
                              let padded =
                                List.init col_count (fun i ->
                                    let cell =
                                      match List.nth_opt cells i with
                                      | Some c -> c
                                      | None -> ""
                                    in
                                    let fit =
                                      Grapheme.truncate_to_width ~max_width:col_w cell
                                    in
                                    let pad =
                                      Int.max 0 (col_w - Grapheme.display_width fit)
                                    in
                                    fit ^ String.make pad ' ')
                              in
                              let sep = " " ^ Glyph.to_utf8 Glyph.Box_v ^ " " in
                              {
                                spans =
                                  [
                                    {
                                      text = String.concat sep padded;
                                      style;
                                      hyperlink = None;
                                    };
                                  ];
                              }
                            in
                            let hdr_bg = Color.of_rgb theme.surface_2 in
                            let hdr_style =
                              Typography.structure ~bg:hdr_bg ~bold:true theme
                            in
                            let rule_line =
                              {
                                spans =
                                  [
                                    {
                                      text =
                                        String.concat ""
                                          (List.init width (fun _ -> Glyph.to_utf8 Glyph.Box_h));
                                      style = hairline_style;
                                      hyperlink = None;
                                    };
                                  ];
                              }
                            in
                            push_lines
                              (pad_line_to_width ~width ~pad_style:hdr_style
                                 (format_trow hdr_style header_cells)
                               :: rule_line
                               :: List.map (format_trow base_style) body_rows);
                            walk remaining
                        | _ ->
                            render_inline_line ~base:base_style ~prefix:[]
                              ~continuation:[] line;
                            walk rest)))
  in
  walk raw_lines;
  List.rev !out

let draw grid ~(rect : Rect.t) ~(theme : Theme.t) ?(osc8 = true) ?(scroll = 0)
    raw =
  if Rect.is_empty rect then 0
  else
    let lines = render_lines ~theme ~width:rect.w ~osc8 raw in
    let total = List.length lines in
    let arr = Array.of_list lines in
    let max_start = Int.max 0 (total - rect.h) in
    let start = Int.max 0 (Int.min max_start scroll) in
    let visible = Int.min rect.h (total - start) in
    let bg = Color.of_rgb theme.surface_1 in
    let clear_style = Typography.primary ~bg theme in
    for i = 0 to visible - 1 do
      let py = rect.y + i in
      let row_rect = Rect.make ~x:rect.x ~y:py ~w:rect.w ~h:1 in
      Cell_grid.fill_rect ~clip:rect grid ~rect:row_rect ~style:clear_style ();
      let cx = ref rect.x in
      List.iter
        (fun (sp : styled_span) ->
          if !cx < Rect.right rect && String.length sp.text > 0 then begin
            let style =
              match (osc8, sp.hyperlink) with
              | true, Some uri ->
                  let link_id = Cell_grid.intern_hyperlink grid uri in
                  Style.with_hyperlink link_id sp.style
              | _ -> sp.style
            in
            let adv = Cell_grid.put_text ~clip:row_rect grid ~x:!cx ~y:py ~style sp.text in
            cx := !cx + adv
          end)
        arr.(start + i).spans
    done;
    total
